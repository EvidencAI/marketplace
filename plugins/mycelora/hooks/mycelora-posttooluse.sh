#!/usr/bin/env bash
# Hook PostToolUse : jalon d'impact (S-REFLEXES-2). Apres un geste
# structurant EXECUTE (Bash DDL/UPDATE-DELETE/infra deja repere par
# mycelora-pretooluse.sh, OU edition d'un fichier sensible via Edit/Write/
# MultiEdit — INFORMATION seule, jamais de refus a ce stade), pose un
# additionalContext "JALON D'IMPACT : ..." et le marqueur .carte-perimee.
# Sortie stdout = JSON de decision UNIQUEMENT quand il y a un jalon (rien du
# tout sinon). exit 0 dans tous les cas.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/mycelora-common.sh"

# Jeton hook : variable CLAUDE_PLUGIN_OPTION_HOOK_KEY (userConfig hook_key, canal
# marketplace, saisie a l'activation et rangee dans le trousseau) si elle est
# definie, sinon la valeur substituee dans le zip par build-plugin-zip.sh.
MYCELORA_HOOK_TOKEN="${CLAUDE_PLUGIN_OPTION_HOOK_KEY:-__MYCELORA_HOOK_KEY__}"

CLEANUP_FILES=()
cleanup_and_exit() {
  local f
  for f in "${CLEANUP_FILES[@]:-}"; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null
  done
  exit 0
}
trap cleanup_and_exit EXIT INT TERM

STDIN_FILE="$(mktemp /tmp/mycelora-hook-post-stdin.XXXXXX)"
CLEANUP_FILES+=("$STDIN_FILE")
cat > "$STDIN_FILE"

# ----------------------------------------------------------------------------
# CHEMIN RAPIDE (bash pur, AUCUN python demarre) : seuls Bash (niveau 1,
# gestes deja repérés par mycelora-pretooluse.sh) et Edit/Write/MultiEdit
# (niveau 2, fichiers sensibles) portent une regle en v1. Aucun outil MCP
# n'a de regle de jalon definie (brief section 4.2) : tout le reste sort
# ici. mycelora_log est du bash pur (date/wc/printf, aucun python).
# ----------------------------------------------------------------------------
TOOL_NAME="$(grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$STDIN_FILE" | head -n 1 | sed -E 's/.*"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/')"
case "$TOOL_NAME" in
  Bash|Edit|Write|MultiEdit) ;;
  *)
    mycelora_log "posttooluse" "detect" 0 "skip-out-of-scope" 0
    exit 0
    ;;
esac

# A partir d'ici seulement : ca vaut le cout de python.
START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"

# Champs communs (session_id, cwd, transcript_path, file_path) : un seul
# appel python, quel que soit l'outil.
META_FILE="$(mktemp /tmp/mycelora-hook-post-meta.XXXXXX)"
CLEANUP_FILES+=("$META_FILE")
python3 - "$STDIN_FILE" "$META_FILE" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    data = {}
tool_input = data.get("tool_input")
if not isinstance(tool_input, dict):
    tool_input = {}
sortie = {
    "session_id": data.get("session_id", "") or "",
    "cwd": data.get("cwd", "") or "",
    "transcript_path": data.get("transcript_path", "") or "",
    "file_path": tool_input.get("file_path", "") or "",
}
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(sortie, f, ensure_ascii=False)
PYEOF

SESSION_ID="$(python3 -c "import json; print(json.load(open('$META_FILE')).get('session_id',''))" 2>/dev/null || echo '')"
CWD="$(python3 -c "import json; print(json.load(open('$META_FILE')).get('cwd',''))" 2>/dev/null || echo '')"
TRANSCRIPT_PATH="$(python3 -c "import json; print(json.load(open('$META_FILE')).get('transcript_path',''))" 2>/dev/null || echo '')"
FILE_PATH="$(python3 -c "import json; print(json.load(open('$META_FILE')).get('file_path',''))" 2>/dev/null || echo '')"

