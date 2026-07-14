#!/usr/bin/env bash
# Hook Stop : retrouve le dernier message utilisateur reel dans le
# transcript, filtre les notifications systeme, appelle mnemos_log_exchange
# sur l'edge en fire-and-forget. AUCUNE sortie stdout, jamais. exit 0 dans
# tous les cas.

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

STDIN_FILE="$(mktemp /tmp/mnemos-hook-stop-stdin.XXXXXX)"
CLEANUP_FILES+=("$STDIN_FILE")
cat > "$STDIN_FILE"

ASSISTANT_FILE="$(mktemp /tmp/mnemos-hook-stop-assistant.XXXXXX)"
CLEANUP_FILES+=("$ASSISTANT_FILE")

# Extraction session_id, transcript_path, prompt_id + ecriture de
# last_assistant_message brut dans ASSISTANT_FILE (3 lignes sur stdout :
# session_id, transcript_path, prompt_id)
META_OUT="$(python3 - "$STDIN_FILE" "$ASSISTANT_FILE" <<'PYEOF'
import json, sys

stdin_path, assistant_path = sys.argv[1], sys.argv[2]
try:
    with open(stdin_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    print("")
    print("")
    sys.exit(0)

session_id = data.get("session_id", "") or ""
transcript_path = data.get("transcript_path", "") or ""
prompt_id = data.get("prompt_id", "") or ""
last_assistant = data.get("last_assistant_message", "")
if not isinstance(last_assistant, str):
    last_assistant = ""

try:
    with open(assistant_path, "w", encoding="utf-8") as f:
        f.write(last_assistant)
except Exception:
    pass

print(session_id)
print(transcript_path)
print(prompt_id)
PYEOF
)"

SESSION_ID="$(printf '%s\n' "$META_OUT" | sed -n '1p')"
TRANSCRIPT_PATH="$(printf '%s\n' "$META_OUT" | sed -n '2p')"
PROMPT_ID="$(printf '%s\n' "$META_OUT" | sed -n '3p')"

# find_last_user <transcript_path> <out_file> <prompt_id>
# Sur un tour Cowork qui utilise des outils (la quasi-totalite des tours),
# la DERNIERE entree type=user au moment du Stop est un tool_result
# (message.content = LISTE), pas un vrai message. S'arreter a cette seule
# derniere entree (ancien comportement) perd donc la quasi-totalite des
# echanges reels. On parcourt desormais tout le transcript en retenant DEUX
# candidats au fil de l'eau (sans jamais s'arreter sur une entree a content
# liste, qui n'est simplement pas candidate) :
#   (a) la derniere entree type=user dont promptId (champ racine de
#       l'entree JSONL) == prompt_id recu sur stdin ET dont message.content
#       est une STRING ;
#   (b) la derniere entree type=user dont message.content est une STRING,
#       sans condition sur promptId (repli).
# A la fin : (a) si trouve, sinon (b), sinon MISSING (retry puis abandon,
# comme avant). Si prompt_id est absent/vide, (a) n'est jamais rempli et on
# utilise directement (b).
find_last_user() {
  local transcript="$1" out_file="$2" prompt_id="$3"
  python3 - "$transcript" "$out_file" "$prompt_id" <<'PYEOF'
import json, sys

transcript_path, out_path, prompt_id = sys.argv[1], sys.argv[2], sys.argv[3]
candidate_a = None
candidate_b = None
try:
    with open(transcript_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue
            if entry.get("type") != "user":
                continue
            message = entry.get("message") or {}
            content = message.get("content")
            if not isinstance(content, str):
                continue
            candidate_b = content
            if prompt_id and entry.get("promptId") == prompt_id:
                candidate_a = content
except Exception:
    pass

found = candidate_a if candidate_a is not None else candidate_b

if found is None:
    print("MISSING")
else:
    try:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(found)
    except Exception:
        print("MISSING")
        sys.exit(0)
    print("FOUND")
PYEOF
}

LAST_USER_FILE="$(mktemp /tmp/mnemos-hook-stop-user.XXXXXX)"
CLEANUP_FILES+=("$LAST_USER_FILE")

USER_DECISION="$(find_last_user "$TRANSCRIPT_PATH" "$LAST_USER_FILE" "$PROMPT_ID")"

if [ "$USER_DECISION" != "FOUND" ]; then
  sleep 0.4
  USER_DECISION="$(find_last_user "$TRANSCRIPT_PATH" "$LAST_USER_FILE" "$PROMPT_ID")"
fi

if [ "$USER_DECISION" != "FOUND" ]; then
  DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"
  mnemos_log "stop" "log_exchange" "$DURATION_MS" "no-user-message" 0
  exit 0
fi

# Filtre systeme (uniquement notifications, PAS de filtre de longueur : un
# "ok" est un echange valide au Stop). "Rappel interne :" est un prefixe
# conventionnel de nos automatismes internes (wakeups send_later) : verifie
# en reel le 14/07, ces flux ne portent NULLE PART le prefixe
# "[SYSTEM NOTIFICATION - NOT USER INPUT]" au niveau des hooks (uniquement
# au niveau conversationnel du modele). Limite assumee : un wakeup au
# libelle libre (pas prefixe "Rappel interne :") passera quand meme ce
# filtre et sera archive comme un echange humain.
FILTER_DECISION="$(python3 - "$LAST_USER_FILE" <<'PYEOF'
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
except Exception:
    content = ""

trimmed = content.strip()
if (
    trimmed.startswith("[SYSTEM NOTIFICATION - NOT USER INPUT]")
    or trimmed.startswith("Rappel interne :")
    or "<task-notification>" in content
):
    print("FILTERED")
else:
    print("OK")
PYEOF
)"

