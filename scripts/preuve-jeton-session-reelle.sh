#!/usr/bin/env bash
# Preuve reelle du jeton de session hook (S-REFLEXES-6, canal marketplace).
#
# Ce script n'est PAS un test unitaire parmi d'autres : c'est le
# DEMONSTRATEUR exige par le DoD de la story, distinct de
# plugins/mycelora/hooks/tests/run-unit-tests.sh. Il rejoue les QUATRE VRAIS
# scripts de hooks (mycelora-userpromptsubmit.sh, mycelora-stop.sh,
# mycelora-pretooluse.sh, mycelora-posttooluse.sh -- jamais une
# reimplementation) contre un extrait REEL de transcript deja complete d'une
# ligne de jeton (fixture transcript-session-start-avec-jeton.jsonl), avec un
# serveur factice local qui enregistre le bearer HTTP reellement recu (meme
# mecanisme que run-unit-tests.sh : un vrai binaire curl place en tete de
# PATH, aucun mock de bash, aucune fonction interceptee).
#
# Preuve produite :
#   1. les quatre hooks envoient bien Bearer mk_sess_FIXTURE0123456789,
#      extrait du transcript via le cache v3 (_mycelora_charger_fil) ;
#   2. apres un 401 type (jeton_session_expire) simule, UserPromptSubmit
#      imprime la ligne de relance exacte.
#
# Rejouable par n'importe qui, plus tard : aucune dependance a l'etat du
# depot au-dela des fichiers versionnes (fixture + hooks).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/plugins/mycelora/hooks"
FIXTURE_TRANSCRIPT="$HOOKS_DIR/tests/fixtures/transcript-session-start-avec-jeton.jsonl"
JETON_ATTENDU="mk_sess_FIXTURE0123456789"
SESSION_ID="preuve-reelle-jeton-0001"

echo "======================================================================"
echo "PREUVE REELLE -- jeton de session hook (S-REFLEXES-6)"
echo "======================================================================"
echo
echo "Objectif : montrer que les QUATRE VRAIS scripts de hooks (pas une"
echo "reimplementation) envoient bien le bearer mk_sess_... extrait d'un"
echo "extrait de transcript reel, puis qu'apres un 401 type simule,"
echo "UserPromptSubmit imprime la ligne de relance."
echo

if [ ! -f "$FIXTURE_TRANSCRIPT" ]; then
  echo "ERREUR : fixture introuvable : $FIXTURE_TRANSCRIPT"
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORKDIR"
  rm -f "/tmp/mycelora-impact-${SESSION_ID}" "/tmp/mycelora-reflexes-${SESSION_ID}.jsonl"
  rm -f "/tmp/mycelora-hook-${SESSION_ID}.json"
  # PostToolUse (etape 3) marque reellement .carte-perimee a la racine du
  # depot (effet de bord REEL et attendu du VRAI hook, pas simule) : nettoye
  # ici pour que ce script reste rejouable sans laisser de trace non
  # versionnee dans le worktree.
  rm -f "$REPO_ROOT/.carte-perimee"
}
trap cleanup EXIT

echo "--- Etape 1 : le transcript reel --------------------------------------"
echo "Repris tel quel depuis :"
echo "  $FIXTURE_TRANSCRIPT"
TRANSCRIPT="$WORKDIR/transcript.jsonl"
cp "$FIXTURE_TRANSCRIPT" "$TRANSCRIPT"
echo "Contenu (4 entrees JSONL ; la 3e porte le jeton dans le tool_result de"
echo "mnemos_session_start) :"
python3 -c "
import json
with open('$TRANSCRIPT', encoding='utf-8') as f:
    for i, line in enumerate(f, 1):
        d = json.loads(line)
        print('  ligne %d : type=%s' % (i, d.get('type')))
"
echo
echo "Jeton attendu (present dans le transcript, sur la ligne dediee"
echo "'[jeton-hook-session ...] mk_sess_...') : $JETON_ATTENDU"
echo

echo "--- Etape 2 : mise en place du faux serveur (curl factice) -----------"
echo "Meme mecanisme que les tests unitaires : un vrai binaire 'curl' place"
echo "en tete de PATH, qui n'appelle jamais le reseau, capture le CORPS"
echo "JSON-RPC (--data-binary) ET le fichier de config -K (donc l'en-tete"
echo "Authorization REELLEMENT envoye par mycelora_curl_post), et rend une"
echo "reponse canned au hook appelant."
echo

