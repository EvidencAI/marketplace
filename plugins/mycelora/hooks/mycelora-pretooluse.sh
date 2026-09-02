#!/usr/bin/env bash
# Hook PreToolUse : reflexe d'impact (S-REFLEXES-2). Avant un geste
# structurant (DDL, UPDATE/DELETE de masse, operation prod), REFUSE une fois
# avec un rapport de qui lit/ecrit l'objet touche, puis laisse passer les
# gestes suivants sur le meme objet dans le meme fil. Sortie stdout = JSON de
# decision UNIQUEMENT quand on refuse (rien du tout quand on laisse passer).
# exit 0 dans tous les cas.

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

STDIN_FILE="$(mktemp /tmp/mycelora-hook-pre-stdin.XXXXXX)"
CLEANUP_FILES+=("$STDIN_FILE")
cat > "$STDIN_FILE"

# ----------------------------------------------------------------------------
# CHEMIN RAPIDE (bash pur, AUCUN python demarre) : seul l'outil Bash peut
# declencher un REFUS en v1 (le brief section 4.2 ne definit aucune regle de
# refus sur le contenu d'un outil MCP, ni sur Edit/Write/MultiEdit qui
# restent de niveau INFORMATION, PostToolUse seul). Extraction NAIVE
# (grep/sed) du seul champ tool_name : suffisante ici, robuste tant que le
# nom d'outil ne porte pas de guillemet echappe (jamais le cas dans le
# catalogue Claude Code). mycelora_log est du bash pur (date/wc/printf,
# aucun python) : l'appeler ici ne rompt pas le chemin rapide.
# ----------------------------------------------------------------------------
TOOL_NAME="$(grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$STDIN_FILE" | head -n 1 | sed -E 's/.*"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/')"
if [ "$TOOL_NAME" != "Bash" ]; then
  mycelora_log "pretooluse" "detect" 0 "skip-not-bash" 0
  exit 0
fi

# A partir d'ici seulement : ca vaut le cout de python (mesure de duree
# incluse, elle n'a pas de sens sur le chemin rapide ci-dessus).
START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"

DETECTION_FILE="$(mktemp /tmp/mycelora-hook-pre-detect.XXXXXX)"
CLEANUP_FILES+=("$DETECTION_FILE")
mycelora_reflexe_detecter "$STDIN_FILE" "$DETECTION_FILE"

FIELDS="$(python3 - "$DETECTION_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}

def ligne(v):
    return "" if v is None else str(v).replace("\n", " ")

print("1" if d.get("ok") else "0")
print(ligne(d.get("geste")))
print(ligne(d.get("sous_type")))
print(ligne(d.get("uid_valeur")))
print(ligne(d.get("session_id")))
print(ligne(d.get("cwd")))
print(ligne(d.get("transcript_path")))
print(ligne(d.get("fichier_lu")))
print(ligne(d.get("empreinte")))
print(json.dumps(d.get("objets") or []))
PYEOF
)"

OK="$(printf '%s\n' "$FIELDS" | sed -n '1p')"
GESTE="$(printf '%s\n' "$FIELDS" | sed -n '2p')"
SOUS_TYPE="$(printf '%s\n' "$FIELDS" | sed -n '3p')"
UID_VALEUR="$(printf '%s\n' "$FIELDS" | sed -n '4p')"
SESSION_ID="$(printf '%s\n' "$FIELDS" | sed -n '5p')"
CWD="$(printf '%s\n' "$FIELDS" | sed -n '6p')"
TRANSCRIPT_PATH="$(printf '%s\n' "$FIELDS" | sed -n '7p')"
FICHIER_LU="$(printf '%s\n' "$FIELDS" | sed -n '8p')"
EMPREINTE="$(printf '%s\n' "$FIELDS" | sed -n '9p')"
OBJETS_JSON="$(printf '%s\n' "$FIELDS" | sed -n '10p')"

DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"

if [ "$OK" != "1" ]; then
  mycelora_log "pretooluse" "detect" "$DURATION_MS" "no-match" 0
  exit 0
fi

REPO_ROOT="$(mycelora_repo_root "$CWD")"
DESARME="$(mycelora_reflexe_desarme "$REPO_ROOT")"
if [ "$DESARME" = "1" ]; then
  mycelora_reflexe_log "$SESSION_ID" "desarme" "Bash" "$OBJETS_JSON" "$EMPREINTE" "0"
  mycelora_log "pretooluse" "detect" "$DURATION_MS" "desarme" 0
  exit 0
fi