REPO_ROOT="$(mycelora_repo_root "$CWD")"
DESARME="$(mycelora_reflexe_desarme "$REPO_ROOT")"
if [ "$DESARME" = "1" ]; then
  mycelora_reflexe_log "$SESSION_ID" "desarme" "$TOOL_NAME" "[]" "" "0"
  mycelora_log "posttooluse" "detect" 0 "desarme" 0
  exit 0
fi

OBJETS_JSON="[]"
ACTION=""
LOCAL_RESULT_FILE=""
SERVER_RESULT_FILE=""
EMPREINTE=""

if [ "$TOOL_NAME" = "Bash" ]; then
  DETECTION_FILE="$(mktemp /tmp/mycelora-hook-post-detect.XXXXXX)"
  CLEANUP_FILES+=("$DETECTION_FILE")
  mycelora_reflexe_detecter "$STDIN_FILE" "$DETECTION_FILE"

  OK="$(python3 -c "
import json
try:
    print('1' if json.load(open('$DETECTION_FILE')).get('ok') else '0')
except Exception:
    print('0')
" 2>/dev/null || echo 0)"

  if [ "$OK" != "1" ]; then
    mycelora_log "posttooluse" "detect" 0 "no-match" 0
    exit 0
  fi

  GESTE="$(python3 -c "import json; print(json.load(open('$DETECTION_FILE')).get('geste') or '')" 2>/dev/null || echo '')"
  EMPREINTE="$(python3 -c "import json; print(json.load(open('$DETECTION_FILE')).get('empreinte') or '')" 2>/dev/null || echo '')"
  OBJETS_JSON="$(python3 -c "import json; print(json.dumps(json.load(open('$DETECTION_FILE')).get('objets') or []))" 2>/dev/null || echo '[]')"

  LOCAL_RESULT_FILE="$(mktemp /tmp/mycelora-hook-post-local.XXXXXX)"
  CLEANUP_FILES+=("$LOCAL_RESULT_FILE")
  SERVER_RESULT_FILE="$(mktemp /tmp/mycelora-hook-post-server.XXXXXX)"
  CLEANUP_FILES+=("$SERVER_RESULT_FILE")

  if [ "$GESTE" = "infra" ]; then
    ACTION="exécuté (geste d'infrastructure)"
    printf '{"resultats": {}}' > "$LOCAL_RESULT_FILE"
    printf '{}' > "$SERVER_RESULT_FILE"
  else
    ACTION="modifié"
    mycelora_reflexe_grep_local "$REPO_ROOT" "$OBJETS_JSON" "$LOCAL_RESULT_FILE"

    NON_RESOLUS_FILE="$(mktemp /tmp/mycelora-hook-post-nonresolus.XXXXXX)"
    CLEANUP_FILES+=("$NON_RESOLUS_FILE")
    mycelora_reflexe_objets_non_resolus "$LOCAL_RESULT_FILE" "$OBJETS_JSON" "$NON_RESOLUS_FILE"
    A_INTERROGER_COUNT="$(python3 -c "
import json
try:
    print(len(json.load(open('$NON_RESOLUS_FILE'))))
except Exception:
    print(0)
" 2>/dev/null || echo 0)"

    if [ "${A_INTERROGER_COUNT:-0}" -gt 0 ] 2>/dev/null; then
      SPACE_ID=""
      if [ -n "$TRANSCRIPT_PATH" ]; then
        SPACE_ID="$(mycelora_resolve_space_id "$SESSION_ID" "$TRANSCRIPT_PATH")"
      fi
      A_INTERROGER_JSON="$(cat "$NON_RESOLUS_FILE")"
      LOOKUP_CFGFILE="$(mktemp /tmp/mycelora-hook-post-lookup-cfg.XXXXXX)"
      CLEANUP_FILES+=("$LOOKUP_CFGFILE")
      LOOKUP_CURL_RESP="$(mktemp /tmp/mycelora-hook-post-lookup-resp.XXXXXX)"
      CLEANUP_FILES+=("$LOOKUP_CURL_RESP")
      mycelora_reflexe_lookup_serveur "$SPACE_ID" "$A_INTERROGER_JSON" "$SERVER_RESULT_FILE" "$LOOKUP_CFGFILE" "$LOOKUP_CURL_RESP"
      if [ -n "${MYCELORA_REFLEXE_LOOKUP_EVT:-}" ]; then
        mycelora_reflexe_log "$SESSION_ID" "${MYCELORA_REFLEXE_LOOKUP_EVT}" "$TOOL_NAME" "$OBJETS_JSON" "$EMPREINTE" "0"
      fi
    else
      printf '{}' > "$SERVER_RESULT_FILE"
    fi
  fi
