#!/usr/bin/env bash
# Hook UserPromptSubmit : filtre les prompts, resout le spaceId, appelle
# mycelora_recall sur l'edge, recopie le bloc FACE-A tel quel sur stdout.
# Sortie stdout = texte brut uniquement, jamais de JSON. exit 0 dans tous
# les cas (succes, filtre, erreur reseau, JSON invalide, exception python).

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

STDIN_FILE="$(mktemp /tmp/mycelora-hook-ups-stdin.XXXXXX)"
CLEANUP_FILES+=("$STDIN_FILE")
cat > "$STDIN_FILE"

PROMPT_FILE="$(mktemp /tmp/mycelora-hook-ups-prompt.XXXXXX)"
CLEANUP_FILES+=("$PROMPT_FILE")

# Extraction (session_id, transcript_path) + ecriture du prompt brut dans
# PROMPT_FILE + decision de filtrage (3 lignes sur stdout : session_id,
# transcript_path, decision "OK" ou "FILTERED").
EXTRACT_OUT="$(python3 - "$STDIN_FILE" "$PROMPT_FILE" <<'PYEOF'
import json, re, sys

stdin_path, prompt_path = sys.argv[1], sys.argv[2]

def retirer_rappels_tete(texte):
    # Retire chaque bloc system-reminder place en tete du texte. Un bloc
    # non ferme reste en place (il sera filtre plus loin).
    while True:
        m = re.match(r"\A\s*<system-reminder>.*?</system-reminder>", texte, re.S)
        if not m:
            break
        texte = texte[m.end():]
    return texte.lstrip()

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
prompt = retirer_rappels_tete(prompt)
session_id = data.get("session_id", "") or ""
transcript_path = data.get("transcript_path", "") or ""

try:
    with open(prompt_path, "w", encoding="utf-8") as f:
        f.write(prompt)
except Exception:
    pass

# "Rappel interne :" is a conventional prefix of scheduled wakeup messages.
# Those flows carry no "[SYSTEM NOTIFICATION - NOT USER INPUT]" prefix at
# hook level (only at the conversation level of the model). Known limit: a
# wakeup with a free-form label (no "Rappel interne :" prefix) still passes
# this filter.
# --------------------------------------------------------------------------
# NOISE FILTER. Two additions, motivated by usage measurements: out of about
# sixty injections, only three changed a decision, and a large share of the
# triggering messages were three-word validations.
#
# 1. MACHINE RESTARTS. The previous filter covered only three restart
#    prefixes. "Continue from where you left off." (32 characters, no
#    marker) got through: four full injections were sent on that message
#    although it does not come from the user.
#
# 2. VALIDATIONS ONLY. A message made ONLY of validation markers
#    ("ok go", "c'est fait", "parfait merci") carries no semantic signal:
#    recall answers by serving atoms linked at random to the words "ok",
#    "go", "fait". The context of the previous turn is enough.
#
# THE CONJUNCTION IS ESSENTIAL: we do NOT filter on brevity alone.
# "et le DNS ?" is short but carries a real question, it must pass. Only a
# message whose words are ALL markers is dropped.
#
# THIS FILTER DOES NOT AFFECT COLLECTION: collection is done by the Stop
# hook, a separate file. An injection is lost, never a memory.
# --------------------------------------------------------------------------

RELANCES_MACHINE = (
    "Continue from where you left off",
    "[Request interrupted",
    "Please continue from where you left off",
)

MARQUEURS_VALIDATION = {
    "ok", "oki", "okay", "go", "oui", "ouais", "yes", "yep",
    "parfait", "nickel", "top", "super", "genial", "génial", "excellent",
    "bien", "merci", "thanks", "vas", "y", "va", "allez", "lance", "lances",
    "continue", "poursuis", "c'est", "cest", "fait", "faite", "bon",
    "voila", "voilà", "ca", "ça", "marche", "impec", "d'accord", "daccord",
    "accord", "compris",
}

def est_relance_machine(texte):
    return any(texte.startswith(p) for p in RELANCES_MACHINE)

def est_validation_seule(texte):
    # Normalisation : minuscules, ponctuation courante remplacee par des
    # espaces. Les apostrophes sont CONSERVEES pour que "c'est" reste un
    # marqueur reconnaissable tel quel.
    normalise = texte.lower()
    for signe in ".,;:!?()[]{}\"/\\-_*#":
        normalise = normalise.replace(signe, " ")
    mots = [m for m in normalise.split() if m]
    if not mots or len(mots) > 5:
        return False
    return all(m in MARQUEURS_VALIDATION for m in mots)

trimmed = prompt.strip()
decision = "OK"
if len(trimmed) < 10:
    decision = "FILTERED"
elif est_relance_machine(trimmed):
    decision = "FILTERED"
elif est_validation_seule(trimmed):
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

# Hook session token, read from the cache. Without a token the hook is
# inert (first message of a thread, before the opening: normal case, never
# a visible error).
mycelora_resolve_hook_token "$SESSION_ID" "$TRANSCRIPT_PATH"
if [ -z "${MYCELORA_HOOK_TOKEN:-}" ]; then
  mycelora_log "userpromptsubmit" "auth" 0 "sans-jeton" 0
  exit 0
fi

DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"

if [ "$DECISION" != "OK" ]; then
  mycelora_log "userpromptsubmit" "filtered" "$DURATION_MS" "filtered" 0
  exit 0
