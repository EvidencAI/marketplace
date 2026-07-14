#!/usr/bin/env bash
# Hook UserPromptSubmit : filtre les prompts, resout le spaceId, appelle
# mnemos_recall sur l'edge, recopie le bloc FACE-A tel quel sur stdout.
# Sortie stdout = texte brut uniquement, jamais de JSON. exit 0 dans tous
# les cas (succes, filtre, erreur reseau, JSON invalide, exception python).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/mnemos-common.sh"

MNEMOS_HOOK_TOKEN="__MNEMOS_HOOK_KEY__"

CLEANUP_FILES=()
cleanup_and_exit() {
  local f
  for f in "${CLEANUP_FILES[@]:-}"; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null
  done
  exit 0
}
trap cleanup_and_exit EXIT INT TERM

START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"

STDIN_FILE="$(mktemp /tmp/mnemos-hook-ups-stdin.XXXXXX)"
CLEANUP_FILES+=("$STDIN_FILE")
cat > "$STDIN_FILE"

PROMPT_FILE="$(mktemp /tmp/mnemos-hook-ups-prompt.XXXXXX)"
CLEANUP_FILES+=("$PROMPT_FILE")

# Extraction (session_id, transcript_path) + ecriture du prompt brut dans
# PROMPT_FILE + decision de filtrage (3 lignes sur stdout : session_id,
# transcript_path, decision "OK" ou "FILTERED").
EXTRACT_OUT="$(python3 - "$STDIN_FILE" "$PROMPT_FILE" <<'PYEOF'
import json, sys

stdin_path, prompt_path = sys.argv[1], sys.argv[2]
try:
    with open(stdin_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    print("")
    print("FILTERED")
    sys.exit(0)

prompt = data.get("prompt", "")
if not isinstance(prompt, str):
    prompt = ""
session_id = data.get("session_id", "") or ""
transcript_path = data.get("transcript_path", "") or ""

try:
    with open(prompt_path, "w", encoding="utf-8") as f:
        f.write(prompt)
except Exception:
    pass

# "Rappel interne :" est un prefixe conventionnel de nos automatismes
# internes (wakeups send_later) : verifie en reel le 14/07, ces flux ne
# portent NULLE PART le prefixe "[SYSTEM NOTIFICATION - NOT USER INPUT]" au
# niveau des hooks (uniquement au niveau conversationnel du modele). Limite
# assumee : un wakeup au libelle libre (pas prefixe "Rappel interne :")
# passera quand meme ce filtre.
trimmed = prompt.strip()
decision = "OK"
if len(trimmed) < 10:
    decision = "FILTERED"
elif trimmed.startswith("<uploaded_files>"):
    decision = "FILTERED"
elif trimmed.startswith("<system-reminder>"):
    decision = "FILTERED"
elif trimmed.startswith("This session is being continued"):
    decision = "FILTERED"
elif trimmed.startswith("[SYSTEM NOTIFICATION - NOT USER INPUT]"):
    decision = "FILTERED"
elif trimmed.startswith("Rappel interne :"):
    decision = "FILTERED"
elif "<task-notification>" in prompt:
    decision = "FILTERED"

print(session_id)
print(transcript_path)
print(decision)
PYEOF
)"

SESSION_ID="$(printf '%s\n' "$EXTRACT_OUT" | sed -n '1p')"
TRANSCRIPT_PATH="$(printf '%s\n' "$EXTRACT_OUT" | sed -n '2p')"
DECISION="$(printf '%s\n' "$EXTRACT_OUT" | sed -n '3p')"

DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"

if [ "$DECISION" != "OK" ]; then
  mnemos_log "userpromptsubmit" "filtered" "$DURATION_MS" "filtered" 0
  exit 0
fi

SPACE_ID="$(mnemos_resolve_space_id "$SESSION_ID" "$TRANSCRIPT_PATH")"