else
  # Edit / Write / MultiEdit : niveau 2, fichier sensible uniquement.
  CATEGORIE="$(mycelora_reflexe_fichier_sensible "$FILE_PATH")"
  if [ -z "$CATEGORIE" ]; then
    mycelora_log "posttooluse" "detect" 0 "skip-not-sensitive" 0
    exit 0
  fi

  LOCAL_RESULT_FILE="$(mktemp /tmp/mycelora-hook-post-local.XXXXXX)"
  CLEANUP_FILES+=("$LOCAL_RESULT_FILE")
  SERVER_RESULT_FILE="$(mktemp /tmp/mycelora-hook-post-server.XXXXXX)"
  CLEANUP_FILES+=("$SERVER_RESULT_FILE")
  printf '{"resultats": {}}' > "$LOCAL_RESULT_FILE"
  printf '{}' > "$SERVER_RESULT_FILE"

  if [ "$CATEGORIE" = "edge_index" ]; then
    EDGE_NOM="$(printf '%s' "$FILE_PATH" | sed -E 's#.*/supabase/functions/([a-zA-Z0-9_-]+)/index\.ts$#\1#')"
    if [ -n "$EDGE_NOM" ] && [ "$EDGE_NOM" != "$FILE_PATH" ]; then
      OBJETS_JSON="$(python3 -c "import json,sys; print(json.dumps([sys.argv[1]]))" "$EDGE_NOM")"
      SPACE_ID=""
      if [ -n "$TRANSCRIPT_PATH" ]; then
        SPACE_ID="$(mycelora_resolve_space_id "$SESSION_ID" "$TRANSCRIPT_PATH")"
      fi
      LOOKUP_CFGFILE="$(mktemp /tmp/mycelora-hook-post-lookup-cfg.XXXXXX)"
      CLEANUP_FILES+=("$LOOKUP_CFGFILE")
      LOOKUP_CURL_RESP="$(mktemp /tmp/mycelora-hook-post-lookup-resp.XXXXXX)"
      CLEANUP_FILES+=("$LOOKUP_CURL_RESP")
      mycelora_reflexe_lookup_serveur "$SPACE_ID" "$OBJETS_JSON" "$SERVER_RESULT_FILE" "$LOOKUP_CFGFILE" "$LOOKUP_CURL_RESP"
    else
      OBJETS_JSON="$(python3 -c "import json,sys; print(json.dumps([sys.argv[1]]))" "$FILE_PATH")"
    fi
  else
    OBJETS_JSON="$(python3 -c "import json,sys; print(json.dumps([sys.argv[1]]))" "$FILE_PATH")"
  fi
  ACTION="édité (fichier sensible : $CATEGORIE)"
  EMPREINTE="$(printf '%s' "$FILE_PATH" | shasum -a 1 2>/dev/null | awk '{print $1}')"
fi

REPORT_FILE="$(mktemp /tmp/mycelora-hook-post-report.XXXXXX)"
CLEANUP_FILES+=("$REPORT_FILE")
mycelora_reflexe_construire_jalon "$OBJETS_JSON" "$ACTION" "$LOCAL_RESULT_FILE" "$SERVER_RESULT_FILE" "$REPORT_FILE"

mycelora_reflexe_marquer_carte_perimee "$REPO_ROOT" "$OBJETS_JSON"
mycelora_reflexe_log "$SESSION_ID" "jalon" "$TOOL_NAME" "$OBJETS_JSON" "$EMPREINTE" "0"

DURATION_MS="$(python3 -c "import time; print(int(time.time()*1000) - $START_MS)")"
mycelora_log "posttooluse" "detect" "$DURATION_MS" "jalon" 0

python3 - "$REPORT_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    texte = f.read()
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": texte,
    }
}, ensure_ascii=False))
PYEOF

exit 0