fi

SPACE_ID="$(mycelora_resolve_space_id "$SESSION_ID" "$TRANSCRIPT_PATH")"

BODY_FILE="$(mktemp /tmp/mycelora-hook-ups-body.XXXXXX)"
CLEANUP_FILES+=("$BODY_FILE")

python3 - "$PROMPT_FILE" "$SPACE_ID" "$SESSION_ID" "$BODY_FILE" <<'PYEOF'
import json, sys

prompt_path, space_id, session_id, body_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(prompt_path, "r", encoding="utf-8") as f:
        prompt = f.read()
except Exception:
    prompt = ""

# Plafonne la query envoyee a l'embedding a 2000 caracteres (evite d'envoyer
# un gros collage de document entier), sans toucher au prompt original
# utilise par ailleurs pour le filtrage.
query = prompt[:2000]

# No userId: the server enforces the identity resolved from the token.
arguments = {"query": query}
if space_id:
    arguments["spaceId"] = space_id
if session_id:
    arguments["sessionId"] = session_id

payload = {
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {"name": "mycelora_recall", "arguments": arguments},
    "id": 1,
}

with open(body_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF

CFGFILE="$(mktemp /tmp/mycelora-hook-ups-cfg.XXXXXX)"
CLEANUP_FILES+=("$CFGFILE")
RESP_FILE="$(mktemp /tmp/mycelora-hook-ups-resp.XXXXXX)"
CLEANUP_FILES+=("$RESP_FILE")

mycelora_curl_post "$BODY_FILE" "$CFGFILE" "$RESP_FILE"
CURL_RC="${MYCELORA_LAST_CURL_RC:-1}"
HTTP_CODE="${MYCELORA_LAST_HTTP_CODE:-000}"

DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"
RESP_SIZE="$(wc -c < "$RESP_FILE" 2>/dev/null | tr -d ' ')"
RESP_SIZE="${RESP_SIZE:-0}"

if [ "$CURL_RC" -ne 0 ]; then
  mycelora_log "userpromptsubmit" "recall" "$DURATION_MS" "timeout" "$RESP_SIZE"
  exit 0
fi

case "$HTTP_CODE" in
  2??) : ;;
  401)
    # Typed 401 (hook session token expired or revoked): never silent, this
    # is the only hook that prints plain text on stdout. A generic 401
    # (unknown key) keeps the behavior of the "*)" branch.
    if grep -q '"jeton_session_expire"' "$RESP_FILE" 2>/dev/null; then
      mycelora_log "userpromptsubmit" "auth" "$DURATION_MS" "jeton-expire" "$RESP_SIZE"
      printf '%s' "Mycelora: session token expired, reopen the thread (mycelora_session_start) to restore memory."
      exit 0
    fi
    mycelora_log "userpromptsubmit" "recall" "$DURATION_MS" "error-http-$HTTP_CODE" "$RESP_SIZE"
    exit 0
    ;;
  *)
    mycelora_log "userpromptsubmit" "recall" "$DURATION_MS" "error-http-$HTTP_CODE" "$RESP_SIZE"
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

# The server returns the recall batch in result._meta.lot_id. Output
# protocol on the ok path: line 1 is the status, line 2 the batch ("-" if
# absent), the block starts at line 3. Other statuses keep their single
# line. WARNING bash 3.2: this python block lives inside a $( )
# substitution; NO APOSTROPHE in comments, the old parser counts it as an
# opening quote.
meta = result.get("_meta")
lot_id = ""
if isinstance(meta, dict) and isinstance(meta.get("lot_id"), str):
    lot_id = meta["lot_id"]

if isinstance(text, str) and text != "":
    print("ok")
    print(lot_id or "-")
    sys.stdout.write(text)
else:
    print("empty")
PYEOF
)"

STATUS="$(printf '%s\n' "$STATUS_AND_TEXT" | head -n 1)"
LOT_ID="$(printf '%s\n' "$STATUS_AND_TEXT" | sed -n '2p')"
TEXT="$(printf '%s\n' "$STATUS_AND_TEXT" | tail -n +3)"

case "$STATUS" in
  ok)
    # The block is really written to stdout, so its batch must be
    # acknowledged at the end of the turn. APPEND (never overwrite): a message
    # sent mid-turn triggers a second UserPromptSubmit before Stop, and both
    # batches must be confirmed. The file is read then deleted by
    # mycelora-stop.sh after a successful log_exchange.
    case "$LOT_ID" in
      [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-*)
        # Nom de fichier assaini : le session_id vient du stdin du hook.
        ACK_SESSION="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
        if [ -n "$ACK_SESSION" ]; then
          printf '%s\n' "$LOT_ID" >> "/tmp/mycelora-ack-${ACK_SESSION}" 2>/dev/null || true
        fi
        ;;
    esac
    mycelora_log "userpromptsubmit" "recall" "$DURATION_MS" "ok" "$RESP_SIZE"
    printf '%s' "$TEXT"
    ;;
  tool-error)
    mycelora_log "userpromptsubmit" "recall" "$DURATION_MS" "tool-error" "$RESP_SIZE"
    ;;
  *)
    mycelora_log "userpromptsubmit" "recall" "$DURATION_MS" "empty" "$RESP_SIZE"
    ;;
esac

exit 0
