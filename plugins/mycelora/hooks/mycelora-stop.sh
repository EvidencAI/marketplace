#!/usr/bin/env bash
# Hook Stop : retrouve le dernier message utilisateur reel dans le
# transcript, filtre les notifications systeme, appelle mnemos_log_exchange
# sur l'edge en fire-and-forget. AUCUNE sortie stdout, jamais. exit 0 dans
# tous les cas.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/mycelora-common.sh"

MYCELORA_HOOK_TOKEN="__MYCELORA_HOOK_KEY__"

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

# S-ALIAS-1 (fil 76, 24/08/2026) : UNE seule passe pour les trois etiquettes
# du fil (espace, nom technique, titre humain). Ne pas appeler successivement
# mycelora_resolve_space_id puis mycelora_resolve_etiquettes : ce serait deux
# processus python pour la meme lecture.
FIL_META="$(_mycelora_charger_fil "$SESSION_ID" "$TRANSCRIPT_PATH")"
SPACE_ID="$(printf '%s\n' "$FIL_META" | sed -n '1p')"
SESSION_LABEL="$(printf '%s\n' "$FIL_META" | sed -n '2p')"
CUSTOM_TITLE="$(printf '%s\n' "$FIL_META" | sed -n '3p')"

BODY_FILE="$(mktemp /tmp/mycelora-hook-stop-body.XXXXXX)"
CLEANUP_FILES+=("$BODY_FILE")

# S-ACK-1 (29/08/2026) : accuse de reception des injections du tour. Le hook
# UserPromptSubmit a appose chaque lot reellement injecte dans ce fichier
# (un lot_id par ligne) ; on le rejoue dans ackLotIds pour que le serveur
# confirme les lignes session_injections. Supprime seulement apres un 2xx
# (plus bas) : sur echec ou timeout il reste, retente au Stop suivant.
ACK_SESSION="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
ACK_FILE="/tmp/mycelora-ack-${ACK_SESSION}"
if [ -z "$ACK_SESSION" ] || [ ! -f "$ACK_FILE" ]; then
  ACK_FILE=""
fi

# S-REFLEXES-5b (02/09/2026) : journal local des reflexes (S-REFLEXES-2),
# meme filtre de session que mycelora_reflexe_log. Rejoue dans "reflexes" au
# meme titre que ackLotIds l'est pour les lots, supprime seulement apres un
# 2xx (plus bas) : sur echec ou timeout il reste, retente au Stop suivant.
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

arguments = {
    "userId": "stephane",
    "sessionId": session_id,
    "userMessage": user_message,
    "assistantResponse": assistant_response,
}
if space_id:
    arguments["spaceId"] = space_id
# S-ALIAS-1 : etiquettes du fil. Omises quand inconnues, jamais inventees
# (regle R4) : un fil ouvert avant le premier session_start n'a pas de nom
# technique, et un fil jamais renomme peut n'avoir aucun titre humain.
if session_label:
    arguments["sessionLabel"] = session_label
if custom_title:
    arguments["customTitle"] = custom_title

# S-ACK-1 : lots a confirmer, un uuid par ligne, dedupliques en gardant
# l'ordre, plafond 50 (aligne sur le serveur). Fichier illisible ou vide :
# on n'envoie rien, jamais une liste inventee.
if ack_path:
    uuid_re = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
    lots = []
    for line in read_file(ack_path).splitlines():
        lot = line.strip()
        if uuid_re.match(lot) and lot not in lots:
            lots.append(lot)
    if lots:
        arguments["ackLotIds"] = lots[:50]

# S-REFLEXES-5b : journal local des reflexes (S-REFLEXES-2), un objet JSON
# par ligne valide du fichier ; lignes invalides ignorees silencieusement
# (jamais d'echec du hook). Absent du corps si aucune ligne valide (meme
# posture que ackLotIds absent).
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
        # question_humain : signal (a) un fichier .cc-attente-decision.md
        # existe directement dans cwd (pas de recherche recursive), signal
        # (b) presence d'un "?" dans la reponse assistant de ce tour
        # (approximation actee a l'audit -- simple presence, pas de NLP). Si
        # (a) OU (b), pose sur la ligne la PLUS RECENTE parmi celles dont
        # evt == "refus" -- aucune si aucun refus dans le lot (jamais de
        # ligne creee).
        #
        # CORRECTION (revue coordinateur, apres ff82375) : deux bugs sur
        # l'ancienne implementation `max(refus_entries, key=lambda e:
        # e.get("t") or "")`.
        # 1. Fail-open casse : une ligne JSON valide mais au TYPE inattendu
        #    (ex. "t":5, un entier) faisait planter ce max() avec un
        #    TypeError NON attrape (comparaison str/int), hors de tout try —
        #    le bloc python entier mourait avant json.dump(payload, ...),
        #    BODY_FILE restait vide, curl envoyait un corps vide, la reponse
        #    non-2xx empechait la purge, et CHAQUE Stop suivant recrashait a
        #    l'identique sur la meme ligne empoisonnee (gel silencieux de
        #    tout mnemos_log_exchange du fil, pas seulement reflexes). Les
        #    entrees dont "evt" ou "t" ne sont pas des chaines sont
        #    desormais exclues de CETTE logique (pas du tableau "reflexes"
        #    envoye, qui les garde toutes) avant tout calcul.
        # 2. "le plus recent" errone en cas d'egalite de "t" : "t" a une
        #    resolution d'UNE SECONDE (mycelora_reflexe_log, format
        #    %Y-%m-%dT%H:%M:%SZ) ; deux refus dans la meme seconde ont un
        #    "t" identique, et max() renvoyait alors le PREMIER rencontre
        #    (le plus ANCIEN dans le fichier), pas le plus recent. Le
        #    journal etant append-only et lu dans l'ordre chronologique
        #    d'ecriture, le DERNIER element de la liste filtree
        #    (refus_entries[-1]) est a la fois plus simple (plus de
        #    max()/key fragile) et correct meme a egalite de seconde.
        signal_decision = bool(cwd) and os.path.exists(os.path.join(cwd, ".cc-attente-decision.md"))
        signal_question = "?" in assistant_response
        if signal_decision or signal_question:
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
    "params": {"name": "mnemos_log_exchange", "arguments": arguments},
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
    # S-ACK-1 : accuses livres, le fichier de lots part avec le tour. Sur
    # timeout ou erreur HTTP (branches ci-dessus/dessous), il RESTE en place
    # et sera rejoue au prochain Stop du fil (l'accuse tardif confirme).
    if [ -n "$ACK_FILE" ]; then
      rm -f "$ACK_FILE" 2>/dev/null || true
    fi
    # S-REFLEXES-5b : meme semantique que l'accuse de lots -- purge du
    # journal local des reflexes SEULEMENT apres ce 2xx.
    if [ -n "$REFLEXES_FILE" ]; then
      rm -f "$REFLEXES_FILE" 2>/dev/null || true
    fi
    ;;
  *) mycelora_log "stop" "log_exchange" "$DURATION_MS" "error-http-$HTTP_CODE" "$RESP_SIZE" ;;
esac

exit 0