# Purge globale (tous fils) des marqueurs de plus de 24h, avant toute
# lecture/ecriture (contrat figé).
mycelora_purge_markers_anciens

SAFE_SESSION="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
MARKER_FILE=""
if [ -n "$SAFE_SESSION" ]; then
  MARKER_FILE="/tmp/mycelora-impact-${SAFE_SESSION}"
fi

# Refus UNIQUE par objet et par fil : si TOUS les objets de cette commande
# sont deja marques refuses pour ce fil, le geste passe (PostToolUse pose
# quand meme le jalon, independamment de ce refus).
NOUVEAUX_JSON="$(python3 - "$MARKER_FILE" "$OBJETS_JSON" <<'PYEOF'
import json, os, sys
marker_path, objets_json = sys.argv[1], sys.argv[2]
try:
    objets = json.loads(objets_json)
except Exception:
    objets = []
deja = set()
if marker_path and os.path.exists(marker_path):
    try:
        with open(marker_path, "r", encoding="utf-8") as f:
            deja = {l.strip() for l in f if l.strip()}
    except Exception:
        deja = set()
nouveaux = [o for o in objets if o not in deja]
print(json.dumps({"tous_deja_vus": len(nouveaux) == 0}))
PYEOF
)"
TOUS_DEJA_VUS="$(printf '%s' "$NOUVEAUX_JSON" | python3 -c "import json,sys; print('1' if json.load(sys.stdin).get('tous_deja_vus') else '0')" 2>/dev/null || echo 0)"

if [ "$TOUS_DEJA_VUS" = "1" ]; then
  mycelora_reflexe_log "$SESSION_ID" "passage" "Bash" "$OBJETS_JSON" "$EMPREINTE" "0"
  mycelora_log "pretooluse" "detect" "$DURATION_MS" "passage" 0
  exit 0
fi

# ----------------------------------------------------------------------------
# A partir d'ici : refus. Construction du rapport (contrat figé).
# ----------------------------------------------------------------------------
REPORT_FILE="$(mktemp /tmp/mycelora-hook-pre-report.XXXXXX)"
CLEANUP_FILES+=("$REPORT_FILE")
RAPPORT_VIDE_FLAG="0"
LOOKUP_EVT=""
CARTE_AGE_JOURS=""

if [ "$GESTE" = "infra" ]; then
  python3 - "$SOUS_TYPE" "$REPORT_FILE" <<'PYEOF'
import sys
sous_type, out_path = sys.argv[1], sys.argv[2]
LIBELLES = {
    "ssh_psql": "accès direct à la base de prod par SSH + docker exec + psql (hors migration versionnée)",
    "rsync": "rsync vers volumes/functions (déploiement hors pipeline standard)",
    "docker_restart": "redémarrage direct d'un conteneur docker en prod",
    "coolify_patch": "modification directe d'une variable d'environnement Coolify (PATCH .../envs)",
}
libelle = LIBELLES.get(sous_type, "geste d'infrastructure sensible")
lignes = [
    "RÉFLEXE D'IMPACT (refus unique, rejouez la commande telle quelle si les incidences sont traitées).",
    f"Objet : {libelle}.",
    "Portée : opération PROD directe, hors outillage habituel. Vérifiez vous-même l'impact avant de "
    "rejouer (qui d'autre dépend de cet état, existe-t-il une procédure versionnée à la place).",
]
with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lignes))
PYEOF
  RAPPORT_VIDE_FLAG="0"
else
  LOCAL_RESULT_FILE="$(mktemp /tmp/mycelora-hook-pre-local.XXXXXX)"
  CLEANUP_FILES+=("$LOCAL_RESULT_FILE")
  mycelora_reflexe_grep_local "$REPO_ROOT" "$OBJETS_JSON" "$LOCAL_RESULT_FILE"

  NON_RESOLUS_FILE="$(mktemp /tmp/mycelora-hook-pre-nonresolus.XXXXXX)"
  CLEANUP_FILES+=("$NON_RESOLUS_FILE")
  mycelora_reflexe_objets_non_resolus "$LOCAL_RESULT_FILE" "$OBJETS_JSON" "$NON_RESOLUS_FILE"

  A_INTERROGER_COUNT="$(python3 -c "
