#!/usr/bin/env bash
# Hook Stop : retrouve le dernier message utilisateur reel dans le
# transcript, filtre les notifications systeme, appelle mycelora_log_exchange
# sur l'edge en fire-and-forget. AUCUNE sortie stdout, jamais. exit 0 dans
# tous les cas.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/mycelora-common.sh"

# Session token: read only from the thread cache built by session_start
# (never from the environment or a plugin option).
MYCELORA_HOOK_TOKEN=""

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

STDIN_FILE="$(mktemp /tmp/mycelora-hook-stop-stdin.XXXXXX)"
CLEANUP_FILES+=("$STDIN_FILE")
cat > "$STDIN_FILE"

ASSISTANT_FILE="$(mktemp /tmp/mycelora-hook-stop-assistant.XXXXXX)"
CLEANUP_FILES+=("$ASSISTANT_FILE")

# Extraction session_id, transcript_path, prompt_id, cwd + ecriture de
# last_assistant_message brut dans ASSISTANT_FILE (4 lignes sur stdout :
# session_id, transcript_path, prompt_id, cwd)
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
    print("")
    sys.exit(0)

session_id = data.get("session_id", "") or ""
transcript_path = data.get("transcript_path", "") or ""
prompt_id = data.get("prompt_id", "") or ""
cwd = data.get("cwd", "") or ""
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
print(cwd)
PYEOF
)"

SESSION_ID="$(printf '%s\n' "$META_OUT" | sed -n '1p')"
TRANSCRIPT_PATH="$(printf '%s\n' "$META_OUT" | sed -n '2p')"
PROMPT_ID="$(printf '%s\n' "$META_OUT" | sed -n '3p')"
CWD="$(printf '%s\n' "$META_OUT" | sed -n '4p')"

# Hook session token, read from the cache. Without a token the hook is
# inert (first message of a thread, before the opening: normal case, never
# a visible error).
mycelora_resolve_hook_token "$SESSION_ID" "$TRANSCRIPT_PATH"
if [ -z "${MYCELORA_HOOK_TOKEN:-}" ]; then
  mycelora_log "stop" "auth" 0 "sans-jeton" 0
  exit 0
fi

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
            message = entry.get("message")
            if not isinstance(message, dict):
                continue
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

LAST_USER_FILE="$(mktemp /tmp/mycelora-hook-stop-user.XXXXXX)"
CLEANUP_FILES+=("$LAST_USER_FILE")

USER_DECISION="$(find_last_user "$TRANSCRIPT_PATH" "$LAST_USER_FILE" "$PROMPT_ID")"

if [ "$USER_DECISION" != "FOUND" ]; then
  sleep 0.4
  USER_DECISION="$(find_last_user "$TRANSCRIPT_PATH" "$LAST_USER_FILE" "$PROMPT_ID")"
fi

if [ "$USER_DECISION" != "FOUND" ]; then
  DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"
  mycelora_log "stop" "log_exchange" "$DURATION_MS" "no-user-message" 0
  exit 0
fi

# System filter (notifications only, NO length filter: an "ok" is a valid
# exchange at Stop). "Rappel interne :" is a conventional prefix of
# scheduled wakeup messages: those flows carry no
# "[SYSTEM NOTIFICATION - NOT USER INPUT]" prefix at hook level (only at
# the conversation level of the model). Known limit: a wakeup with a
# free-form label (no "Rappel interne :" prefix) still passes this filter
# and is archived as a human exchange.
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
  mycelora_log "stop" "log_exchange" "$DURATION_MS" "filtered-system" 0
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
  mycelora_log "stop" "log_exchange" "$DURATION_MS" "empty-message" 0
  exit 0
fi

# ONE single pass for the three thread labels (space, technical name,
# human title). Do not call mycelora_resolve_space_id then
# mycelora_resolve_etiquettes in turn: that would be two python processes
# for the same read.
FIL_META="$(_mycelora_charger_fil "$SESSION_ID" "$TRANSCRIPT_PATH")"
SPACE_ID="$(printf '%s\n' "$FIL_META" | sed -n '1p')"
SESSION_LABEL="$(printf '%s\n' "$FIL_META" | sed -n '2p')"
CUSTOM_TITLE="$(printf '%s\n' "$FIL_META" | sed -n '3p')"

