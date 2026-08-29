#!/usr/bin/env bash
# Hook UserPromptSubmit : filtre les prompts, resout le spaceId, appelle
# mnemos_recall sur l'edge, recopie le bloc FACE-A tel quel sur stdout.
# Sortie stdout = texte brut uniquement, jamais de JSON. exit 0 dans tous
# les cas (succes, filtre, erreur reseau, JSON invalide, exception python).

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

STDIN_FILE="$(mktemp /tmp/mycelora-hook-ups-stdin.XXXXXX)"
CLEANUP_FILES+=("$STDIN_FILE")
cat > "$STDIN_FILE"

PROMPT_FILE="$(mktemp /tmp/mycelora-hook-ups-prompt.XXXXXX)"
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
# --------------------------------------------------------------------------
# FILTRE DU BRUIT (27/07/2026, fil 20). Deux ajouts, motives par un retour
# d'usage mesure sur le fil 19 (QUALITE-DES-ATOMES.md) : sur environ soixante
# injections, trois seulement ont change une decision, et une large part des
# messages declencheurs etaient des validations de trois mots.
#
# 1. RELANCES MACHINE. Le filtre existant ne couvrait que trois prefixes de
#    relance. "Continue from where you left off." (32 caracteres, aucun
#    marqueur) passait : PREUVE REELLE, quatre injections completes sont
#    parties sur ce message pendant le fil 20 lui-meme, alors qu'il n'est pas
#    de l'utilisateur.
#
# 2. VALIDATIONS SEULES. Un message compose UNIQUEMENT de marqueurs de
#    validation ("ok go", "c'est fait", "parfait merci") ne porte aucun signal
#    semantique : le recall y repond en servant des atomes lies au hasard des
#    mots "ok", "go", "fait". Le contexte du tour precedent suffit.
#
# LA CONJONCTION EST ESSENTIELLE : on ne filtre PAS sur la brievete seule.
# "et le DNS ?" est court mais porte une vraie question, il doit passer. Seul
# un message dont TOUS les mots sont des marqueurs est ecarte.
#
# CE FILTRE NE TOUCHE PAS LA COLLECTE : elle est faite par le hook Stop, qui
# est un fichier distinct. On perd une injection, jamais un souvenir.
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

arguments = {"userId": "stephane", "query": query}
if space_id:
    arguments["spaceId"] = space_id
if session_id:
    arguments["sessionId"] = session_id

payload = {
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {"name": "mnemos_recall", "arguments": arguments},
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

# S-ACK-1 (29/08/2026) : le serveur rend le lot du recall dans
# result._meta.lot_id. Protocole de sortie sur le chemin ok : ligne 1 le
# statut, ligne 2 le lot ("-" si absent), le bloc a partir de la ligne 3.
# Les autres statuts gardent leur ligne unique. ATTENTION bash 3.2 : ce
# bloc python vit dans une substitution $( ) ; PAS D APOSTROPHE dans les
# commentaires, le vieux parseur la compte comme une quote ouvrante.
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
    # S-ACK-1 : le bloc part reellement sur stdout, donc le lot est a
    # accuser en fin de tour. APPEND (jamais overwrite) : un message envoye
    # en cours de tour declenche un second UPS avant le Stop, les deux lots
    # doivent etre confirmes. Le fichier est lu puis supprime par
    # mycelora-stop.sh apres un log_exchange en 2xx.
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