BODY_FILE="$(mktemp /tmp/mnemos-hook-ups-body.XXXXXX)"
CLEANUP_FILES+=("$BODY_FILE")

python3 - "$PROMPT_FILE" "$SPACE_ID" "$BODY_FILE" <<'PYEOF'
import json, sys

prompt_path, space_id, body_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(prompt_path, "r", encoding="utf-8") as f:
        prompt = f.read()
except Exception:
    prompt = ""

# Plafonne la query envoyee a l'embedding a 2000 caracteres (evite d'envoyer
# un gros collage de document entier), sans toucher au prompt original
# utilise par ailleurs pour le filtrage.
query = prompt[:2000]

arguments = {"userId": "stephane", "query": query}
if space_id:
    arguments["spaceId"] = space_id

payload = {
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {"name": "mnemos_recall", "arguments": arguments},
    "id": 1,
}

with open(body_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF

CFGFILE="$(mktemp /tmp/mnemos-hook-ups-cfg.XXXXXX)"
CLEANUP_FILES+=("$CFGFILE")
RESP_FILE="$(mktemp /tmp/mnemos-hook-ups-resp.XXXXXX)"
CLEANUP_FILES+=("$RESP_FILE")

mnemos_curl_post "$BODY_FILE" "$CFGFILE" "$RESP_FILE"
CURL_RC="${MNEMOS_LAST_CURL_RC:-1}"
HTTP_CODE="${MNEMOS_LAST_HTTP_CODE:-000}"

DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"
RESP_SIZE="$(wc -c < "$RESP_FILE" 2>/dev/null | tr -d ' ')"
RESP_SIZE="${RESP_SIZE:-0}"

if [ "$CURL_RC" -ne 0 ]; then
  mnemos_log "userpromptsubmit" "recall" "$DURATION_MS" "timeout" "$RESP_SIZE"
  exit 0
fi

case "$HTTP_CODE" in
  2??) : ;;
  *)
    mnemos_log "userpromptsubmit" "recall" "$DURATION_MS" "error-http-$HTTP_CODE" "$RESP_SIZE"
    exit 0
    ;;
esac

# L'edge renvoie les erreurs d'execution d'outil en HTTP 200 avec
# result.content[0].text = message d'erreur ET result.isError = true
# (verifie sur tools.ts, bloc catch et cas "Unknown tool"). Si isError est
# vrai, on ne renvoie RIEN sur stdout (Q10 : fail silencieux obligatoire,
# jamais de texte d'erreur injecte dans le contexte du modele) et on
# distingue le statut logge ("tool-error") plutot que "ok"/"empty".
STATUS_AND_TEXT="$(python3 - "$RESP_FILE" <<'PYEOF'
import json, sys

resp_path = sys.argv[1]
try:
    with open(resp_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("empty")
    sys.exit(0)

result = data.get("result")
if not isinstance(result, dict):
    print("empty")
    sys.exit(0)

if result.get("isError"):
    print("tool-error")
    sys.exit(0)

try:
    text = result["content"][0]["text"]
except Exception:
    text = ""

if isinstance(text, str) and text != "":
    print("ok")
    sys.stdout.write(text)
else:
    print("empty")
PYEOF
)"

STATUS="$(printf '%s\n' "$STATUS_AND_TEXT" | head -n 1)"
TEXT="$(printf '%s\n' "$STATUS_AND_TEXT" | tail -n +2)"

case "$STATUS" in
  ok)
    mnemos_log "userpromptsubmit" "recall" "$DURATION_MS" "ok" "$RESP_SIZE"
    printf '%s' "$TEXT"
    ;;
  tool-error)
    mnemos_log "userpromptsubmit" "recall" "$DURATION_MS" "tool-error" "$RESP_SIZE"
    ;;
  *)
    mnemos_log "userpromptsubmit" "recall" "$DURATION_MS" "empty" "$RESP_SIZE"
    ;;
esac

exit 0