FAKE_BIN_DIR="$WORKDIR/bin"
mkdir -p "$FAKE_BIN_DIR"
cat > "$FAKE_BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
CALL_LOG="${MYCELORA_TEST_CURL_LOG:?MYCELORA_TEST_CURL_LOG non defini}"
RESP_BODY_FILE="${MYCELORA_TEST_CURL_RESPONSE:-}"
HTTP_CODE="${MYCELORA_TEST_CURL_HTTP_CODE:-200}"
echo "CALLED" >> "$CALL_LOG"
OUT_FILE=""
BODY_SRC=""
CFG_FILE=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    -o) i=$((i+1)); OUT_FILE="${args[$i]}" ;;
    --data-binary) i=$((i+1)); BODY_SRC="${args[$i]}" ;;
    -K) i=$((i+1)); CFG_FILE="${args[$i]}" ;;
  esac
  i=$((i+1))
done
if [ -n "$BODY_SRC" ] && [ -n "${MYCELORA_TEST_CAPTURE_BODY:-}" ]; then
  case "$BODY_SRC" in
    @*) cp "${BODY_SRC#@}" "$MYCELORA_TEST_CAPTURE_BODY" 2>/dev/null || true ;;
  esac
fi
if [ -n "$CFG_FILE" ] && [ -n "${MYCELORA_TEST_CAPTURE_CFG:-}" ]; then
  cp "$CFG_FILE" "$MYCELORA_TEST_CAPTURE_CFG" 2>/dev/null || true
fi
if [ -n "$OUT_FILE" ]; then
  if [ -n "$RESP_BODY_FILE" ] && [ -f "$RESP_BODY_FILE" ]; then
    cp "$RESP_BODY_FILE" "$OUT_FILE"
  else
    printf '' > "$OUT_FILE"
  fi
fi
printf '%s' "$HTTP_CODE"
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/curl"
export PATH="$FAKE_BIN_DIR:$PATH"
echo "Faux curl en place : $FAKE_BIN_DIR/curl"
echo "Verifie par resolution PATH : $(command -v curl)"
echo

ANOMALIE=0

check_bearer() {
  local nom="$1" cfg_file="$2"
  local ligne
  ligne="$(grep '^header = "Authorization:' "$cfg_file" 2>/dev/null || true)"
  echo "  Bearer capture pour $nom :"
  echo "    $ligne"
  if [ "$ligne" = "header = \"Authorization: Bearer $JETON_ATTENDU\"" ]; then
    echo "    -> CONFORME (bearer attendu Bearer $JETON_ATTENDU)"
  else
    echo "    -> ANOMALIE : bearer attendu 'Bearer $JETON_ATTENDU', ligne capturee ci-dessus"
    ANOMALIE=1
  fi
  echo
}

echo "======================================================================"
echo "Etape 3 : les QUATRE VRAIS scripts de hooks, contre ce transcript"
echo "======================================================================"
echo

# --- UserPromptSubmit -------------------------------------------------------
echo "--- mycelora-userpromptsubmit.sh --------------------------------------"
UPS_RESP="$WORKDIR/ups-resp.json"
cat > "$UPS_RESP" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"[Mycelora] Rappel de memoire : le jeton de session hook est bien en place sur ce fil (S-REFLEXES-6)."}]},"id":1}
EOF
UPS_STDIN="$WORKDIR/ups-stdin.json"
cat > "$UPS_STDIN" <<EOF
{
  "session_id": "$SESSION_ID",
  "transcript_path": "$TRANSCRIPT",
  "cwd": "$REPO_ROOT",
  "prompt_id": "preuve-reelle-ups-0001",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "peux-tu confirmer que le jeton de session hook est bien envoye sur ce fil ?"
}
EOF
UPS_CFG="$WORKDIR/ups-cfg.txt"
UPS_CALLLOG="$WORKDIR/ups-call.log"
echo "Prompt utilisateur : \"peux-tu confirmer que le jeton de session hook est bien envoye sur ce fil ?\""
echo "Lance : mycelora-userpromptsubmit.sh (stdin ci-dessus sur son entree standard)"
UPS_OUT="$(
  MYCELORA_TEST_CURL_LOG="$UPS_CALLLOG" \
  MYCELORA_TEST_CURL_RESPONSE="$UPS_RESP" \
  MYCELORA_TEST_CURL_HTTP_CODE="200" \
  MYCELORA_TEST_CAPTURE_CFG="$UPS_CFG" \
  "$HOOKS_DIR/mycelora-userpromptsubmit.sh" < "$UPS_STDIN"
)"
echo "Stdout du hook (ce qui serait injecte dans le contexte du modele) :"
echo "  $UPS_OUT"
echo
check_bearer "UserPromptSubmit (appel mnemos_recall)" "$UPS_CFG"