import json
try:
    with open('$NON_RESOLUS_FILE', encoding='utf-8') as f:
        print(len(json.load(f)))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"

  SERVER_RESULT_FILE="$(mktemp /tmp/mycelora-hook-pre-server.XXXXXX)"
  CLEANUP_FILES+=("$SERVER_RESULT_FILE")

  if [ "${A_INTERROGER_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    SPACE_ID=""
    if [ -n "$TRANSCRIPT_PATH" ]; then
      SPACE_ID="$(mycelora_resolve_space_id "$SESSION_ID" "$TRANSCRIPT_PATH")"
    fi
    A_INTERROGER_JSON="$(cat "$NON_RESOLUS_FILE")"

    LOOKUP_CFGFILE="$(mktemp /tmp/mycelora-hook-pre-lookup-cfg.XXXXXX)"
    CLEANUP_FILES+=("$LOOKUP_CFGFILE")
    LOOKUP_CURL_RESP="$(mktemp /tmp/mycelora-hook-pre-lookup-resp.XXXXXX)"
    CLEANUP_FILES+=("$LOOKUP_CURL_RESP")

    mycelora_reflexe_lookup_serveur "$SPACE_ID" "$A_INTERROGER_JSON" "$SERVER_RESULT_FILE" "$LOOKUP_CFGFILE" "$LOOKUP_CURL_RESP"
    LOOKUP_EVT="${MYCELORA_REFLEXE_LOOKUP_EVT:-}"
  else
    printf '{}' > "$SERVER_RESULT_FILE"
  fi

  META_FILE="$(mktemp /tmp/mycelora-hook-pre-meta.XXXXXX)"
  CLEANUP_FILES+=("$META_FILE")
  mycelora_reflexe_construire_rapport "$OBJETS_JSON" "$GESTE" "$SOUS_TYPE" "$UID_VALEUR" "$FICHIER_LU" "$LOOKUP_EVT" "$LOCAL_RESULT_FILE" "$SERVER_RESULT_FILE" "$REPORT_FILE" "$META_FILE"

  RAPPORT_VIDE_FLAG="$(python3 -c "
import json
try:
    with open('$META_FILE', encoding='utf-8') as f:
        d = json.load(f)
    print('1' if d.get('rapport_vide') else '0')
except Exception:
    print('0')
" 2>/dev/null || echo 0)"
  LOOKUP_EVT_META="$(python3 -c "
import json
try:
    with open('$META_FILE', encoding='utf-8') as f:
        d = json.load(f)
    print(d.get('lookup_evt') or '')
except Exception:
    print('')
" 2>/dev/null || echo '')"
  [ -n "$LOOKUP_EVT_META" ] && LOOKUP_EVT="$LOOKUP_EVT_META"
  CARTE_AGE_JOURS="$(python3 -c "
import json
try:
    with open('$META_FILE', encoding='utf-8') as f:
        d = json.load(f)
    v = d.get('carte_age_jours')
    print(v if isinstance(v, int) and not isinstance(v, bool) else '')
except Exception:
    print('')
" 2>/dev/null || echo '')"
fi

# Marque les N objets comme refuses pour ce fil (fusion avec l'existant).
if [ -n "$MARKER_FILE" ]; then
  python3 - "$MARKER_FILE" "$OBJETS_JSON" <<'PYEOF' 2>/dev/null || true
import json, sys
marker_path, objets_json = sys.argv[1], sys.argv[2]
try:
    objets = json.loads(objets_json)
except Exception:
    objets = []
deja = set()
try:
    with open(marker_path, "r", encoding="utf-8") as f:
        deja = {l.strip() for l in f if l.strip()}
except Exception:
    pass
total = deja | set(objets)
try:
    with open(marker_path, "w", encoding="utf-8") as f:
        for o in sorted(total):
            f.write(o + "\n")
except Exception:
    pass
PYEOF
fi

mycelora_reflexe_log "$SESSION_ID" "refus" "Bash" "$OBJETS_JSON" "$EMPREINTE" "$RAPPORT_VIDE_FLAG" "$CARTE_AGE_JOURS"
case "$LOOKUP_EVT" in
  lookup_timeout|lookup_erreur)
    mycelora_reflexe_log "$SESSION_ID" "$LOOKUP_EVT" "Bash" "$OBJETS_JSON" "$EMPREINTE" "$RAPPORT_VIDE_FLAG"
    ;;
esac
if [ "$RAPPORT_VIDE_FLAG" = "1" ]; then
  mycelora_reflexe_log "$SESSION_ID" "rapport_vide" "Bash" "$OBJETS_JSON" "$EMPREINTE" "1"
fi

DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"
mycelora_log "pretooluse" "detect" "$DURATION_MS" "refus" 0

python3 - "$REPORT_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    texte = f.read()
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": texte,
    }
}, ensure_ascii=False))
PYEOF

exit 0