if [ "$FILTER_DECISION" != "OK" ]; then
  DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"
  mnemos_log "stop" "log_exchange" "$DURATION_MS" "filtered-system" 0
  exit 0
fi

# Un message user ou assistant vide ne doit pas etre archive (l'edge ne
# valide rien cote serveur sur ces champs, ce serait deposé tel quel).
EMPTY_CHECK="$(python3 - "$LAST_USER_FILE" "$ASSISTANT_FILE" <<'PYEOF'
import sys

user_path, assistant_path = sys.argv[1], sys.argv[2]

def read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""

user_message = read_file(user_path)
assistant_response = read_file(assistant_path)

if user_message.strip() == "" or assistant_response.strip() == "":
    print("EMPTY")
else:
    print("OK")
PYEOF
)"

if [ "$EMPTY_CHECK" != "OK" ]; then
  DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"
  mnemos_log "stop" "log_exchange" "$DURATION_MS" "empty-message" 0
  exit 0
fi

SPACE_ID="$(mnemos_resolve_space_id "$SESSION_ID" "$TRANSCRIPT_PATH")"

BODY_FILE="$(mktemp /tmp/mnemos-hook-stop-body.XXXXXX)"
CLEANUP_FILES+=("$BODY_FILE")

python3 - "$LAST_USER_FILE" "$ASSISTANT_FILE" "$SESSION_ID" "$SPACE_ID" "$BODY_FILE" <<'PYEOF'
import json, sys

user_path, assistant_path, session_id, space_id, body_path = sys.argv[1:6]

def read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""

user_message = read_file(user_path)
assistant_response = read_file(assistant_path)

arguments = {
    "userId": "stephane",
    "sessionId": session_id,
    "userMessage": user_message,
    "assistantResponse": assistant_response,
}
if space_id:
    arguments["spaceId"] = space_id

payload = {
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {"name": "mnemos_log_exchange", "arguments": arguments},
    "id": 1,
}

with open(body_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF

CFGFILE="$(mktemp /tmp/mnemos-hook-stop-cfg.XXXXXX)"
CLEANUP_FILES+=("$CFGFILE")
RESP_FILE="$(mktemp /tmp/mnemos-hook-stop-resp.XXXXXX)"
CLEANUP_FILES+=("$RESP_FILE")

mnemos_curl_post "$BODY_FILE" "$CFGFILE" "$RESP_FILE"
CURL_RC="${MNEMOS_LAST_CURL_RC:-1}"
HTTP_CODE="${MNEMOS_LAST_HTTP_CODE:-000}"
RESP_SIZE="$(wc -c < "$RESP_FILE" 2>/dev/null | tr -d ' ')"
RESP_SIZE="${RESP_SIZE:-0}"
DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"

if [ "$CURL_RC" -ne 0 ]; then
  mnemos_log "stop" "log_exchange" "$DURATION_MS" "timeout" "$RESP_SIZE"
  exit 0
fi

case "$HTTP_CODE" in
  2??) mnemos_log "stop" "log_exchange" "$DURATION_MS" "ok" "$RESP_SIZE" ;;
  *) mnemos_log "stop" "log_exchange" "$DURATION_MS" "error-http-$HTTP_CODE" "$RESP_SIZE" ;;
esac

exit 0