# --- Stop --------------------------------------------------------------
echo "--- mycelora-stop.sh ---------------------------------------------------"
STOP_RESP="$WORKDIR/stop-resp.json"
cat > "$STOP_RESP" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"{\"success\": true, \"sessionId\": \"preuve-reelle\"}"}]},"id":1}
EOF
STOP_STDIN="$WORKDIR/stop-stdin.json"
cat > "$STOP_STDIN" <<EOF
{
  "session_id": "$SESSION_ID",
  "transcript_path": "$TRANSCRIPT",
  "cwd": "$REPO_ROOT",
  "prompt_id": "preuve-reelle-stop-sans-correspondance",
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "Session Mnemos demarree sur le developpement Mycelora.",
  "background_tasks": [],
  "session_crons": []
}
EOF
STOP_CFG="$WORKDIR/stop-cfg.txt"
STOP_CALLLOG="$WORKDIR/stop-call.log"
echo "Dernier message assistant du tour : \"Session Mnemos demarree sur le developpement Mycelora.\""
echo "(retrouve dans le transcript comme le message utilisateur d'ouverture)"
echo "Lance : mycelora-stop.sh (stdin ci-dessus sur son entree standard)"
STOP_OUT="$(
  MYCELORA_TEST_CURL_LOG="$STOP_CALLLOG" \
  MYCELORA_TEST_CURL_RESPONSE="$STOP_RESP" \
  MYCELORA_TEST_CURL_HTTP_CODE="200" \
  MYCELORA_TEST_CAPTURE_CFG="$STOP_CFG" \
  "$HOOKS_DIR/mycelora-stop.sh" < "$STOP_STDIN"
)"
echo "Stdout du hook (doit rester vide -- contrat Stop, aucune sortie jamais) : '$STOP_OUT'"
echo
check_bearer "Stop (appel mnemos_log_exchange)" "$STOP_CFG"

# --- PreToolUse ----------------------------------------------------------
echo "--- mycelora-pretooluse.sh (reflexe d'impact) --------------------------"
rm -f "/tmp/mycelora-impact-${SESSION_ID}" "/tmp/mycelora-reflexes-${SESSION_ID}.jsonl"
PRE_RESP="$WORKDIR/pre-resp.json"
cat > "$PRE_RESP" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"{\"spaceId\":\"sp1\",\"carteVide\":true,\"dateCarte\":null,\"carteperimee\":false,\"avertissement\":null,\"objets\":[]}"}]}}
EOF
PRE_STDIN="$WORKDIR/pre-stdin.json"
cat > "$PRE_STDIN" <<EOF
{
  "session_id": "$SESSION_ID",
  "transcript_path": "$TRANSCRIPT",
  "cwd": "$REPO_ROOT",
  "tool_use_id": "toolu_preuve_reelle_pre",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": {
    "command": "psql -h localhost -U admin -d postgres <<'SQL'\nALTER TABLE preuve_reelle_demo ADD COLUMN foo int;\nSQL"
  }
}
EOF
PRE_CFG="$WORKDIR/pre-cfg.txt"
PRE_CALLLOG="$WORKDIR/pre-call.log"
echo "Commande Bash structurante detectee : ALTER TABLE preuve_reelle_demo ADD COLUMN foo int;"
echo "Lance : mycelora-pretooluse.sh (stdin ci-dessus sur son entree standard)"
PRE_OUT="$(
  MYCELORA_TEST_CURL_LOG="$PRE_CALLLOG" \
  MYCELORA_TEST_CURL_RESPONSE="$PRE_RESP" \
  MYCELORA_TEST_CURL_HTTP_CODE="200" \
  MYCELORA_TEST_CAPTURE_CFG="$PRE_CFG" \
  "$HOOKS_DIR/mycelora-pretooluse.sh" < "$PRE_STDIN"
)"
echo "Stdout du hook (decision de refus, RÉFLEXE D'IMPACT) :"
echo "$PRE_OUT" | python3 -m json.tool 2>/dev/null || echo "  $PRE_OUT"
echo
check_bearer "PreToolUse (appel mnemos_impact_lookup)" "$PRE_CFG"
rm -f "/tmp/mycelora-impact-${SESSION_ID}" "/tmp/mycelora-reflexes-${SESSION_ID}.jsonl"

