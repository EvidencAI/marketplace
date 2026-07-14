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

arguments = {"userId": "stephane", "query": prompt}
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

TEXT="$(python3 - "$RESP_FILE" <<'PYEOF'
import json, sys

resp_path = sys.argv[1]
try:
    with open(resp_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

try:
    text = data["result"]["content"][0]["text"]
except Exception:
    text = ""

if isinstance(text, str) and text != "":
    sys.stdout.write(text)
PYEOF
)"

if [ -n "$TEXT" ]; then
  mnemos_log "userpromptsubmit" "recall" "$DURATION_MS" "ok" "$RESP_SIZE"
  printf '%s' "$TEXT"
else
  mnemos_log "userpromptsubmit" "recall" "$DURATION_MS" "empty" "$RESP_SIZE"
fi

exit 0