BODY_FILE="$(mktemp /tmp/mycelora-hook-stop-body.XXXXXX)"
CLEANUP_FILES+=("$BODY_FILE")

# Acknowledgment of the injections of the turn. The UserPromptSubmit hook
# appended each batch actually injected to this file (one lot_id per line);
# it is replayed in ackLotIds so the server confirms the session_injections
# rows. Deleted only after a 2xx (below): on failure or timeout it stays,
# retried at the next Stop.
ACK_SESSION="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
ACK_FILE="/tmp/mycelora-ack-${ACK_SESSION}"
if [ -z "$ACK_SESSION" ] || [ ! -f "$ACK_FILE" ]; then
  ACK_FILE=""
fi

# Local reflex log, same session filter as mycelora_reflexe_log. Replayed
# in "reflexes" just as ackLotIds is for batches, deleted only after a
# 2xx (below): on failure or timeout it stays, retried at the next Stop.
REFLEXES_SESSION="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
REFLEXES_FILE="/tmp/mycelora-reflexes-${REFLEXES_SESSION}.jsonl"
if [ -z "$REFLEXES_SESSION" ] || [ ! -f "$REFLEXES_FILE" ]; then
  REFLEXES_FILE=""
fi

python3 - "$LAST_USER_FILE" "$ASSISTANT_FILE" "$SESSION_ID" "$SPACE_ID" "$BODY_FILE" "$SESSION_LABEL" "$CUSTOM_TITLE" "$ACK_FILE" "$REFLEXES_FILE" "$CWD" <<'PYEOF'
import json, os, re, sys

user_path, assistant_path, session_id, space_id, body_path = sys.argv[1:6]
session_label = sys.argv[6] if len(sys.argv) > 6 else ""
custom_title = sys.argv[7] if len(sys.argv) > 7 else ""
ack_path = sys.argv[8] if len(sys.argv) > 8 else ""
reflexes_path = sys.argv[9] if len(sys.argv) > 9 else ""
cwd = sys.argv[10] if len(sys.argv) > 10 else ""