# --- PostToolUse ---------------------------------------------------------
echo "--- mycelora-posttooluse.sh (jalon d'impact) ---------------------------"
POST_RESP="$WORKDIR/post-resp.json"
cat > "$POST_RESP" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"{\"spaceId\":\"sp1\",\"carteVide\":true,\"dateCarte\":null,\"carteperimee\":false,\"avertissement\":null,\"objets\":[]}"}]}}
EOF
POST_STDIN="$WORKDIR/post-stdin.json"
cat > "$POST_STDIN" <<EOF
{
  "session_id": "$SESSION_ID",
  "transcript_path": "$TRANSCRIPT",
  "cwd": "$REPO_ROOT",
  "tool_use_id": "toolu_preuve_reelle_post",
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_input": {
    "command": "psql -h localhost -U admin -d postgres <<'SQL'\nALTER TABLE preuve_reelle_demo_post ADD COLUMN foo int;\nSQL"
  }
}
EOF
POST_CFG="$WORKDIR/post-cfg.txt"
POST_CALLLOG="$WORKDIR/post-call.log"
echo "Jalon correspondant (geste deja execute) : ALTER TABLE preuve_reelle_demo_post ADD COLUMN foo int;"
echo "Lance : mycelora-posttooluse.sh (stdin ci-dessus sur son entree standard)"
POST_OUT="$(
  MYCELORA_TEST_CURL_LOG="$POST_CALLLOG" \
  MYCELORA_TEST_CURL_RESPONSE="$POST_RESP" \
  MYCELORA_TEST_CURL_HTTP_CODE="200" \
  MYCELORA_TEST_CAPTURE_CFG="$POST_CFG" \
  "$HOOKS_DIR/mycelora-posttooluse.sh" < "$POST_STDIN"
)"
echo "Stdout du hook (JALON D'IMPACT) :"
echo "$POST_OUT" | python3 -m json.tool 2>/dev/null || echo "  $POST_OUT"
echo
check_bearer "PostToolUse (appel mnemos_impact_lookup)" "$POST_CFG"
rm -f "/tmp/mycelora-impact-${SESSION_ID}" "/tmp/mycelora-reflexes-${SESSION_ID}.jsonl"

echo "======================================================================"
echo "Etape 4 : 401 jeton_session_expire simule, relance UserPromptSubmit"
echo "======================================================================"
echo
echo "Simule une reponse HTTP 401 dont le corps porte"
echo "error.data.code == \"jeton_session_expire\" sur le PROCHAIN appel"
echo "mnemos_recall, puis relance mycelora-userpromptsubmit.sh avec un"
echo "NOUVEAU prompt sur le meme fil (meme session_id, meme transcript)."
echo
UPS401_RESP="$WORKDIR/ups401-resp.json"
cat > "$UPS401_RESP" <<'EOF'
{"jsonrpc":"2.0","error":{"code":-32001,"message":"Unauthorized","data":{"code":"jeton_session_expire"}},"id":null}
EOF
UPS401_STDIN="$WORKDIR/ups401-stdin.json"
cat > "$UPS401_STDIN" <<EOF
{
  "session_id": "$SESSION_ID",
  "transcript_path": "$TRANSCRIPT",
  "cwd": "$REPO_ROOT",
  "prompt_id": "preuve-reelle-ups-0002",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "et maintenant que le jeton vient d'expirer, que se passe-t-il sur ce prompt ?"
}
EOF
UPS401_CALLLOG="$WORKDIR/ups401-call.log"
UPS401_OUT="$(
  MYCELORA_TEST_CURL_LOG="$UPS401_CALLLOG" \
  MYCELORA_TEST_CURL_RESPONSE="$UPS401_RESP" \
  MYCELORA_TEST_CURL_HTTP_CODE="401" \
  "$HOOKS_DIR/mycelora-userpromptsubmit.sh" < "$UPS401_STDIN"
)"
echo "Stdout du hook (ligne de relance imprimee en clair, injectee dans le"
echo "contexte du modele) :"
echo "  $UPS401_OUT"
echo
UPS401_ATTENDU="Mycelora : jeton de session expiré, relancez l'ouverture du fil (mnemos_session_start) pour rétablir la mémoire."
if [ "$UPS401_OUT" = "$UPS401_ATTENDU" ]; then
  echo "-> CONFORME : ligne de relance exacte."
else
  echo "-> ANOMALIE : ligne de relance attendue :"
  echo "     $UPS401_ATTENDU"
  echo "   ligne obtenue :"
  echo "     $UPS401_OUT"
  ANOMALIE=1
fi
echo

echo "======================================================================"
if [ "$ANOMALIE" -eq 0 ]; then
  echo "PREUVE TERMINEE, TOUT CONFORME."
  echo "Les quatre hooks reels envoient bien Bearer $JETON_ATTENDU extrait du"
  echo "transcript via le cache v3, et la relance de jeton expire s'affiche"
  echo "telle qu'attendue apres le 401 type simule."
else
  echo "PREUVE TERMINEE AVEC AU MOINS UNE ANOMALIE (voir ci-dessus)."
fi
echo "======================================================================"

exit "$ANOMALIE"