def read_file(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return ""

user_message = read_file(user_path)
assistant_response = read_file(assistant_path)

# No userId: the server enforces the identity resolved from the token.
arguments = {
    "sessionId": session_id,
    "userMessage": user_message,
    "assistantResponse": assistant_response,
}
if space_id:
    arguments["spaceId"] = space_id
# Thread labels. Omitted when unknown, never invented: a thread opened
# before the first session_start has no technical name, and a thread never
# renamed may have no human title.
if session_label:
    arguments["sessionLabel"] = session_label
if custom_title:
    arguments["customTitle"] = custom_title

# Batches to confirm, one uuid per line, deduplicated keeping order, cap
# 50 (aligned with the server). Unreadable or empty file: nothing is sent,
# never an invented list.
if ack_path:
    uuid_re = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
    lots = []
    for line in read_file(ack_path).splitlines():
        lot = line.strip()
        if uuid_re.match(lot) and lot not in lots:
            lots.append(lot)
    if lots:
        arguments["ackLotIds"] = lots[:50]

# Local reflex log: one JSON object per valid line of the file; invalid
# lines are silently ignored (the hook never fails). Absent from the body
# if no line is valid (same posture as an absent ackLotIds).
if reflexes_path:
    entries = []
    for line in read_file(reflexes_path).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            entries.append(obj)
    if entries:
        # question_humain: set when a "?" appears in the assistant reply of
        # this turn (simple presence, no NLP). The flag is set on the MOST
        # RECENT line among those with evt == "refus"; none if the batch has
        # no refusal (no line is ever created).
        #
        # The most recent refusal is the LAST element of the filtered list
        # (refus_entries[-1]), for two reasons:
        # 1. Fail-open: a valid JSON line with an unexpected TYPE (e.g.
        #    "t":5, an integer) would make a max() raise an uncaught
        #    TypeError (str/int comparison), outside any try: the whole
        #    python block would die before json.dump(payload, ...), BODY_FILE
        #    would stay empty, curl would send an empty body, the non-2xx
        #    response would prevent the purge, and EVERY following Stop would
        #    crash again on the same poisoned line (silent freeze of the
        #    whole mycelora_log_exchange, not only reflexes). Entries whose
        #    "evt" or "t" are not strings are therefore excluded from THIS
        #    logic (not from the "reflexes" array sent, which keeps them
        #    all) before any computation.
        # 2. Ties: "t" has a ONE SECOND resolution (mycelora_reflexe_log,
        #    format %Y-%m-%dT%H:%M:%SZ); two refusals in the same second
        #    have an identical "t", and max() would return the FIRST one met
        #    (the OLDEST in the file), not the most recent. The log being
        #    append-only and read in write order, the LAST element is both
        #    simpler (no fragile max()/key) and correct even on a tie.
        signal_question = "?" in assistant_response
        if signal_question:
            refus_entries = [
                e for e in entries
                if isinstance(e.get("evt"), str) and e.get("evt") == "refus"
                and isinstance(e.get("t"), str)
            ]
            if refus_entries:
                refus_entries[-1]["question_humain"] = True
        arguments["reflexes"] = entries

payload = {
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {"name": "mycelora_log_exchange", "arguments": arguments},
    "id": 1,
}

with open(body_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF

CFGFILE="$(mktemp /tmp/mycelora-hook-stop-cfg.XXXXXX)"
CLEANUP_FILES+=("$CFGFILE")
RESP_FILE="$(mktemp /tmp/mycelora-hook-stop-resp.XXXXXX)"
CLEANUP_FILES+=("$RESP_FILE")

mycelora_curl_post "$BODY_FILE" "$CFGFILE" "$RESP_FILE"
CURL_RC="${MYCELORA_LAST_CURL_RC:-1}"
HTTP_CODE="${MYCELORA_LAST_HTTP_CODE:-000}"
RESP_SIZE="$(wc -c < "$RESP_FILE" 2>/dev/null | tr -d ' ')"
RESP_SIZE="${RESP_SIZE:-0}"
DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"

if [ "$CURL_RC" -ne 0 ]; then
  mycelora_log "stop" "log_exchange" "$DURATION_MS" "timeout" "$RESP_SIZE"
  exit 0
fi

case "$HTTP_CODE" in
  2??)
    mycelora_log "stop" "log_exchange" "$DURATION_MS" "ok" "$RESP_SIZE"
    # Acknowledgments delivered, the batch file leaves with the turn. On
    # timeout or HTTP error (branches above/below) it STAYS in place and is
    # replayed at the next Stop of the thread (the late ack confirms).
    if [ -n "$ACK_FILE" ]; then
      rm -f "$ACK_FILE" 2>/dev/null || true
    fi
    # Same semantics as the batch acknowledgment: the local reflex log is
    # purged ONLY after this 2xx.
    if [ -n "$REFLEXES_FILE" ]; then
      rm -f "$REFLEXES_FILE" 2>/dev/null || true
    fi
    ;;
  401)
    # Typed 401 (token expired/revoked) -> stay silent, this hook NEVER
    # writes to stdout. A generic 401 stays in "*)".
    if grep -q '"jeton_session_expire"' "$RESP_FILE" 2>/dev/null; then
      mycelora_log "stop" "auth" "$DURATION_MS" "jeton-expire" "$RESP_SIZE"
    else
      mycelora_log "stop" "log_exchange" "$DURATION_MS" "error-http-$HTTP_CODE" "$RESP_SIZE"
    fi
    ;;
  *) mycelora_log "stop" "log_exchange" "$DURATION_MS" "error-http-$HTTP_CODE" "$RESP_SIZE" ;;
esac

exit 0
