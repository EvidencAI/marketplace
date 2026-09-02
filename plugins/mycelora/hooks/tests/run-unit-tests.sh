#!/usr/bin/env bash

set -uo pipefail

# Calculer le repertoire racine du repo
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# Nettoyage initial
rm -f /tmp/mycelora-hook.log /tmp/mycelora-hook-*.json

# Creer un dossier temporaire pour le faux curl
FAKE_BIN_DIR="$(mktemp -d)"
FAKE_CURL_SCRIPT="$FAKE_BIN_DIR/curl"
cat > "$FAKE_CURL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Faux curl pour les tests unitaires. Ne fait aucun appel reseau.
CALL_LOG="${MYCELORA_TEST_CURL_LOG:?MYCELORA_TEST_CURL_LOG non defini}"
RESP_BODY_FILE="${MYCELORA_TEST_CURL_RESPONSE:-}"
HTTP_CODE="${MYCELORA_TEST_CURL_HTTP_CODE:-200}"
SHOULD_FAIL="${MYCELORA_TEST_CURL_FAIL:-0}"

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

# F1 (revue adversariale S-REFLEXES-6, 02/09/2026) : le bearer REELLEMENT
# envoye vit dans le fichier de config -K (jamais en argument, cf.
# mycelora_curl_post), pas dans --data-binary. Meme convention que
# MYCELORA_TEST_CAPTURE_BODY : copie du CONTENU du fichier -K si demande.
if [ -n "$CFG_FILE" ] && [ -n "${MYCELORA_TEST_CAPTURE_CFG:-}" ]; then
  cp "$CFG_FILE" "$MYCELORA_TEST_CAPTURE_CFG" 2>/dev/null || true
fi

if [ "$SHOULD_FAIL" = "1" ]; then
  exit 7
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
chmod +x "$FAKE_CURL_SCRIPT"

# S-REFLEXES-6 (02/09/2026) : jeton de session hook. Les 93 tests ECRITS
# AVANT cette story ne connaissent pas le jeton et doivent continuer d'agir
# EXACTEMENT comme avant (aucune regression) : on exporte donc globalement
# une fausse valeur "deja substituee" (priorite 1 du contrat de
# mycelora_resolve_hook_token -> gardee telle quelle, jamais touchee au
# cache), qui met tous les hooks dans l'etat "jeton present" par defaut. Les
# tests dedies au canal marketplace (sans-jeton, cache v3, priorites) unsetent
# CLAUDE_PLUGIN_OPTION_HOOK_KEY localement (sous-shell) pour retomber sur la
# resolution reelle.
export CLAUDE_PLUGIN_OPTION_HOOK_KEY="mk_live_TESTFAKE0000000000000000"

# Compteurs de resultats reels (pas un comptage sur le code source)
TOTAL_TESTS=0
FAILED_TESTS=0

# Fonction d'assertion
assert() {
  local test_name="$1"
  local command="$2"
  local expected_exit_code="$3"
  local expected_stdout="$4"
  local expect_curl_call="$5" # "yes" ou "no"
  local custom_response="${6:-}" # chemin optionnel vers un corps de reponse canned personnalise (remplace la reponse recall par defaut)

  local temp_dir
  temp_dir="$(mktemp -d)"
  # trap RETURN (et non EXIT) : se declenche a la sortie de CETTE fonction,
  # donc nettoie bien le temp_dir de CET appel avant l'appel suivant.
  trap 'rm -rf "$temp_dir"' RETURN

  local call_log="$temp_dir/call.log"
  local capture_body="$temp_dir/body.json"
  local response_file="$temp_dir/response.json"
  local stdin_file="$temp_dir/stdin.json"

  # Ecrire la reponse canned (ou la reponse personnalisee si fournie, ex
  # pour simuler un result.isError=true)
  if [ -n "$custom_response" ] && [ -f "$custom_response" ]; then
    cp "$custom_response" "$response_file"
  else
    cat > "$response_file" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"FACE-A CANNED TEXT"}]},"id":1}
EOF
  fi

  # Ecrire le corps de reponse pour mnemos_log_exchange
  local log_exchange_response="$temp_dir/log_exchange_response.json"
  cat > "$log_exchange_response" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"{\"success\": true, \"sessionId\": \"whatever\"}"}]},"id":1}
EOF

  # Exécuter la commande
  local stdout_file="$temp_dir/stdout"
  local exit_code=0
  local actual_stdout=""
  
  cd "$REPO_ROOT" || exit 1
  
  # Exporter les variables d'environnement pour le faux curl
  export PATH="$FAKE_BIN_DIR:$PATH"
  export MYCELORA_TEST_CURL_LOG="$call_log"
  export MYCELORA_TEST_CURL_RESPONSE="$response_file"
  export MYCELORA_TEST_CURL_HTTP_CODE="200"
  export MYCELORA_TEST_CAPTURE_BODY="$capture_body"

  # Exécuter la commande
  eval "$command" > "$stdout_file" 2>&1 || exit_code=$?
  
  actual_stdout="$(cat "$stdout_file")"

  # Vérifier le code de sortie
  if [ "$exit_code" -ne "$expected_exit_code" ]; then
    echo "FAIL $test_name : exit code expected $expected_exit_code, got $exit_code"
    return 1
  fi

  # Vérifier stdout
  if [ "$actual_stdout" != "$expected_stdout" ]; then
    echo "FAIL $test_name : stdout expected '$expected_stdout', got '$actual_stdout'"
    return 1
  fi

  # Vérifier si curl a été appelé
  local curl_called=0
  if [ -f "$call_log" ]; then
    curl_called=1
  fi

  if [ "$expect_curl_call" = "yes" ] && [ "$curl_called" -eq 0 ]; then
    echo "FAIL $test_name : expected curl call but none was made"
    return 1
  fi

  if [ "$expect_curl_call" = "no" ] && [ "$curl_called" -eq 1 ]; then
    echo "FAIL $test_name : unexpected curl call was made"
    return 1
  fi

  # Si on attend un appel curl et qu'il a été fait, vérifier le payload
  if [ "$expect_curl_call" = "yes" ] && [ -f "$capture_body" ]; then
    local payload_content
    payload_content="$(cat "$capture_body")"
    
    # Vérifier le JSONRPC
    local jsonrpc
    jsonrpc="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('jsonrpc', ''))" < "$capture_body")"
    if [ "$jsonrpc" != "2.0" ]; then
      echo "FAIL $test_name : expected jsonrpc '2.0', got '$jsonrpc'"
      return 1
    fi

    # Vérifier le method
    local method
    method="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('method', ''))" < "$capture_body")"
    if [ "$method" != "tools/call" ]; then
      echo "FAIL $test_name : expected method 'tools/call', got '$method'"
      return 1
    fi

    # Vérifier le nom de l'outil
    local tool_name
    tool_name="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('name', ''))" < "$capture_body")"
    
    case "$test_name" in
      mycelora-stop-*)
        if [ "$tool_name" != "mnemos_log_exchange" ]; then
          echo "FAIL $test_name : expected tool name 'mnemos_log_exchange', got '$tool_name'"
          return 1
        fi
        ;;
      *)
        if [ "$tool_name" != "mnemos_recall" ]; then
          echo "FAIL $test_name : expected tool name 'mnemos_recall', got '$tool_name'"
          return 1
        fi
        ;;
    esac

    # Vérifier les arguments pour mnemos_recall
    if [ "$tool_name" = "mnemos_recall" ]; then
      local user_id
      user_id="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('arguments', {}).get('userId', ''))" < "$capture_body")"
      if [ "$user_id" != "stephane" ]; then
        echo "FAIL $test_name : expected userId 'stephane', got '$user_id'"
        return 1
      fi

      # Vérifier le query pour mnemos_recall
      local query
      query="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('arguments', {}).get('query', ''))" < "$capture_body")"
      
      if [ "$test_name" = "mycelora-userpromptsubmit-2" ]; then
        # Pour ce test, vérifier le prompt exact
        if [ "$query" != "peux-tu m'expliquer comment fonctionne le cache de spaceId dans les hooks ?" ]; then
          echo "FAIL $test_name : expected query 'peux-tu m'expliquer comment fonctionne le cache de spaceId dans les hooks ?', got '$query'"
          return 1
        fi
      elif [ "$test_name" = "mycelora-userpromptsubmit-9" ]; then
        # Pour ce test, vérifier le prompt
        if [ "$query" != "ceci est un prompt de test suffisamment long pour passer les filtres" ]; then
          echo "FAIL $test_name : expected query 'ceci est un prompt de test suffisamment long pour passer les filtres', got '$query'"
          return 1
        fi
      fi

      # Vérifier le spaceId pour mnemos_recall
      local space_id
      space_id="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('arguments', {}).get('spaceId', ''))" < "$capture_body")"
      
      if [ "$test_name" = "mycelora-userpromptsubmit-2" ]; then
        # Pour ce test, vérifier le spaceId
        if [ "$space_id" != "Développement Mnemos" ]; then
          echo "FAIL $test_name : expected spaceId 'Développement Mnemos', got '$space_id'"
          return 1
        fi
      elif [ "$test_name" = "mycelora-userpromptsubmit-9" ]; then
        # Pour ce test, vérifier qu'il n'y a pas de spaceId
        if [ -n "$space_id" ]; then
          echo "FAIL $test_name : expected no spaceId, but got '$space_id'"
          return 1
        fi
      fi
    elif [ "$tool_name" = "mnemos_log_exchange" ]; then
      # Vérifier les arguments pour mnemos_log_exchange
      local user_message
      user_message="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('arguments', {}).get('userMessage', ''))" < "$capture_body")"
      
      if [ "$test_name" = "mycelora-stop-10" ]; then
        # Pour ce test, vérifier le userMessage exact
        if [ "$user_message" != "et maintenant, peux-tu lister les fichiers du dossier hooks ?" ]; then
          echo "FAIL $test_name : expected userMessage 'et maintenant, peux-tu lister les fichiers du dossier hooks ?', got '$user_message'"
          return 1
        fi
      elif [ "$test_name" = "mycelora-stop-14" ]; then
        # Pour ce test, vérifier le userMessage
        if [ "$user_message" != "ok" ]; then
          echo "FAIL $test_name : expected userMessage 'ok', got '$user_message'"
          return 1
        fi
      elif [ "$test_name" = "mycelora-stop-13" ]; then
        if [ "$user_message" != "lance la commande de build stp" ]; then
          echo "FAIL $test_name : expected userMessage 'lance la commande de build stp', got '$user_message'"
          return 1
        fi
      elif [ "$test_name" = "mycelora-stop-tool-heavy" ] || [ "$test_name" = "mycelora-stop-tool-heavy-no-promptid" ]; then
        # Test de non-regression : avec l'ancienne logique (arret sur la
        # derniere entree user tout court), ces deux cas auraient echoue en
        # MISSING car le transcript se termine par un tool_result.
        if [ "$user_message" != "peux-tu lister les fichiers du dossier hooks et me dire s'il y a des tests ?" ]; then
          echo "FAIL $test_name : expected userMessage 'peux-tu lister les fichiers du dossier hooks et me dire s'il y a des tests ?', got '$user_message'"
          return 1
        fi
      fi

      local assistant_response
      assistant_response="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('arguments', {}).get('assistantResponse', ''))" < "$capture_body")"
      
      if [ "$test_name" = "mycelora-stop-10" ]; then
        # Pour ce test, vérifier l'assistantResponse exact
        if [ "$assistant_response" != "Voici la liste des fichiers du dossier hooks : hooks.json, mycelora-userpromptsubmit.sh, mycelora-stop.sh." ]; then
          echo "FAIL $test_name : expected assistantResponse 'Voici la liste des fichiers du dossier hooks : hooks.json, mycelora-userpromptsubmit.sh, mycelora-stop.sh.', got '$assistant_response'"
          return 1
        fi
      fi

      local session_id
      session_id="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('arguments', {}).get('sessionId', ''))" < "$capture_body")"
      
      if [ "$test_name" = "mycelora-stop-10" ]; then
        # Pour ce test, vérifier le sessionId
        if [ "$session_id" != "726ec160-e1f5-5bd0-b3e7-3de9785ea2be" ]; then
          echo "FAIL $test_name : expected sessionId '726ec160-e1f5-5bd0-b3e7-3de9785ea2be', got '$session_id'"
          return 1
        fi
      fi

      local user_id
      user_id="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('arguments', {}).get('userId', ''))" < "$capture_body")"
      
      if [ "$test_name" = "mycelora-stop-10" ]; then
        # Pour ce test, vérifier le userId
        if [ "$user_id" != "stephane" ]; then
          echo "FAIL $test_name : expected userId 'stephane', got '$user_id'"
          return 1
        fi
      fi
    fi

    # Vérifier l'id
    local id
    id="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('id', ''))" < "$capture_body")"
    if [ "$id" != 1 ]; then
      echo "FAIL $test_name : expected id 1, got '$id'"
      return 1
    fi
  fi

  echo "PASS $test_name"
}

# Vérifier que __MYCELORA_HOOK_KEY__ est présent dans les deux scripts
TOTAL_TESTS=$((TOTAL_TESTS+1))
if ! grep -q "__MYCELORA_HOOK_KEY__" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"; then
  echo "FAIL placeholder-15 : __MYCELORA_HOOK_KEY__ not found in mycelora-userpromptsubmit.sh"
  FAILED_TESTS=$((FAILED_TESTS+1))
elif ! grep -q "__MYCELORA_HOOK_KEY__" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"; then
  echo "FAIL placeholder-15 : __MYCELORA_HOOK_KEY__ not found in mycelora-stop.sh"
  FAILED_TESTS=$((FAILED_TESTS+1))
else
  echo "PASS placeholder-15"
fi

# Exécuter les tests (chaque appel incremente TOTAL_TESTS et, en cas
# d'echec de assert (return 1), incremente FAILED_TESTS sans interrompre la
# suite : set -e est desactive volontairement pour ce script).
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-1" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "FACE-A CANNED TEXT" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-2" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-valid-long.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "FACE-A CANNED TEXT" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-3" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-short.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-4" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-uploaded-files.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-5" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-system-reminder.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-6" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-continued.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-7" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-system-notification.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-8" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-task-notification.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

# Test synthétique pour mycelora-userpromptsubmit-9
temp_synthetic_stdin="$(mktemp)"
cat > "$temp_synthetic_stdin" <<EOF
{
  "session_id": "synthetic-no-session-start-0001",
  "transcript_path": "plugins/mycelora/hooks/tests/fixtures/transcript-no-session-start.jsonl",
  "cwd": "/home/claude",
  "prompt_id": "daa83436-ac05-41b8-890b-2e2769ad9ce5",
  "permission_mode": "default",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "ceci est un prompt de test suffisamment long pour passer les filtres"
}
EOF

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-9" \
  "cat '$temp_synthetic_stdin' | PATH='$FAKE_BIN_DIR:$PATH' '$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh'" \
  0 \
  "FACE-A CANNED TEXT" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

# Nettoyer le fichier temporaire
rm -f "$temp_synthetic_stdin"

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-stop-10" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"' \
  0 \
  "" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-stop-11" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-task-notification.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-stop-12" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-system-notification.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

# Ce fixture (transcript-missing-last-user.jsonl) se termine par un
# tool_result, mais contient bien un vrai message user en tete d'echange
# ("lance la commande de build stp"). Avec l'ancien algorithme (arret sur
# la seule derniere entree user), ce message etait perdu a tort (MISSING).
# Avec le nouvel algorithme (repli b, on remonte l'historique), il est
# retrouve : ce n'est donc plus un cas "MISSING" mais un cas de repli
# reussi. Le vrai test du chemin retry-puis-abandon (aucun message user nul
# part dans le fichier) est couvert plus bas par un transcript synthetique.
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-stop-13" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-missing-user.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"' \
  0 \
  "" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-stop-14" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-short-user.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"' \
  0 \
  "" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

# Non-regression : transcript se terminant par un tool_result (cas reel
# majoritaire des tours Cowork qui utilisent des outils). Avec l'ancienne
# logique de find_last_user (arret sur la seule derniere entree user), ces
# deux cas echouaient en MISSING. promptId present dans le stdin : doit
# retrouver le vrai message user via le critere (a).
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-stop-tool-heavy" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-tool-heavy.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"' \
  0 \
  "" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

# Meme transcript mais SANS prompt_id dans le stdin : doit retrouver le
# meme message user via le repli (b), en remontant l'historique.
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-stop-tool-heavy-no-promptid" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-tool-heavy-no-promptid.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"' \
  0 \
  "" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

# Filtre "Rappel interne :" (wakeups send_later, ne portent pas le prefixe
# "[SYSTEM NOTIFICATION - NOT USER INPUT]" au niveau des hooks).
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-rappel-interne" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-rappel-interne.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-stop-rappel-interne" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-rappel-interne.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

# Cas synthetique : transcript sans AUCUNE entree type=user a content
# string (uniquement une entree tool_result). C'est le seul vrai test du
# chemin retry-puis-abandon (MISSING), plus aucune fixture fournie ne le
# couvre depuis le fix du nouvel algorithme find_last_user (voir
# commentaire sur mycelora-stop-13 plus haut).
temp_synthetic_transcript="$(mktemp)"
cat > "$temp_synthetic_transcript" <<'EOF'
{"type": "assistant", "sessionId": "synthetic-no-user-msg", "session_id": "synthetic-no-user-msg", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_syn1", "name": "Bash", "input": {"command": "echo hi"}}]}, "uuid": "a1", "parentUuid": null, "timestamp": "2026-07-14T20:00:00.000Z"}
{"type": "user", "sessionId": "synthetic-no-user-msg", "session_id": "synthetic-no-user-msg", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_syn1", "content": [{"type": "text", "text": "hi"}]}]}, "uuid": "u1", "parentUuid": "a1", "timestamp": "2026-07-14T20:00:01.000Z"}
EOF

temp_synthetic_stop_stdin="$(mktemp)"
cat > "$temp_synthetic_stop_stdin" <<EOF
{
  "session_id": "synthetic-no-user-msg",
  "transcript_path": "$temp_synthetic_transcript",
  "cwd": "/home/claude",
  "prompt_id": "synthetic-no-user-msg-prompt",
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "hi",
  "background_tasks": [],
  "session_crons": []
}
EOF

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-stop-truly-missing-synthetic" \
  "cat '$temp_synthetic_stop_stdin' | PATH='$FAKE_BIN_DIR:$PATH' '$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh'" \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

rm -f "$temp_synthetic_transcript" "$temp_synthetic_stop_stdin"

# result.isError=true (panne edge, quota epuise, outil inconnu) : le texte
# d'erreur ne doit JAMAIS etre injecte sur stdout (Q10, fail silencieux).
tool_error_response="$(mktemp)"
cat > "$tool_error_response" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"{\"error\":\"Unknown error\",\"tool\":\"mnemos_recall\"}"}],"isError":true},"id":1}
EOF

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mycelora-userpromptsubmit-tool-error" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "yes" \
  "$tool_error_response" || FAILED_TESTS=$((FAILED_TESTS+1))

rm -f "$tool_error_response"

# ---------------------------------------------------------------------------
# FILTRE DU BRUIT (27/07/2026, fil 20).
#
# Les cas FILTRES assertent DEUX choses ensemble : stdout vide ET aucun appel
# curl. Le stdout vide seul ne prouverait rien (le hook sort aussi vide quand
# l'edge repond en erreur : 4e des cinq formes du test qui ne peut pas
# echouer). C'est l'absence d'appel reseau qui prouve que le filtre a mordu.
#
# Les DEUX derniers cas sont les garde-fous inverses : un message court mais
# porteur d'une vraie question, et un message qui COMMENCE par un marqueur
# mais continue en question. Les deux DOIVENT declencher le recall. Sans eux,
# elargir la liste de marqueurs casserait l'injection sans que rien ne rougisse.
#
# CONTRE-EPREUVE PAR MUTATION verifiee : neutraliser est_validation_seule (en
# lui faisant retourner False) fait echouer les trois premiers ; neutraliser
# est_relance_machine fait echouer le quatrieme.
# ---------------------------------------------------------------------------

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "ups-filtre-validation-ok-go" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-validation-ok-go.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "ups-filtre-validation-cest-fait" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-validation-cest-fait.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "ups-filtre-validation-parfait-accents" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-validation-parfait.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "ups-filtre-relance-machine" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-relance-machine.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

# GARDE-FOU INVERSE 1 : court (11 caracteres) mais vraie question -> DOIT passer.
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "ups-question-courte-doit-passer" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-courte-mais-vraie-question.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "FACE-A CANNED TEXT" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

# GARDE-FOU INVERSE 2 : commence par un marqueur mais porte une question -> DOIT passer.
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "ups-validation-puis-question-doit-passer" \
  'cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-validation-puis-question.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"' \
  0 \
  "FACE-A CANNED TEXT" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

# ============================================================================
# S-ALIAS-1 (fil 76, 24/08/2026) — etiquettes du fil dans le corps envoye
# ============================================================================
#
# `assert` ne sait verifier que le code de sortie, stdout et le fait qu'un
# appel curl ait eu lieu. Ces tests-ci portent sur le CONTENU du corps
# JSON-RPC : ils passent donc par MYCELORA_TEST_CAPTURE_BODY directement.
#
# assert_arguments <nom> <fixture_stdin> <expression_python_sur_arguments>
assert_arguments() {
  local test_name="$1" fixture="$2" expression="$3"
  local temp_dir capture_body verdict
  temp_dir="$(mktemp -d)"

  # Etat propre AVANT chaque cas. Le cache d'etiquettes est indexe par
  # session_id seul : ces fixtures partagent le meme session_id avec des
  # transcripts differents, donc sans ce nettoyage le titre trouve par un cas
  # fuiterait dans le suivant. Piege paye au premier lancement (fil 76).
  rm -f /tmp/mycelora-hook-*.json

  MYCELORA_TEST_CURL_LOG="$temp_dir/call.log" \
  MYCELORA_TEST_CAPTURE_BODY="$temp_dir/body.json" \
  MYCELORA_TEST_CURL_RESPONSE="" \
  PATH="$FAKE_BIN_DIR:$PATH" \
    "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" \
    < "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/$fixture" > /dev/null 2>&1

  verdict="$(python3 - "$temp_dir/body.json" "$expression" <<'PYEOF'
import json, sys
chemin, expression = sys.argv[1], sys.argv[2]
try:
    with open(chemin, encoding="utf-8") as f:
        arguments = json.load(f)["params"]["arguments"]
except Exception as err:
    print("FAIL corps illisible: %s" % err)
    sys.exit(0)
print("OK" if eval(expression, {"arguments": arguments}) else "FAIL %s" % json.dumps(
    {k: v for k, v in arguments.items() if k != "userMessage" and k != "assistantResponse"},
    ensure_ascii=False))
PYEOF
)"

  rm -rf "$temp_dir"
  TOTAL_TESTS=$((TOTAL_TESTS+1))
  if [ "$verdict" = "OK" ]; then
    echo "PASS $test_name"
  else
    echo "FAIL $test_name : $verdict"
    FAILED_TESTS=$((FAILED_TESTS+1))
  fi
}

# Le cas nominal : les deux etiquettes sont dans le transcript, les deux
# doivent partir. Le nom technique vient de l'appel session_start, le titre
# humain de l'entree type=custom-title.
assert_arguments "alias-les-deux-etiquettes-partent" "stdin-stop-alias.json" \
  "arguments.get('sessionLabel') == 'cowork-2026-07-14-sprint-v3-s3-watcher' and arguments.get('customTitle') == 'PROMPT-FIL-SUITE76'"

# Regle R4, JAMAIS D'INVENTION : pas d'entree custom-title dans ce transcript,
# donc pas de cle customTitle dans le corps. Surtout pas une chaine vide.
assert_arguments "alias-sans-titre-humain-la-cle-est-absente" "stdin-stop-alias-sans-titre.json" \
  "'customTitle' not in arguments and arguments.get('sessionLabel') == 'cowork-2026-07-14-sprint-v3-s3-watcher'"

# Contrat historique preserve : la resolution d'espace continue de marcher,
# elle passe desormais par la meme passe de lecture.
assert_arguments "alias-le-spaceId-est-toujours-resolu" "stdin-stop-alias.json" \
  "arguments.get('spaceId') == 'Développement Mnemos'"

# ============ S-ACK-1 (29/08/2026) : accuse de reception des injections ====
# Le session_id des fixtures normales est 726ec160-e1f5-5bd0-b3e7-3de9785ea2be,
# donc le fichier de lots est /tmp/mycelora-ack-<ce session_id>.
ACK_TEST_SESSION="726ec160-e1f5-5bd0-b3e7-3de9785ea2be"
ACK_TEST_FILE="/tmp/mycelora-ack-${ACK_TEST_SESSION}"
ACK_TEST_LOT="9d1e4b2a-1111-4222-8333-abcdefabcdef"

# A. UPS : une reponse ok portant _meta.lot_id ecrit le lot dans le fichier.
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "$ACK_TEST_FILE"
ack_tmp="$(mktemp -d)"
cat > "$ack_tmp/resp-meta.json" <<EOF
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"FACE-A CANNED TEXT"}],"_meta":{"lot_id":"$ACK_TEST_LOT"}},"id":1}
EOF
export MYCELORA_TEST_CURL_LOG="$ack_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE="$ack_tmp/resp-meta.json"
export MYCELORA_TEST_CURL_HTTP_CODE="200"
export MYCELORA_TEST_CAPTURE_BODY="$ack_tmp/body.json"
ack_out="$(cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh")"
if [ "$ack_out" = "FACE-A CANNED TEXT" ] && [ -f "$ACK_TEST_FILE" ] && grep -q "$ACK_TEST_LOT" "$ACK_TEST_FILE"; then
  echo "PASS ack-ups-ecrit-le-lot"
else
  echo "FAIL ack-ups-ecrit-le-lot : stdout='$ack_out', fichier=$([ -f "$ACK_TEST_FILE" ] && cat "$ACK_TEST_FILE" || echo ABSENT)"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

# B. UPS : une reponse ok SANS _meta ne cree pas de fichier (serveur pre-S-ACK-1).
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "$ACK_TEST_FILE"
cat > "$ack_tmp/resp-sans-meta.json" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"FACE-A CANNED TEXT"}]},"id":1}
EOF
export MYCELORA_TEST_CURL_RESPONSE="$ack_tmp/resp-sans-meta.json"
ack_out="$(cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh")"
if [ "$ack_out" = "FACE-A CANNED TEXT" ] && [ ! -f "$ACK_TEST_FILE" ]; then
  echo "PASS ack-ups-sans-meta-pas-de-fichier"
else
  echo "FAIL ack-ups-sans-meta-pas-de-fichier : stdout='$ack_out', fichier=$([ -f "$ACK_TEST_FILE" ] && echo PRESENT || echo absent)"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

# C. Stop : le fichier de lots part dans ackLotIds et est supprime apres un 2xx.
TOTAL_TESTS=$((TOTAL_TESTS+1))
printf '%s\n%s\npas-un-uuid\n%s\n' "$ACK_TEST_LOT" "$ACK_TEST_LOT" "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" > "$ACK_TEST_FILE"
export MYCELORA_TEST_CURL_RESPONSE="$ack_tmp/resp-sans-meta.json"
export MYCELORA_TEST_CAPTURE_BODY="$ack_tmp/body-stop.json"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
ack_args_ok="$(python3 -c "
import json
try:
    d = json.load(open('$ack_tmp/body-stop.json'))
    lots = d['params']['arguments'].get('ackLotIds')
    print('ok' if lots == ['$ACK_TEST_LOT', 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'] else 'ko:%s' % lots)
except Exception as e:
    print('ko:%s' % e)
")"
if [ "$ack_args_ok" = "ok" ] && [ ! -f "$ACK_TEST_FILE" ]; then
  echo "PASS ack-stop-rejoue-et-supprime"
else
  echo "FAIL ack-stop-rejoue-et-supprime : args=$ack_args_ok, fichier=$([ -f "$ACK_TEST_FILE" ] && echo PRESENT || echo absent)"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

# D. Stop : sur une erreur HTTP, le fichier RESTE (rejoue au Stop suivant).
TOTAL_TESTS=$((TOTAL_TESTS+1))
printf '%s\n' "$ACK_TEST_LOT" > "$ACK_TEST_FILE"
export MYCELORA_TEST_CURL_HTTP_CODE="500"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
if [ -f "$ACK_TEST_FILE" ]; then
  echo "PASS ack-stop-echec-http-garde-le-fichier"
else
  echo "FAIL ack-stop-echec-http-garde-le-fichier : fichier supprime malgre le 500"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
export MYCELORA_TEST_CURL_HTTP_CODE="200"
rm -f "$ACK_TEST_FILE"
rm -rf "$ack_tmp"

# ============================================================================
# S-REFLEXES-2 (02/09/2026) — reflexe d'impact : mycelora-pretooluse.sh /
# mycelora-posttooluse.sh. Les fixtures stdin-pre-*/stdin-post-* portent
# REPO_ROOT_PLACEHOLDER a la place de "cwd" (le hook resout le depot local en
# remontant depuis cwd : il doit reellement pointer vers CE checkout pour que
# la resolution .git/supabase//plugins/mycelora et l'interrupteur fichier
# fonctionnent) — substitue a la volee par reflexe_stdin, jamais fige en dur
# dans la fixture (portable entre checkouts).
# ============================================================================

rm -f /tmp/mycelora-reflexes-*.jsonl /tmp/mycelora-impact-*

reflexe_stdin() {
  sed "s#REPO_ROOT_PLACEHOLDER#$REPO_ROOT#g" "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/$1"
}

PRETOOLUSE="$REPO_ROOT/plugins/mycelora/hooks/mycelora-pretooluse.sh"
POSTTOOLUSE="$REPO_ROOT/plugins/mycelora/hooks/mycelora-posttooluse.sh"

# Reponse canned mnemos_impact_lookup (contrat REEL de S-REFLEXES-1,
# ImpactLookupResult : objets est un TABLEAU {identifiant,inconnu,lignes},
# pas un Record — verifie sur carte.ts/tools.ts le 02/09, distinct de la
# forme simplifiee donnee en amorce de cette story). memory_atoms connu (une
# ligne complete, gabarit du rapport figé), memory_atoms.foo inconnu.
REFLEXE_IMPACT_RESPONSE="$(mktemp /tmp/mycelora-test-reflexe-resp.XXXXXX)"
cat > "$REFLEXE_IMPACT_RESPONSE" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"{\"spaceId\":\"sp1\",\"carteVide\":false,\"dateCarte\":\"2026-09-02T07:00:00Z\",\"carteperimee\":false,\"avertissement\":null,\"objets\":[{\"identifiant\":\"memory_atoms\",\"inconnu\":false,\"lignes\":[{\"type\":\"table\",\"objet\":\"memory_atoms\",\"colonnes\":[],\"lu_par\":[\"recall.ts\",\"garbage-collect.ts\",\"export-generate.ts\",\"a.ts\"],\"ecrit_par\":[\"extract-from-exchanges/index.ts\",\"atoms.ts\"],\"rpc\":[\"hybrid_search_atoms\"],\"section_carte\":\"Tables coeur (l.410)\",\"genere_le\":\"2026-09-02T07:00:00Z\",\"empreinte\":\"x\"}]},{\"identifiant\":\"memory_atoms.foo\",\"inconnu\":true,\"lignes\":[]}]}"}]}}
EOF

# assert_reflexe_json <test_name> <fixture> <verif_python_sur_le_fichier_stdout> [attend_curl(yes|no)]
# Verifie exit=0, puis passe le CHEMIN d'un fichier contenant le stdout brut
# a l'expression python (jamais le contenu interpole dans une commande : le
# rapport contient des apostrophes francaises qui casseraient toute
# interpolation de chaine).
assert_reflexe_json() {
  local test_name="$1" fixture="$2" expression="$3" attend_curl="${4:-yes}"
  local tmp out_file call_log
  tmp="$(mktemp -d)"
  out_file="$tmp/stdout.json"
  call_log="$tmp/call.log"

  export MYCELORA_TEST_CURL_LOG="$call_log"
  export MYCELORA_TEST_CURL_RESPONSE="$REFLEXE_IMPACT_RESPONSE"
  export MYCELORA_TEST_CURL_HTTP_CODE="200"
  export MYCELORA_TEST_CAPTURE_BODY="$tmp/body.json"

  reflexe_stdin "$fixture" | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE" > "$out_file" 2>"$tmp/stderr"
  local rc=$?

  TOTAL_TESTS=$((TOTAL_TESTS+1))
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $test_name : exit code $rc (stderr: $(cat "$tmp/stderr" 2>/dev/null))"
    FAILED_TESTS=$((FAILED_TESTS+1))
    rm -rf "$tmp"
    return 1
  fi

  local curl_called=0
  [ -f "$call_log" ] && curl_called=1
  if [ "$attend_curl" = "yes" ] && [ "$curl_called" -eq 0 ]; then
    echo "FAIL $test_name : appel curl attendu mais absent"
    FAILED_TESTS=$((FAILED_TESTS+1))
    rm -rf "$tmp"
    return 1
  fi
  if [ "$attend_curl" = "no" ] && [ "$curl_called" -eq 1 ]; then
    echo "FAIL $test_name : appel curl inattendu"
    FAILED_TESTS=$((FAILED_TESTS+1))
    rm -rf "$tmp"
    return 1
  fi

  local verdict
  verdict="$(python3 - "$out_file" <<PYEOF
import json, sys
chemin = sys.argv[1]
try:
    with open(chemin, encoding="utf-8") as f:
        texte = f.read()
except Exception as e:
    print("FAIL:lecture impossible: %s" % e)
    sys.exit(0)
try:
    d = json.loads(texte) if texte.strip() else None
except Exception as e:
    print("FAIL:JSON invalide (%s) : %r" % (e, texte[:200]))
    sys.exit(0)
try:
    verdict = bool($expression)
except Exception as e:
    print("FAIL:expression: %s" % e)
    sys.exit(0)
print("OK" if verdict else "FAIL:expression fausse sur %r" % (texte[:300]))
PYEOF
)"
  rm -rf "$tmp"
  if [ "$verdict" = "OK" ]; then
    echo "PASS $test_name"
  else
    echo "FAIL $test_name : $verdict"
    FAILED_TESTS=$((FAILED_TESTS+1))
  fi
}

# --- Cas obligatoire : deny sur ALTER TABLE (heredoc), rapport contient
# l'objet, "Lu par", et la portee "changement de PRODUIT" ------------------
rm -f /tmp/mycelora-impact-reflexe-ddl-alter /tmp/mycelora-reflexes-reflexe-ddl-alter.jsonl
assert_reflexe_json "reflexe-pre-deny-alter-table" "stdin-pre-ddl-alter-table.json" \
  'd["hookSpecificOutput"]["hookEventName"] == "PreToolUse" and d["hookSpecificOutput"]["permissionDecision"] == "deny" and "memory_atoms" in d["hookSpecificOutput"]["permissionDecisionReason"] and "Lu par" in d["hookSpecificOutput"]["permissionDecisionReason"] and "Portée : changement de PRODUIT" in d["hookSpecificOutput"]["permissionDecisionReason"]' \
  "yes"

# --- Cas obligatoire : passage au second geste sur le meme objet (dedup) --
TOTAL_TESTS=$((TOTAL_TESTS+1))
dedup_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$dedup_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE="$REFLEXE_IMPACT_RESPONSE"
export MYCELORA_TEST_CAPTURE_BODY="$dedup_tmp/body.json"
out2="$(reflexe_stdin stdin-pre-ddl-alter-table.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
if [ -z "$out2" ] && [ ! -f "$dedup_tmp/call.log" ]; then
  echo "PASS reflexe-pre-passage-second-geste-meme-objet"
else
  echo "FAIL reflexe-pre-passage-second-geste-meme-objet : stdout='$out2', curl_appele=$([ -f "$dedup_tmp/call.log" ] && echo oui || echo non)"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$dedup_tmp"

# --- Cas obligatoire : N objets (deux ALTER TABLE) = UN SEUL refus --------
rm -f /tmp/mycelora-impact-reflexe-n-objets /tmp/mycelora-reflexes-reflexe-n-objets.jsonl
assert_reflexe_json "reflexe-pre-n-objets-un-seul-refus" "stdin-pre-n-objets.json" \
  'd["hookSpecificOutput"]["permissionDecision"] == "deny" and d["hookSpecificOutput"]["permissionDecisionReason"].count("Objet : table_alpha (") == 1 and d["hookSpecificOutput"]["permissionDecisionReason"].count("Objet : table_beta (") == 1' \
  "yes"
TOTAL_TESTS=$((TOTAL_TESTS+1))
if [ "$(cat /tmp/mycelora-reflexes-reflexe-n-objets.jsonl 2>/dev/null | wc -l | tr -d ' ')" -le 2 ] 2>/dev/null; then
  echo "PASS reflexe-pre-n-objets-journal-une-ligne-refus"
else
  echo "FAIL reflexe-pre-n-objets-journal-une-ligne-refus : $(cat /tmp/mycelora-reflexes-reflexe-n-objets.jsonl 2>/dev/null | wc -l) lignes"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

# --- Cas obligatoire : "< fichier.sql" lu et analyse -----------------------
rm -f /tmp/mycelora-impact-reflexe-fichier-sql /tmp/mycelora-reflexes-reflexe-fichier-sql.jsonl
assert_reflexe_json "reflexe-pre-fichier-sql-lu-et-analyse" "stdin-pre-fichier-sql.json" \
  'd["hookSpecificOutput"]["permissionDecision"] == "deny" and "table_depuis_fichier" in d["hookSpecificOutput"]["permissionDecisionReason"]' \
  "yes"

# --- UPDATE ciblant user_id : deny, portee mentionne user_id et la valeur -
rm -f /tmp/mycelora-impact-reflexe-update-userid /tmp/mycelora-reflexes-reflexe-update-userid.jsonl
assert_reflexe_json "reflexe-pre-update-user-id" "stdin-pre-update-userid.json" \
  'd["hookSpecificOutput"]["permissionDecision"] == "deny" and "user_id 2ba47612-aaaa-bbbb-cccc-000000000000" in d["hookSpecificOutput"]["permissionDecisionReason"] and "UN compte" in d["hookSpecificOutput"]["permissionDecisionReason"]' \
  "yes"

# --- DELETE sans WHERE : deny, portee "toutes les lignes" ------------------
rm -f /tmp/mycelora-impact-reflexe-delete-nowhere /tmp/mycelora-reflexes-reflexe-delete-nowhere.jsonl
assert_reflexe_json "reflexe-pre-delete-sans-where" "stdin-pre-delete-nowhere.json" \
  'd["hookSpecificOutput"]["permissionDecision"] == "deny" and "SANS clause WHERE" in d["hookSpecificOutput"]["permissionDecisionReason"]' \
  "yes"

# --- Infra : rsync / docker restart / PATCH Coolify / ssh+docker exec+psql,
# aucun appel curl (pas d'objet de schema a chercher) -----------------------
for cas in "stdin-pre-infra-rsync.json:reflexe-pre-infra-rsync:rsync vers volumes/functions" \
           "stdin-pre-infra-docker-restart.json:reflexe-pre-infra-docker-restart:redémarrage direct" \
           "stdin-pre-infra-coolify-patch.json:reflexe-pre-infra-coolify:Coolify" \
           "stdin-pre-infra-ssh-psql.json:reflexe-pre-infra-ssh-psql:accès direct à la base de prod"; do
  fixture="${cas%%:*}"; reste="${cas#*:}"; nom="${reste%%:*}"; motif="${reste#*:}"
  session="$(python3 -c "import json; print(json.load(open('$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/$fixture'))['session_id'])")"
  rm -f "/tmp/mycelora-impact-${session}" "/tmp/mycelora-reflexes-${session}.jsonl"
  TOTAL_TESTS=$((TOTAL_TESTS+1))
  infra_tmp="$(mktemp -d)"
  export MYCELORA_TEST_CURL_LOG="$infra_tmp/call.log"
  export MYCELORA_TEST_CAPTURE_BODY="$infra_tmp/body.json"
  out_infra="$(reflexe_stdin "$fixture" | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
  printf '%s' "$out_infra" > "$infra_tmp/stdout.json"
  verdict_infra="$(python3 - "$infra_tmp/stdout.json" "$motif" <<'PYEOF'
import json, sys
chemin, motif = sys.argv[1], sys.argv[2]
try:
    with open(chemin, encoding="utf-8") as f:
        d = json.loads(f.read())
    ok = d["hookSpecificOutput"]["permissionDecision"] == "deny" and motif in d["hookSpecificOutput"]["permissionDecisionReason"]
    print("OK" if ok else "FAIL:motif absent")
except Exception as e:
    print("FAIL:%s" % e)
PYEOF
)"
  if [ "$verdict_infra" = "OK" ] && [ ! -f "$infra_tmp/call.log" ]; then
    echo "PASS $nom"
  else
    echo "FAIL $nom : verdict=$verdict_infra, curl_appele=$([ -f "$infra_tmp/call.log" ] && echo oui || echo non)"
    FAILED_TESTS=$((FAILED_TESTS+1))
  fi
  rm -rf "$infra_tmp"
done

# --- Cas obligatoire : "alter" dans un commentaire SQL ne declenche pas ---
TOTAL_TESTS=$((TOTAL_TESTS+1))
nodeny_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$nodeny_tmp/call.log"
out_comment="$(reflexe_stdin stdin-pre-comment-alter.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
if [ -z "$out_comment" ] && [ ! -f "$nodeny_tmp/call.log" ]; then
  echo "PASS reflexe-pre-alter-dans-commentaire-ne-declenche-pas"
else
  echo "FAIL reflexe-pre-alter-dans-commentaire-ne-declenche-pas : stdout='$out_comment'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$nodeny_tmp"

# --- Cas obligatoire : "alter" dans un litteral d'un SELECT ne declenche pas
TOTAL_TESTS=$((TOTAL_TESTS+1))
nodeny_tmp2="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$nodeny_tmp2/call.log"
out_select="$(reflexe_stdin stdin-pre-select-litteral-alter.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
if [ -z "$out_select" ] && [ ! -f "$nodeny_tmp2/call.log" ]; then
  echo "PASS reflexe-pre-alter-dans-select-ne-declenche-pas"
else
  echo "FAIL reflexe-pre-alter-dans-select-ne-declenche-pas : stdout='$out_select'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$nodeny_tmp2"

# --- Contre-epreuve par mutation (regle 8bis) sur nettoyer_sql : ces deux
# cas placent "ALTER TABLE ..." en tete de sa PROPRE LIGNE a l'interieur
# respectivement d'un commentaire bloc /* */ et d'un litteral '...' multi-
# lignes. Sans le nettoyage (mutation testee manuellement, voir
# .claude/v2-decisions/S-REFLEXES-2.md), l'ancrage seul ^\s*alter\s+table
# matcherait quand meme puisque la ligne commence bien par "ALTER TABLE" une
# fois les delimiteurs de commentaire/litteral retires du chemin — la ou les
# cas "comment-alter"/"select-litteral-alter" plus haut restent surs par
# construction de l'ancrage SEUL (alter n'y est jamais en tete de ligne),
# ceux-ci sont les seuls a vraiment exercer nettoyer_sql. -------------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
blockcomment_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$blockcomment_tmp/call.log"
out_blockcomment="$(reflexe_stdin stdin-pre-block-comment-alter.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
if [ -z "$out_blockcomment" ] && [ ! -f "$blockcomment_tmp/call.log" ]; then
  echo "PASS reflexe-pre-alter-dans-commentaire-bloc-ne-declenche-pas"
else
  echo "FAIL reflexe-pre-alter-dans-commentaire-bloc-ne-declenche-pas : stdout='$out_blockcomment'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$blockcomment_tmp"

TOTAL_TESTS=$((TOTAL_TESTS+1))
literalml_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$literalml_tmp/call.log"
out_literalml="$(reflexe_stdin stdin-pre-literal-multiline-alter.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
if [ -z "$out_literalml" ] && [ ! -f "$literalml_tmp/call.log" ]; then
  echo "PASS reflexe-pre-alter-dans-litteral-multiligne-ne-declenche-pas"
else
  echo "FAIL reflexe-pre-alter-dans-litteral-multiligne-ne-declenche-pas : stdout='$out_literalml'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$literalml_tmp"

# Contre-epreuve par mutation (regle 8bis) sur l'ANCRAGE de RE_DDL
# specifiquement (independant de nettoyer_sql, verifie separement ci-dessus) :
# "alter table" ici est dans une chaine bash DOUBLE-quotee (argument d'echo),
# jamais touchee par nettoyer_sql (qui ne nettoie que les commentaires SQL et
# les litteraux SQL simple-quotes). Seul l'ancrage "^\s*" en tete
# d'instruction empeche cette commande totalement inoffensive de declencher.
# Mutation testee manuellement (retrait de l'ancrage sur RE_DDL) : ce test
# est le SEUL de la suite a echouer sur cette mutation precise (voir
# .claude/v2-decisions/S-REFLEXES-2.md) — les autres cas "alter en
# commentaire/litteral" passent grace a nettoyer_sql seul, meme sans ancrage.
TOTAL_TESTS=$((TOTAL_TESTS+1))
dquote_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$dquote_tmp/call.log"
out_dquote="$(reflexe_stdin stdin-pre-double-quote-alter-non-tete.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
if [ -z "$out_dquote" ] && [ ! -f "$dquote_tmp/call.log" ]; then
  echo "PASS reflexe-pre-alter-hors-tete-instruction-ne-declenche-pas"
else
  echo "FAIL reflexe-pre-alter-hors-tete-instruction-ne-declenche-pas : stdout='$out_dquote'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$dquote_tmp"

# --- UPDATE avec WHERE reel (pas user_id) : ne declenche pas ---------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
nodeny_tmp3="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$nodeny_tmp3/call.log"
out_whereok="$(reflexe_stdin stdin-pre-update-where-ok.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
if [ -z "$out_whereok" ] && [ ! -f "$nodeny_tmp3/call.log" ]; then
  echo "PASS reflexe-pre-update-avec-where-ne-declenche-pas"
else
  echo "FAIL reflexe-pre-update-avec-where-ne-declenche-pas : stdout='$out_whereok'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$nodeny_tmp3"

# --- Cas obligatoire : interrupteur MYCELORA_REFLEXE_IMPACT=0 desarme -----
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f /tmp/mycelora-impact-reflexe-ddl-alter /tmp/mycelora-reflexes-reflexe-ddl-alter.jsonl
off_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$off_tmp/call.log"
out_off_env="$(reflexe_stdin stdin-pre-ddl-alter-table.json | MYCELORA_REFLEXE_IMPACT=0 PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
if [ -z "$out_off_env" ] && [ ! -f "$off_tmp/call.log" ] && grep -q '"evt": "desarme"' /tmp/mycelora-reflexes-reflexe-ddl-alter.jsonl 2>/dev/null; then
  echo "PASS reflexe-pre-interrupteur-env-var"
else
  echo "FAIL reflexe-pre-interrupteur-env-var : stdout='$out_off_env'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$off_tmp"

# --- Cas obligatoire : interrupteur .mycelora-reflexes-off (fichier) ------
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f /tmp/mycelora-impact-reflexe-ddl-alter /tmp/mycelora-reflexes-reflexe-ddl-alter.jsonl
touch "$REPO_ROOT/.mycelora-reflexes-off"
off_tmp2="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$off_tmp2/call.log"
out_off_file="$(reflexe_stdin stdin-pre-ddl-alter-table.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
rm -f "$REPO_ROOT/.mycelora-reflexes-off"
if [ -z "$out_off_file" ] && [ ! -f "$off_tmp2/call.log" ] && grep -q '"evt": "desarme"' /tmp/mycelora-reflexes-reflexe-ddl-alter.jsonl 2>/dev/null; then
  echo "PASS reflexe-pre-interrupteur-fichier"
else
  echo "FAIL reflexe-pre-interrupteur-fichier : stdout='$out_off_file'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$off_tmp2"

# --- Cas obligatoire : fail-open compte sur serveur muet (timeout) --------
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f /tmp/mycelora-impact-reflexe-ddl-alter /tmp/mycelora-reflexes-reflexe-ddl-alter.jsonl
timeout_tmp="$(mktemp -d)"
cat > "$FAKE_BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo "CALLED" >> "${MYCELORA_TEST_CURL_LOG:-/dev/null}"
exit 28
EOF
chmod +x "$FAKE_BIN_DIR/curl"
export MYCELORA_TEST_CURL_LOG="$timeout_tmp/call.log"
out_timeout="$(reflexe_stdin stdin-pre-ddl-alter-table.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
# Le contenu du rapport porte des apostrophes francaises : jamais
# d'interpolation de chaine dans une commande python, toujours un fichier.
printf '%s' "$out_timeout" > "$timeout_tmp/stdout.json"
verdict_timeout="$(python3 - "$timeout_tmp/stdout.json" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.loads(f.read())
    ok = d["hookSpecificOutput"]["permissionDecision"] == "deny"
    print("OK" if ok else "FAIL:pas de deny")
except Exception as e:
    print("FAIL:%s" % e)
PYEOF
)"
journal_a_lookup_timeout="0"
grep -q '"evt": "lookup_timeout"' /tmp/mycelora-reflexes-reflexe-ddl-alter.jsonl 2>/dev/null && journal_a_lookup_timeout="1"
# Restaure le faux curl "normal" pour la suite des tests. F1 (revue
# adversariale S-REFLEXES-6, 02/09/2026) : cette restauration ecrasait le
# faux curl par une COPIE FIGEE, anterieure a l'ajout de la capture -K/
# MYCELORA_TEST_CAPTURE_CFG dans le generateur du haut de ce fichier -- toute
# la suite des tests execut apres ce point (la quasi-totalite du fichier,
# dont toute la section S-REFLEXES-6) tournait donc avec un faux curl QUI NE
# SAVAIT PAS CAPTURER LE BEARER, meme apres l'avoir ajoute plus haut. Meme
# contenu que le generateur initial desormais (les deux DOIVENT rester
# identiques).
cat > "$FAKE_BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
CALL_LOG="${MYCELORA_TEST_CURL_LOG:?MYCELORA_TEST_CURL_LOG non defini}"
RESP_BODY_FILE="${MYCELORA_TEST_CURL_RESPONSE:-}"
HTTP_CODE="${MYCELORA_TEST_CURL_HTTP_CODE:-200}"
SHOULD_FAIL="${MYCELORA_TEST_CURL_FAIL:-0}"
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
if [ "$SHOULD_FAIL" = "1" ]; then
  exit 7
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
if [ "$verdict_timeout" = "OK" ] && [ "$journal_a_lookup_timeout" = "1" ]; then
  echo "PASS reflexe-pre-fail-open-serveur-muet"
else
  echo "FAIL reflexe-pre-fail-open-serveur-muet : verdict=$verdict_timeout, journal_lookup_timeout=$journal_a_lookup_timeout"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$timeout_tmp"

# --- Cas obligatoire : chemin rapide sans demarrer python sur un outil hors
# perimetre (Edit, non-Bash) : preuve BEHAVIORALE que python3 n'est jamais
# invoque (un faux python3, place avant le vrai dans PATH, journalise son
# appel). -------------------------------------------------------------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
NOPY_DIR="$(mktemp -d)"
cat > "$NOPY_DIR/python3" <<'EOF'
#!/usr/bin/env bash
echo "PYTHON3 CALLED" >> /tmp/mycelora-test-python-called.log
exit 1
EOF
chmod +x "$NOPY_DIR/python3"
rm -f /tmp/mycelora-test-python-called.log
out_nopy="$(reflexe_stdin stdin-pre-edit-nonbash.json | PATH="$NOPY_DIR:$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE" 2>"$NOPY_DIR/stderr")"
rc_nopy=$?
if [ -z "$out_nopy" ] && [ "$rc_nopy" -eq 0 ] && [ ! -f /tmp/mycelora-test-python-called.log ]; then
  echo "PASS reflexe-pre-chemin-rapide-sans-python-outil-hors-perimetre"
else
  echo "FAIL reflexe-pre-chemin-rapide-sans-python-outil-hors-perimetre : stdout='$out_nopy' rc=$rc_nopy python_appele=$([ -f /tmp/mycelora-test-python-called.log ] && echo oui || echo non)"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$NOPY_DIR"
rm -f /tmp/mycelora-test-python-called.log

# Meme preuve pour PostToolUse (outil totalement hors matcher, ex: Read).
TOTAL_TESTS=$((TOTAL_TESTS+1))
NOPY_DIR2="$(mktemp -d)"
cat > "$NOPY_DIR2/python3" <<'EOF'
#!/usr/bin/env bash
echo "PYTHON3 CALLED" >> /tmp/mycelora-test-python-called.log
exit 1
EOF
chmod +x "$NOPY_DIR2/python3"
rm -f /tmp/mycelora-test-python-called.log
read_stdin="$(mktemp)"
cat > "$read_stdin" <<EOF
{"session_id":"reflexe-read-outil","cwd":"$REPO_ROOT","tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}
EOF
out_nopy2="$(cat "$read_stdin" | PATH="$NOPY_DIR2:$FAKE_BIN_DIR:$PATH" "$POSTTOOLUSE" 2>"$NOPY_DIR2/stderr")"
rc_nopy2=$?
if [ -z "$out_nopy2" ] && [ "$rc_nopy2" -eq 0 ] && [ ! -f /tmp/mycelora-test-python-called.log ]; then
  echo "PASS reflexe-post-chemin-rapide-sans-python-outil-hors-perimetre"
else
  echo "FAIL reflexe-post-chemin-rapide-sans-python-outil-hors-perimetre : stdout='$out_nopy2' rc=$rc_nopy2"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$NOPY_DIR2" "$read_stdin"
rm -f /tmp/mycelora-test-python-called.log

# --- Cas obligatoire : aucune sortie stdout hors JSON (le deny est un JSON
# valide, une SEULE ligne, rien avant/apres) --------------------------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f /tmp/mycelora-impact-reflexe-ddl-alter /tmp/mycelora-reflexes-reflexe-ddl-alter.jsonl
jsononly_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$jsononly_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE="$REFLEXE_IMPACT_RESPONSE"
out_jsononly="$(reflexe_stdin stdin-pre-ddl-alter-table.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
printf '%s' "$out_jsononly" > "$jsononly_tmp/stdout.json"
nb_lignes="$(wc -l < "$jsononly_tmp/stdout.json" | tr -d ' ')"
verdict_json="$(python3 - "$jsononly_tmp/stdout.json" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    texte = f.read()
try:
    json.loads(texte)
    print("OK")
except Exception as e:
    print("FAIL:%s" % e)
PYEOF
)"
if [ "$verdict_json" = "OK" ] && [ "$nb_lignes" -le 1 ] 2>/dev/null; then
  echo "PASS reflexe-pre-stdout-json-uniquement"
else
  echo "FAIL reflexe-pre-stdout-json-uniquement : verdict=$verdict_json, lignes=$nb_lignes"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$jsononly_tmp"

# --- Cas obligatoire : le heredoc python n'avale pas stdin (cat > fichier
# AVANT tout heredoc python) — verification STRUCTURELLE sur les deux
# nouveaux hooks, sur le modele du test "placeholder-15" plus haut. La
# preuve COMPORTEMENTALE est deja faite : chaque test ci-dessus qui lit
# correctement tool_name/tool_input depuis stdin le prouve (un heredoc
# avalant stdin plus tot rendrait STDIN_FILE vide, donc TOOL_NAME vide,
# donc tous les cas deny ci-dessus auraient echoue au lieu de passer). -----
for f in mycelora-pretooluse.sh mycelora-posttooluse.sh; do
  TOTAL_TESTS=$((TOTAL_TESTS+1))
  chemin="$REPO_ROOT/plugins/mycelora/hooks/$f"
  ligne_cat="$(grep -n 'cat > "\$STDIN_FILE"' "$chemin" | head -n1 | cut -d: -f1)"
  ligne_heredoc="$(grep -n "<<'PYEOF'" "$chemin" | head -n1 | cut -d: -f1)"
  if [ -n "$ligne_cat" ] && [ -n "$ligne_heredoc" ] && [ "$ligne_cat" -lt "$ligne_heredoc" ]; then
    echo "PASS reflexe-heredoc-n-avale-pas-stdin-$f"
  else
    echo "FAIL reflexe-heredoc-n-avale-pas-stdin-$f : ligne_cat=$ligne_cat ligne_heredoc=$ligne_heredoc"
    FAILED_TESTS=$((FAILED_TESTS+1))
  fi
done

# --- PostToolUse : jalon apres un geste Bash structurant EXECUTE, avec
# marqueur .carte-perimee et journal evt=jalon ------------------------------
rm -f /tmp/mycelora-reflexes-reflexe-post-ddl.jsonl
carte_perimee_avant="0"
[ -f "$REPO_ROOT/.carte-perimee" ] && carte_perimee_avant="$(wc -l < "$REPO_ROOT/.carte-perimee" | tr -d ' ')"
post_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$post_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE="$REFLEXE_IMPACT_RESPONSE"
out_post_ddl="$(reflexe_stdin stdin-post-ddl-executed.json | PATH="$FAKE_BIN_DIR:$PATH" "$POSTTOOLUSE")"
printf '%s' "$out_post_ddl" > "$post_tmp/stdout.json"
verdict_post="$(python3 - "$post_tmp/stdout.json" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.loads(f.read())
    r = d["hookSpecificOutput"]
    ok = (r.get("hookEventName") == "PostToolUse" and "JALON D'IMPACT" in r.get("additionalContext", "")
          and "table_gamma" in r.get("additionalContext", "")
          and "reviewer frais" in r.get("additionalContext", ""))
    print("OK" if ok else "FAIL:contenu")
except Exception as e:
    print("FAIL:%s" % e)
PYEOF
)"
TOTAL_TESTS=$((TOTAL_TESTS+1))
if [ "$verdict_post" = "OK" ]; then
  echo "PASS reflexe-post-jalon-ddl-execute"
else
  echo "FAIL reflexe-post-jalon-ddl-execute : $verdict_post"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
TOTAL_TESTS=$((TOTAL_TESTS+1))
if grep -q '"evt": "jalon"' /tmp/mycelora-reflexes-reflexe-post-ddl.jsonl 2>/dev/null; then
  echo "PASS reflexe-post-jalon-journal"
else
  echo "FAIL reflexe-post-jalon-journal : absent de /tmp/mycelora-reflexes-reflexe-post-ddl.jsonl"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
TOTAL_TESTS=$((TOTAL_TESTS+1))
carte_perimee_apres="0"
[ -f "$REPO_ROOT/.carte-perimee" ] && carte_perimee_apres="$(wc -l < "$REPO_ROOT/.carte-perimee" | tr -d ' ')"
if [ "$carte_perimee_apres" -gt "$carte_perimee_avant" ] 2>/dev/null; then
  echo "PASS reflexe-post-marqueur-carte-perimee"
else
  echo "FAIL reflexe-post-marqueur-carte-perimee : avant=$carte_perimee_avant apres=$carte_perimee_apres"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -f "$REPO_ROOT/.carte-perimee"
rm -rf "$post_tmp"

# --- PostToolUse : edition d'un fichier sensible (migration) -> jalon -----
TOTAL_TESTS=$((TOTAL_TESTS+1))
sens_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$sens_tmp/call.log"
out_post_migration="$(reflexe_stdin stdin-post-migration-sensible.json | PATH="$FAKE_BIN_DIR:$PATH" "$POSTTOOLUSE")"
printf '%s' "$out_post_migration" > "$sens_tmp/stdout.json"
verdict_sens="$(python3 - "$sens_tmp/stdout.json" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.loads(f.read())
    r = d["hookSpecificOutput"]
    ok = "JALON D'IMPACT" in r.get("additionalContext", "") and "migration" in r.get("additionalContext", "")
    print("OK" if ok else "FAIL:contenu")
except Exception as e:
    print("FAIL:%s" % e)
PYEOF
)"
if [ "$verdict_sens" = "OK" ]; then
  echo "PASS reflexe-post-jalon-fichier-sensible-migration"
else
  echo "FAIL reflexe-post-jalon-fichier-sensible-migration : $verdict_sens"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -f "$REPO_ROOT/.carte-perimee"
rm -rf "$sens_tmp"

# --- PostToolUse : edition d'un fichier NON sensible -> rien ---------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
nonsens_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$nonsens_tmp/call.log"
out_post_readme="$(reflexe_stdin stdin-post-readme-nonsensible.json | PATH="$FAKE_BIN_DIR:$PATH" "$POSTTOOLUSE")"
if [ -z "$out_post_readme" ] && [ ! -f "$nonsens_tmp/call.log" ]; then
  echo "PASS reflexe-post-fichier-non-sensible-rien"
else
  echo "FAIL reflexe-post-fichier-non-sensible-rien : stdout='$out_post_readme'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$nonsens_tmp"

# ============================================================================
# CORRECTIONS relecture reviewer/ergonome du 02/09/2026 (4 findings, avant
# ouverture de PR). Chaque bloc ci-dessous prouve UN correctif precis.
# ============================================================================

# --- Finding 1 (HIGH, confirme en reel par le coordinateur) : "update" mot
# anglais courant, sans rapport avec du SQL, ne doit JAMAIS declencher. -----
for fixture in stdin-pre-npm-update.json stdin-pre-apt-get-update.json \
               stdin-pre-brew-update.json stdin-pre-git-remote-update.json \
               stdin-pre-cargo-update.json stdin-pre-update-alternatives.json; do
  TOTAL_TESTS=$((TOTAL_TESTS+1))
  noupdate_tmp="$(mktemp -d)"
  export MYCELORA_TEST_CURL_LOG="$noupdate_tmp/call.log"
  out_noupdate="$(reflexe_stdin "$fixture" | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
  if [ -z "$out_noupdate" ] && [ ! -f "$noupdate_tmp/call.log" ]; then
    echo "PASS reflexe-pre-faux-positif-update-$fixture"
  else
    echo "FAIL reflexe-pre-faux-positif-update-$fixture : stdout='$out_noupdate'"
    FAILED_TESTS=$((FAILED_TESTS+1))
  fi
  rm -rf "$noupdate_tmp"
done

# --- Finding 2 (MEDIUM, confirme en reel) : mention de "docker restart" en
# prose (echo, message de commit) ne doit PAS declencher. ------------------
for fixture in stdin-pre-prose-docker-restart-echo.json stdin-pre-prose-docker-restart-commit.json; do
  TOTAL_TESTS=$((TOTAL_TESTS+1))
  noprose_tmp="$(mktemp -d)"
  export MYCELORA_TEST_CURL_LOG="$noprose_tmp/call.log"
  out_noprose="$(reflexe_stdin "$fixture" | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
  if [ -z "$out_noprose" ] && [ ! -f "$noprose_tmp/call.log" ]; then
    echo "PASS reflexe-pre-faux-positif-infra-prose-$fixture"
  else
    echo "FAIL reflexe-pre-faux-positif-infra-prose-$fixture : stdout='$out_noprose'"
    FAILED_TESTS=$((FAILED_TESTS+1))
  fi
  rm -rf "$noprose_tmp"
done

# --- Contre-epreuve du gating (finding 2) : un VRAI docker restart apres un
# separateur shell reel (&&) doit continuer a declencher -- le gating de
# position ne doit pas etre une regression deguisee en faux negatif. -------
rm -f /tmp/mycelora-impact-reflexe-infra-apres-separateur /tmp/mycelora-reflexes-reflexe-infra-apres-separateur.jsonl
TOTAL_TESTS=$((TOTAL_TESTS+1))
apres_sep_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$apres_sep_tmp/call.log"
out_apres_sep="$(reflexe_stdin stdin-pre-infra-apres-separateur.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE")"
printf '%s' "$out_apres_sep" > "$apres_sep_tmp/stdout.json"
verdict_apres_sep="$(python3 - "$apres_sep_tmp/stdout.json" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.loads(f.read())
    ok = d["hookSpecificOutput"]["permissionDecision"] == "deny" and "redémarrage direct" in d["hookSpecificOutput"]["permissionDecisionReason"]
    print("OK" if ok else "FAIL:contenu")
except Exception as e:
    print("FAIL:%s" % e)
PYEOF
)"
if [ "$verdict_apres_sep" = "OK" ]; then
  echo "PASS reflexe-pre-infra-declenche-toujours-apres-separateur"
else
  echo "FAIL reflexe-pre-infra-declenche-toujours-apres-separateur : $verdict_apres_sep"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$apres_sep_tmp"

# --- Finding 4 (trouve par l'ergonome en reel) : ALTER TABLE a 4 clauses
# ADD/DROP COLUMN -- AUCUNE colonne ne doit disparaitre silencieusement. ---
rm -f /tmp/mycelora-impact-reflexe-alter-multi-colonnes /tmp/mycelora-reflexes-reflexe-alter-multi-colonnes.jsonl
assert_reflexe_json "reflexe-pre-alter-multi-colonnes-aucune-perdue" "stdin-pre-alter-multi-colonnes.json" \
  'd["hookSpecificOutput"]["permissionDecision"] == "deny" and all(("Objet : memory_atoms.%s (" % c) in d["hookSpecificOutput"]["permissionDecisionReason"] for c in ("priorite", "statut", "score", "legacy"))' \
  "yes"

# --- Finding 3 (LOW) : si la construction python du rapport leve AVANT
# d'ecrire out_report, le repli textuel generique doit partir ET
# rapport_vide doit etre journalise a true -- jamais un rapport vide,
# jamais silencieux (piege 3 du brief). Test DIRECT de la fonction (pas via
# le hook complet) : objets_json = "42" (JSON valide mais pas une LISTE)
# fait lever `for o in objets:` (TypeError, pas gardee par le try/except
# qui ne protege que le PARSING JSON, pas la FORME rendue) -- realiste
# (donnee corrompue en amont) et NEUTRE cote fichiers (out_report/out_meta
# restent des chemins /tmp normaux, comme dans le vrai hook ou ils sont
# toujours crees par mktemp avant l'appel) : le repli bash peut donc
# ecrire dessus normalement, contrairement a un chemin dans un dossier
# inexistant (premier essai de cette preuve, ecarte : cassait AUSSI
# l'ecriture de repli elle-meme, ne prouvait rien d'utile). -----------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
failopen_tmp="$(mktemp -d)"
echo '{"resultats": {}}' > "$failopen_tmp/local.json"
echo '{}' > "$failopen_tmp/server.json"
out_report_normal="$failopen_tmp/rapport.txt"
out_meta_ok="$failopen_tmp/meta.json"
# Sous-processus bash ISOLE (pas un `source` dans CE script) : le trap
# `RETURN` pose par la fonction `assert` plus haut (ligne ~76,
# `trap 'rm -rf "$temp_dir"' RETURN`) fuit hors de son appel et se
# redeclenche sur tout evenement RETURN suivant dans CE shell -- source
# le declenchait avec un $temp_dir hors-scope ("unbound variable" sous
# set -u). Un `bash -c` neuf n'a aucun trap herite, aucun risque.
bash -c '
  set -uo pipefail
  source "$1/plugins/mycelora/hooks/mycelora-common.sh"
  mycelora_reflexe_construire_rapport "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
' _ "$REPO_ROOT" "42" "ddl" "" "" "" "" \
  "$failopen_tmp/local.json" "$failopen_tmp/server.json" "$out_report_normal" "$out_meta_ok"
verdict_failopen="ERREUR"
if [ -s "$out_report_normal" ] 2>/dev/null; then
  verdict_failopen="rapport-non-vide"
fi
rapport_vide_meta="$(python3 -c "
import json
try:
    print('1' if json.load(open('$out_meta_ok')).get('rapport_vide') else '0')
except Exception:
    print('erreur')
" 2>/dev/null)"
if [ "$verdict_failopen" = "rapport-non-vide" ] && [ "$rapport_vide_meta" = "1" ]; then
  echo "PASS reflexe-construire-rapport-fail-open-jamais-silencieux"
else
  echo "FAIL reflexe-construire-rapport-fail-open-jamais-silencieux : rapport=$verdict_failopen, rapport_vide_meta=$rapport_vide_meta"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$failopen_tmp"

# ============================================================================
# S-REFLEXES-5b (02/09/2026) — carte_age_jours (mycelora_reflexe_log,
# mycelora_reflexe_construire_rapport) et mycelora-stop.sh (remontee
# "reflexes", question_humain, purge apres 2xx). Choix documentes dans
# .claude/v2-decisions/S-REFLEXES-5b.md.
# ============================================================================

# --- mycelora_reflexe_log : carte_age_jours ecrit (numerique) quand fourni,
# JAMAIS une cle a null ni une chaine vide, omise purement et simplement
# sinon (meme discipline que tools.ts cote serveur pour ce champ). ----------
reflog_journal="/tmp/mycelora-reflexes-reflog-test-session.jsonl"
rm -f "$reflog_journal"
bash -c '
  set -uo pipefail
  source "$1/plugins/mycelora/hooks/mycelora-common.sh"
  mycelora_reflexe_log "reflog-test-session" "refus" "Bash" "[\"t1\"]" "empreinte1" "0" "5"
' _ "$REPO_ROOT"
TOTAL_TESTS=$((TOTAL_TESTS+1))
verdict_reflog_avec="$(python3 -c "
import json
try:
    d = json.loads(open('$reflog_journal').read().strip().splitlines()[-1])
    print('OK' if d.get('carte_age_jours') == 5 else 'FAIL:%r' % d)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$verdict_reflog_avec" = "OK" ]; then
  echo "PASS reflexe-log-carte-age-jours-ecrit-quand-fourni"
else
  echo "FAIL reflexe-log-carte-age-jours-ecrit-quand-fourni : $verdict_reflog_avec"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

rm -f "$reflog_journal"
bash -c '
  set -uo pipefail
  source "$1/plugins/mycelora/hooks/mycelora-common.sh"
  mycelora_reflexe_log "reflog-test-session" "passage" "Bash" "[\"t1\"]" "empreinte1" "0"
' _ "$REPO_ROOT"
TOTAL_TESTS=$((TOTAL_TESTS+1))
verdict_reflog_sans="$(python3 -c "
import json
try:
    d = json.loads(open('$reflog_journal').read().strip().splitlines()[-1])
    print('OK' if 'carte_age_jours' not in d else 'FAIL:%r' % d)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$verdict_reflog_sans" = "OK" ]; then
  echo "PASS reflexe-log-carte-age-jours-omis-quand-absent"
else
  echo "FAIL reflexe-log-carte-age-jours-omis-quand-absent : $verdict_reflog_sans"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -f "$reflog_journal"

# --- mycelora_reflexe_construire_rapport : les 4 cas du calcul de
# carte_age_jours (candidat par objet, MAX des candidats, priorite absolue de
# l'echec de lookup). Test DIRECT de la fonction (meme patron que la preuve
# fail-open plus haut : bash -c isole, jamais un `source` dans CE script). --

# Cas 1 : resolution LOCALE seule (grep frais) -> candidat 0.
# CONTRE-EPREUVE PAR MUTATION (DoD) verifiee manuellement le 02/09/2026 :
# `candidats_age.append(0)` mute en `candidats_age.append(1)` dans
# mycelora_reflexe_construire_rapport fait echouer CE test (carte_age_jours
# rendu vaut "1", pas "0") ; mutation revertie aussitot apres verification,
# aucune trace dans le code final. Voir .claude/v2-decisions/S-REFLEXES-5b.md.
TOTAL_TESTS=$((TOTAL_TESTS+1))
age_local_tmp="$(mktemp -d)"
cat > "$age_local_tmp/local.json" <<'EOF'
{"resultats": {"tabla_local": {"lu_par": ["a.ts"], "ecrit_par": []}}}
EOF
echo '{}' > "$age_local_tmp/server.json"
bash -c '
  set -uo pipefail
  source "$1/plugins/mycelora/hooks/mycelora-common.sh"
  mycelora_reflexe_construire_rapport "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
' _ "$REPO_ROOT" '["tabla_local"]' "ddl" "" "" "" "" \
  "$age_local_tmp/local.json" "$age_local_tmp/server.json" "$age_local_tmp/rapport.txt" "$age_local_tmp/meta.json"
age_local_verdict="$(python3 -c "
import json
try:
    print(json.load(open('$age_local_tmp/meta.json')).get('carte_age_jours'))
except Exception as e:
    print('ERROR:%s' % e)
")"
if [ "$age_local_verdict" = "0" ]; then
  echo "PASS reflexe-carte-age-jours-local-seul-zero"
else
  echo "FAIL reflexe-carte-age-jours-local-seul-zero : $age_local_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$age_local_tmp"

# Cas 2 : resolution SERVEUR seule, age connu (genere_le il y a 5 jours,
# calcule dynamiquement -- jamais une date figee, la suite doit rester verte
# a n'importe quelle date d'execution).
TOTAL_TESTS=$((TOTAL_TESTS+1))
age_srv_tmp="$(mktemp -d)"
echo '{"resultats": {}}' > "$age_srv_tmp/local.json"
python3 - "$age_srv_tmp/server.json" <<'PYEOF'
import datetime, json, sys
out_path = sys.argv[1]
genere_le = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
inner = {
    "spaceId": "sp1", "carteVide": False, "dateCarte": genere_le, "carteperimee": False, "avertissement": None,
    "objets": [{"identifiant": "tabla_srv", "inconnu": False, "lignes": [{
        "type": "table", "objet": "tabla_srv", "colonnes": [], "lu_par": ["x.ts"], "ecrit_par": [],
        "rpc": [], "section_carte": "", "genere_le": genere_le, "empreinte": "x"
    }]}]
}
payload = {"jsonrpc": "2.0", "result": {"content": [{"type": "text", "text": json.dumps(inner, ensure_ascii=False)}]}}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF
bash -c '
  set -uo pipefail
  source "$1/plugins/mycelora/hooks/mycelora-common.sh"
  mycelora_reflexe_construire_rapport "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
' _ "$REPO_ROOT" '["tabla_srv"]' "ddl" "" "" "" "" \
  "$age_srv_tmp/local.json" "$age_srv_tmp/server.json" "$age_srv_tmp/rapport.txt" "$age_srv_tmp/meta.json"
age_srv_verdict="$(python3 -c "
import json
try:
    print(json.load(open('$age_srv_tmp/meta.json')).get('carte_age_jours'))
except Exception as e:
    print('ERROR:%s' % e)
")"
if [ "$age_srv_verdict" = "5" ]; then
  echo "PASS reflexe-carte-age-jours-serveur-seul-age-connu"
else
  echo "FAIL reflexe-carte-age-jours-serveur-seul-age-connu : $age_srv_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$age_srv_tmp"

# Cas 3 : melange LOCAL (candidat 0) + SERVEUR (candidat 7) -> MAX = 7 (le
# rapport le plus defavorable, pas la derniere source vue).
TOTAL_TESTS=$((TOTAL_TESTS+1))
age_mix_tmp="$(mktemp -d)"
cat > "$age_mix_tmp/local.json" <<'EOF'
{"resultats": {"tabla_local_mix": {"lu_par": ["a.ts"], "ecrit_par": []}}}
EOF
python3 - "$age_mix_tmp/server.json" <<'PYEOF'
import datetime, json, sys
out_path = sys.argv[1]
genere_le = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
inner = {
    "spaceId": "sp1", "carteVide": False, "dateCarte": genere_le, "carteperimee": False, "avertissement": None,
    "objets": [{"identifiant": "tabla_srv_mix", "inconnu": False, "lignes": [{
        "type": "table", "objet": "tabla_srv_mix", "colonnes": [], "lu_par": ["y.ts"], "ecrit_par": [],
        "rpc": [], "section_carte": "", "genere_le": genere_le, "empreinte": "x"
    }]}]
}
payload = {"jsonrpc": "2.0", "result": {"content": [{"type": "text", "text": json.dumps(inner, ensure_ascii=False)}]}}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF
bash -c '
  set -uo pipefail
  source "$1/plugins/mycelora/hooks/mycelora-common.sh"
  mycelora_reflexe_construire_rapport "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
' _ "$REPO_ROOT" '["tabla_local_mix", "tabla_srv_mix"]' "ddl" "" "" "" "" \
  "$age_mix_tmp/local.json" "$age_mix_tmp/server.json" "$age_mix_tmp/rapport.txt" "$age_mix_tmp/meta.json"
age_mix_verdict="$(python3 -c "
import json
try:
    print(json.load(open('$age_mix_tmp/meta.json')).get('carte_age_jours'))
except Exception as e:
    print('ERROR:%s' % e)
")"
if [ "$age_mix_verdict" = "7" ]; then
  echo "PASS reflexe-carte-age-jours-melange-local-serveur-le-max"
else
  echo "FAIL reflexe-carte-age-jours-melange-local-serveur-le-max : $age_mix_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$age_mix_tmp"

# Cas 4 : echec REEL du lookup (lookup_timeout) -> ABSENT en PRIORITE, meme
# si un objet est par ailleurs resolu localement (candidat 0 ignore).
TOTAL_TESTS=$((TOTAL_TESTS+1))
age_fail_tmp="$(mktemp -d)"
cat > "$age_fail_tmp/local.json" <<'EOF'
{"resultats": {"tabla_local_fail": {"lu_par": ["a.ts"], "ecrit_par": []}}}
EOF
echo '{}' > "$age_fail_tmp/server.json"
bash -c '
  set -uo pipefail
  source "$1/plugins/mycelora/hooks/mycelora-common.sh"
  mycelora_reflexe_construire_rapport "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
' _ "$REPO_ROOT" '["tabla_local_fail"]' "ddl" "" "" "" "lookup_timeout" \
  "$age_fail_tmp/local.json" "$age_fail_tmp/server.json" "$age_fail_tmp/rapport.txt" "$age_fail_tmp/meta.json"
age_fail_verdict="$(python3 -c "
import json
try:
    d = json.load(open('$age_fail_tmp/meta.json'))
    print('null' if d.get('carte_age_jours') is None else d.get('carte_age_jours'))
except Exception as e:
    print('ERROR:%s' % e)
")"
if [ "$age_fail_verdict" = "null" ]; then
  echo "PASS reflexe-carte-age-jours-lookup-echec-priorite-absent"
else
  echo "FAIL reflexe-carte-age-jours-lookup-echec-priorite-absent : $age_fail_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$age_fail_tmp"

# --- Plombage bout en bout (mycelora-pretooluse.sh -> META_FILE ->
# mycelora_reflexe_log) : le hook complet lit bien carte_age_jours dans le
# meta et le fait suivre jusque dans la ligne "refus" du journal. ----------

# Cas SERVEUR (age connu, calcule dynamiquement) : ALTER TABLE memory_atoms.
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f /tmp/mycelora-impact-reflexe-carte-age-jours-serveur /tmp/mycelora-reflexes-reflexe-carte-age-jours-serveur.jsonl
cajs_tmp="$(mktemp -d)"
cajs_resp="$cajs_tmp/resp.json"
python3 - "$cajs_resp" <<'PYEOF'
import datetime, json, sys
out_path = sys.argv[1]
genere_le = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
inner = {
    "spaceId": "sp1", "carteVide": False, "dateCarte": genere_le, "carteperimee": False, "avertissement": None,
    "objets": [{"identifiant": "memory_atoms", "inconnu": False, "lignes": [{
        "type": "table", "objet": "memory_atoms", "colonnes": [], "lu_par": ["recall.ts"], "ecrit_par": [],
        "rpc": [], "section_carte": "Tables coeur (l.410)", "genere_le": genere_le, "empreinte": "x"
    }]}]
}
payload = {"jsonrpc": "2.0", "result": {"content": [{"type": "text", "text": json.dumps(inner, ensure_ascii=False)}]}}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF
export MYCELORA_TEST_CURL_LOG="$cajs_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE="$cajs_resp"
export MYCELORA_TEST_CURL_HTTP_CODE="200"
export MYCELORA_TEST_CAPTURE_BODY="$cajs_tmp/body.json"
reflexe_stdin stdin-pre-carte-age-jours-serveur.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE" > /dev/null 2>&1
cajs_verdict="$(python3 -c "
import json
try:
    lignes = [json.loads(l) for l in open('/tmp/mycelora-reflexes-reflexe-carte-age-jours-serveur.jsonl') if l.strip()]
    refus = [l for l in lignes if l.get('evt') == 'refus']
    ok = len(refus) == 1 and refus[0].get('carte_age_jours') == 3
    print('OK' if ok else 'FAIL:%r' % lignes)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$cajs_verdict" = "OK" ]; then
  echo "PASS reflexe-carte-age-jours-full-hook-serveur-jusquau-journal"
else
  echo "FAIL reflexe-carte-age-jours-full-hook-serveur-jusquau-journal : $cajs_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$cajs_tmp"
rm -f /tmp/mycelora-impact-reflexe-carte-age-jours-serveur /tmp/mycelora-reflexes-reflexe-carte-age-jours-serveur.jsonl

# Cas INFRA (pas de rapport par objet, jamais de carte consultee) -> absent.
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f /tmp/mycelora-impact-reflexe-infra-ssh-psql /tmp/mycelora-reflexes-reflexe-infra-ssh-psql.jsonl
cajinfra_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$cajinfra_tmp/call.log"
export MYCELORA_TEST_CAPTURE_BODY="$cajinfra_tmp/body.json"
reflexe_stdin stdin-pre-infra-ssh-psql.json | PATH="$FAKE_BIN_DIR:$PATH" "$PRETOOLUSE" > /dev/null 2>&1
cajinfra_verdict="$(python3 -c "
import json
try:
    lignes = [json.loads(l) for l in open('/tmp/mycelora-reflexes-reflexe-infra-ssh-psql.jsonl') if l.strip()]
    refus = [l for l in lignes if l.get('evt') == 'refus']
    ok = len(refus) == 1 and 'carte_age_jours' not in refus[0]
    print('OK' if ok else 'FAIL:%r' % lignes)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$cajinfra_verdict" = "OK" ]; then
  echo "PASS reflexe-carte-age-jours-infra-absent"
else
  echo "FAIL reflexe-carte-age-jours-infra-absent : $cajinfra_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$cajinfra_tmp"
rm -f /tmp/mycelora-impact-reflexe-infra-ssh-psql /tmp/mycelora-reflexes-reflexe-infra-ssh-psql.jsonl

# ============================================================================
# mycelora-stop.sh : remontee "reflexes", question_humain, purge apres 2xx.
# ============================================================================

REFLEXES_TEST_SESSION="726ec160-e1f5-5bd0-b3e7-3de9785ea2be"
REFLEXES_TEST_FILE="/tmp/mycelora-reflexes-${REFLEXES_TEST_SESSION}.jsonl"

# A. Journal absent -> pas de cle "reflexes" du tout (meme posture que
# ackLotIds absent).
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "$REFLEXES_TEST_FILE"
c1_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$c1_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE=""
export MYCELORA_TEST_CURL_HTTP_CODE="200"
export MYCELORA_TEST_CAPTURE_BODY="$c1_tmp/body.json"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
c1_verdict="$(python3 -c "
import json
try:
    d = json.load(open('$c1_tmp/body.json'))
    print('OK' if 'reflexes' not in d['params']['arguments'] else 'FAIL:present')
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$c1_verdict" = "OK" ]; then
  echo "PASS reflexe-stop-journal-absent-pas-de-cle-reflexes"
else
  echo "FAIL reflexe-stop-journal-absent-pas-de-cle-reflexes : $c1_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$c1_tmp"

# B. Journal present -> "reflexes" part avec le corps, purge SEULEMENT apres
# un 2xx.
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "$REFLEXES_TEST_FILE"
printf '%s\n' '{"t":"2026-09-01T10:00:00Z","evt":"refus","outil":"Bash","objets":["tbl1"],"empreinte":"e1","rapport_vide":false}' > "$REFLEXES_TEST_FILE"
printf '%s\n' '{"t":"2026-09-01T10:00:05Z","evt":"passage","outil":"Bash","objets":["tbl1"],"empreinte":"e1","rapport_vide":false}' >> "$REFLEXES_TEST_FILE"
c2_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$c2_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE=""
export MYCELORA_TEST_CURL_HTTP_CODE="200"
export MYCELORA_TEST_CAPTURE_BODY="$c2_tmp/body.json"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
c2_verdict="$(python3 -c "
import json
try:
    d = json.load(open('$c2_tmp/body.json'))
    refs = d['params']['arguments'].get('reflexes')
    print('OK' if isinstance(refs, list) and len(refs) == 2 and refs[0]['evt'] == 'refus' and refs[1]['evt'] == 'passage' else 'FAIL:%r' % refs)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$c2_verdict" = "OK" ] && [ ! -f "$REFLEXES_TEST_FILE" ]; then
  echo "PASS reflexe-stop-journal-present-et-purge-apres-2xx"
else
  echo "FAIL reflexe-stop-journal-present-et-purge-apres-2xx : $c2_verdict, fichier=$([ -f "$REFLEXES_TEST_FILE" ] && echo PRESENT || echo absent)"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$c2_tmp"

# C. Erreur HTTP -> le journal RESTE (rejoue au Stop suivant).
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "$REFLEXES_TEST_FILE"
printf '%s\n' '{"t":"2026-09-01T10:00:00Z","evt":"refus","outil":"Bash","objets":["tbl1"],"empreinte":"e1","rapport_vide":false}' > "$REFLEXES_TEST_FILE"
c3_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$c3_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE=""
export MYCELORA_TEST_CURL_HTTP_CODE="500"
export MYCELORA_TEST_CAPTURE_BODY="$c3_tmp/body.json"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
if [ -f "$REFLEXES_TEST_FILE" ]; then
  echo "PASS reflexe-stop-echec-http-garde-le-journal"
else
  echo "FAIL reflexe-stop-echec-http-garde-le-journal : fichier supprime malgre le 500"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
export MYCELORA_TEST_CURL_HTTP_CODE="200"
rm -rf "$c3_tmp"
rm -f "$REFLEXES_TEST_FILE"

# D. Timeout (curl en echec, pas seulement un mauvais code HTTP) -> le
# journal RESTE aussi.
TOTAL_TESTS=$((TOTAL_TESTS+1))
printf '%s\n' '{"t":"2026-09-01T10:00:00Z","evt":"refus","outil":"Bash","objets":["tbl1"],"empreinte":"e1","rapport_vide":false}' > "$REFLEXES_TEST_FILE"
c3b_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$c3b_tmp/call.log"
export MYCELORA_TEST_CURL_FAIL="1"
export MYCELORA_TEST_CAPTURE_BODY="$c3b_tmp/body.json"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
if [ -f "$REFLEXES_TEST_FILE" ]; then
  echo "PASS reflexe-stop-timeout-garde-le-journal"
else
  echo "FAIL reflexe-stop-timeout-garde-le-journal : fichier supprime malgre le timeout"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
unset MYCELORA_TEST_CURL_FAIL
rm -rf "$c3b_tmp"
rm -f "$REFLEXES_TEST_FILE"

# E. question_humain pose par signal (a) : .cc-attente-decision.md present
# directement dans le cwd du fixture (cwd substitue a un dossier temporaire
# reel, pas de recherche recursive).
TOTAL_TESTS=$((TOTAL_TESTS+1))
c4_cwd="$(mktemp -d)"
touch "$c4_cwd/.cc-attente-decision.md"
c4_session="reflexe-stop-cwd-signal"
c4_journal="/tmp/mycelora-reflexes-${c4_session}.jsonl"
rm -f "$c4_journal"
printf '%s\n' '{"t":"2026-09-01T10:00:00Z","evt":"refus","outil":"Bash","objets":["tbl1"],"empreinte":"e1","rapport_vide":false}' > "$c4_journal"
c4_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$c4_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE=""
export MYCELORA_TEST_CURL_HTTP_CODE="200"
export MYCELORA_TEST_CAPTURE_BODY="$c4_tmp/body.json"
sed "s#CWD_PLACEHOLDER#$c4_cwd#g" "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-reflexes-cwd.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
c4_verdict="$(python3 -c "
import json
try:
    d = json.load(open('$c4_tmp/body.json'))
    refs = d['params']['arguments'].get('reflexes')
    print('OK' if isinstance(refs, list) and len(refs) == 1 and refs[0].get('question_humain') is True else 'FAIL:%r' % refs)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$c4_verdict" = "OK" ]; then
  echo "PASS reflexe-stop-question-humain-signal-fichier-decision"
else
  echo "FAIL reflexe-stop-question-humain-signal-fichier-decision : $c4_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$c4_tmp" "$c4_cwd"
rm -f "$c4_journal"

# F. question_humain pose par signal (b) : un "?" dans la reponse assistant
# de ce tour (simple presence, pas de NLP).
c5_session="reflexe-stop-question"
c5_journal="/tmp/mycelora-reflexes-${c5_session}.jsonl"

TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "$c5_journal"
printf '%s\n' '{"t":"2026-09-01T10:00:00Z","evt":"refus","outil":"Bash","objets":["tbl1"],"empreinte":"e1","rapport_vide":false}' > "$c5_journal"
c5_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$c5_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE=""
export MYCELORA_TEST_CURL_HTTP_CODE="200"
export MYCELORA_TEST_CAPTURE_BODY="$c5_tmp/body.json"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-reflexes-question.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
c5_verdict="$(python3 -c "
import json
try:
    d = json.load(open('$c5_tmp/body.json'))
    refs = d['params']['arguments'].get('reflexes')
    print('OK' if isinstance(refs, list) and len(refs) == 1 and refs[0].get('question_humain') is True else 'FAIL:%r' % refs)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$c5_verdict" = "OK" ]; then
  echo "PASS reflexe-stop-question-humain-signal-point-interrogation"
else
  echo "FAIL reflexe-stop-question-humain-signal-point-interrogation : $c5_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$c5_tmp"

# G. Aucun refus dans le lot -> question_humain n'est JAMAIS pose (pas de
# ligne creee), meme si le signal "?" est present.
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "$c5_journal"
printf '%s\n' '{"t":"2026-09-01T10:00:00Z","evt":"passage","outil":"Bash","objets":["tbl1"],"empreinte":"e1","rapport_vide":false}' > "$c5_journal"
c6_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$c6_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE=""
export MYCELORA_TEST_CURL_HTTP_CODE="200"
export MYCELORA_TEST_CAPTURE_BODY="$c6_tmp/body.json"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-reflexes-question.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
c6_verdict="$(python3 -c "
import json
try:
    d = json.load(open('$c6_tmp/body.json'))
    refs = d['params']['arguments'].get('reflexes')
    print('OK' if isinstance(refs, list) and len(refs) == 1 and 'question_humain' not in refs[0] else 'FAIL:%r' % refs)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$c6_verdict" = "OK" ]; then
  echo "PASS reflexe-stop-question-humain-non-pose-sans-refus"
else
  echo "FAIL reflexe-stop-question-humain-non-pose-sans-refus : $c6_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$c6_tmp"

# H. Plusieurs refus dans le lot -> question_humain pose SEULEMENT sur le
# plus recent (le plus grand "t"), jamais sur les autres, meme si une ligne
# non-refus plus recente encore existe dans le lot.
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "$c5_journal"
printf '%s\n' '{"t":"2026-09-01T10:00:00Z","evt":"refus","outil":"Bash","objets":["tbl_old"],"empreinte":"e1","rapport_vide":false}' > "$c5_journal"
printf '%s\n' '{"t":"2026-09-01T09:00:00Z","evt":"refus","outil":"Bash","objets":["tbl_ancien"],"empreinte":"e0","rapport_vide":false}' >> "$c5_journal"
printf '%s\n' '{"t":"2026-09-01T11:00:00Z","evt":"refus","outil":"Bash","objets":["tbl_recent"],"empreinte":"e2","rapport_vide":false}' >> "$c5_journal"
printf '%s\n' '{"t":"2026-09-01T11:30:00Z","evt":"passage","outil":"Bash","objets":["tbl_recent"],"empreinte":"e2","rapport_vide":false}' >> "$c5_journal"
c7_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$c7_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE=""
export MYCELORA_TEST_CURL_HTTP_CODE="200"
export MYCELORA_TEST_CAPTURE_BODY="$c7_tmp/body.json"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-reflexes-question.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
c7_verdict="$(python3 -c "
import json
try:
    d = json.load(open('$c7_tmp/body.json'))
    refs = d['params']['arguments'].get('reflexes')
    tagged = [r for r in refs if r.get('question_humain')]
    ok = (len(tagged) == 1 and tagged[0]['objets'] == ['tbl_recent'] and tagged[0]['evt'] == 'refus')
    print('OK' if ok else 'FAIL:%r' % refs)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$c7_verdict" = "OK" ]; then
  echo "PASS reflexe-stop-question-humain-refus-le-plus-recent-seul"
else
  echo "FAIL reflexe-stop-question-humain-refus-le-plus-recent-seul : $c7_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$c7_tmp"
rm -f "$c5_journal"

# I. CORRECTION post-revue (apres ff82375) : une ligne JSON valide mais au
# TYPE inattendu ("t" un entier, pas une chaine) melangee a des lignes
# valides NE DOIT PAS faire planter le hook -- ancien bug reproduit :
# max(refus_entries, key=lambda e: e.get("t") or "") levait un TypeError
# NON attrape (comparaison str/int) qui tuait le bloc python AVANT
# json.dump(payload, ...), laissait BODY_FILE vide, et empechait la purge
# a chaque Stop suivant (gel silencieux de tout mnemos_log_exchange du
# fil). Le hook doit terminer proprement, envoyer TOUTES les lignes dans
# "reflexes" (la ligne poison n'est PAS exclue du tableau, seulement de la
# logique question_humain), et taguer le dernier refus VALIDE (t et evt
# tous deux des chaines).
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "$c5_journal"
printf '%s\n' '{"t":"2026-09-01T10:00:00Z","evt":"refus","outil":"Bash","objets":["tbl_valide_1"],"empreinte":"e1","rapport_vide":false}' > "$c5_journal"
printf '%s\n' '{"t":5,"evt":"refus","outil":"Bash","objets":["tbl_poison"],"empreinte":"e2","rapport_vide":false}' >> "$c5_journal"
printf '%s\n' '{"t":"2026-09-01T12:00:00Z","evt":"refus","outil":"Bash","objets":["tbl_valide_2"],"empreinte":"e3","rapport_vide":false}' >> "$c5_journal"
c8_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$c8_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE=""
export MYCELORA_TEST_CURL_HTTP_CODE="200"
export MYCELORA_TEST_CAPTURE_BODY="$c8_tmp/body.json"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-reflexes-question.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
c8_verdict="$(python3 -c "
import json
try:
    d = json.load(open('$c8_tmp/body.json'))
    refs = d['params']['arguments'].get('reflexes')
    tagged = [r for r in refs if r.get('question_humain')]
    ok = (isinstance(refs, list) and len(refs) == 3 and len(tagged) == 1 and tagged[0]['objets'] == ['tbl_valide_2'])
    print('OK' if ok else 'FAIL:%r' % refs)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$c8_verdict" = "OK" ] && [ ! -f "$c5_journal" ]; then
  echo "PASS reflexe-stop-question-humain-ligne-type-inattendu-ne-plante-pas"
else
  echo "FAIL reflexe-stop-question-humain-ligne-type-inattendu-ne-plante-pas : $c8_verdict, fichier=$([ -f "$c5_journal" ] && echo PRESENT || echo absent)"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$c8_tmp"
rm -f "$c5_journal"

# J. Deux refus au MEME "t" (egalite a la seconde, resolution reelle de
# mycelora_reflexe_log) -> le DERNIER ecrit dans le fichier (le plus
# recent) doit etre tague, jamais le premier. Ancien bug : max() Python
# renvoie le PREMIER element rencontre en cas d'egalite de cle, donc
# l'ancien refus etait tague a tort. refus_entries[-1] (ordre d'ecriture,
# journal append-only) resout ce cas sans avoir besoin de comparer "t".
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "$c5_journal"
printf '%s\n' '{"t":"2026-09-01T10:00:00Z","evt":"refus","outil":"Bash","objets":["tbl_premier_meme_seconde"],"empreinte":"e1","rapport_vide":false}' > "$c5_journal"
printf '%s\n' '{"t":"2026-09-01T10:00:00Z","evt":"refus","outil":"Bash","objets":["tbl_dernier_meme_seconde"],"empreinte":"e2","rapport_vide":false}' >> "$c5_journal"
c9_tmp="$(mktemp -d)"
export MYCELORA_TEST_CURL_LOG="$c9_tmp/call.log"
export MYCELORA_TEST_CURL_RESPONSE=""
export MYCELORA_TEST_CURL_HTTP_CODE="200"
export MYCELORA_TEST_CAPTURE_BODY="$c9_tmp/body.json"
cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-reflexes-question.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh" > /dev/null 2>&1
c9_verdict="$(python3 -c "
import json
try:
    d = json.load(open('$c9_tmp/body.json'))
    refs = d['params']['arguments'].get('reflexes')
    tagged = [r for r in refs if r.get('question_humain')]
    ok = (len(tagged) == 1 and tagged[0]['objets'] == ['tbl_dernier_meme_seconde'])
    print('OK' if ok else 'FAIL:%r' % refs)
except Exception as e:
    print('FAIL:%s' % e)
")"
if [ "$c9_verdict" = "OK" ]; then
  echo "PASS reflexe-stop-question-humain-egalite-t-le-dernier-ecrit-gagne"
else
  echo "FAIL reflexe-stop-question-humain-egalite-t-le-dernier-ecrit-gagne : $c9_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$c9_tmp"
rm -f "$c5_journal"

# ============================================================================
# S-REFLEXES-6 (02/09/2026) — jeton de session hook, canal marketplace.
# Cache v3 (spaceId/sessionLabel/customTitle/hookToken), extraire_jeton,
# mycelora_resolve_hook_token, cas sans-jeton des quatre hooks, 401 type
# (jeton_session_expire) distinct d'un 401 generique.
# ============================================================================

COMMON_SH="$REPO_ROOT/plugins/mycelora/hooks/mycelora-common.sh"
JETON_TRANSCRIPT="$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/transcript-session-start-avec-jeton.jsonl"
JETON_TRANSCRIPT_STRING="$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/transcript-session-start-jeton-content-string.jsonl"
NO_SESSION_START_TRANSCRIPT="$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/transcript-no-session-start.jsonl"

# --- Cache v2 existant : traite comme ABSENT, reconstruit en v3 (meme regle
# que le passage v1 -> v2). ------------------------------------------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
v2_session="s-reflexes-6-cache-v2"
v2_cache="/tmp/mycelora-hook-${v2_session}.json"
rm -f "$v2_cache"
printf '%s' '{"v":2,"offset":9999,"spaceId":"ancien-space","sessionLabel":"ancien-label","customTitle":"ancien-titre"}' > "$v2_cache"
v2_out="$(
  source "$COMMON_SH"
  _mycelora_charger_fil "$v2_session" "$JETON_TRANSCRIPT"
)"
v2_cache_v="$(python3 -c "import json; print(json.load(open('$v2_cache')).get('v'))" 2>/dev/null || echo 'ERR')"
v2_expected="$(printf 'd23fb267-1234-4abc-8def-000000000001\ncowork-2026-09-01-dev-mycelora\n\nmk_sess_FIXTURE0123456789')"
if [ "$v2_out" = "$v2_expected" ] && [ "$v2_cache_v" = "3" ]; then
  echo "PASS cache-v2-existant-traite-comme-absent-reconstruit-v3"
else
  echo "FAIL cache-v2-existant-traite-comme-absent-reconstruit-v3 : out='$v2_out', cache_v='$v2_cache_v'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -f "$v2_cache"

# --- extraire_jeton (fonction pure) : test DIRECT, sur le code source REEL
# (extrait de mycelora-common.sh, pas une reimplementation), cas positifs et
# negatifs. C'est cette fonction que la contre-epreuve par mutation (regle
# 8bis, plus bas dans ce script) doit faire tomber en rouge. -----------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
EXTRAIRE_JETON_SRC="$(python3 -c "
with open('$COMMON_SH', encoding='utf-8') as f:
    texte = f.read()
debut = texte.index('_RE_JETON = re.compile(')
fin = texte.index('modifie = False', debut)
print(texte[debut:fin])
")"
EXTRAIRE_JETON_TEST_SCRIPT="$(mktemp /tmp/mycelora-test-extraire-jeton.XXXXXX)"
{
  echo 'import re'
  printf '%s\n' "$EXTRAIRE_JETON_SRC"
  cat <<'PYEOF'
cas = [
    ("[jeton-hook-session ne jamais l'afficher ni le recopier] mk_sess_ABC123", "mk_sess_ABC123", "ligne_seule"),
    ("Bonjour,\nvoici le brief.\n\n[jeton-hook-session x] mk_sess_XYZ_-9\n\nSuite du texte.", "mk_sess_XYZ_-9", "ligne_parmi_autre_texte"),
    ("[jeton-hook-session a] mk_sess_PREMIER\n[jeton-hook-session b] mk_sess_DERNIER", "mk_sess_DERNIER", "dernier_vu_gagne"),
    ("Bonjour, rien a voir ici, pas de jeton.", None, "pas_de_ligne"),
    ("[jeton-hook-session]mk_sess_NOSPACE", None, "ligne_mal_formee_pas_despace"),
    ("Le jeton est mk_sess_SANSBRACKET ici.", None, "mk_sess_sans_prefixe_bracket"),
    ("[jeton-hook-session x] mk_sess_TRAILING1234 et voici du texte en plus", None, "texte_parasite_apres_le_jeton_sur_la_meme_ligne"),
    (123, None, "non_str"),
    # F6 (revue adversariale 02/09) : \s+/\s*, en mode MULTILINE, traverse le
    # \n entre les deux lignes -- un jeton a cheval sur deux lignes etait
    # extrait a tort, alors que le contrat dit "sur une ligne dediee".
    ("[jeton-hook-session x]\nmk_sess_CROSSLINE", None, "jeton_a_cheval_sur_deux_lignes"),
]
erreurs = []
for texte, attendu, nom in cas:
    obtenu = extraire_jeton(texte)
    if obtenu != attendu:
        erreurs.append("%s: attendu=%r obtenu=%r" % (nom, attendu, obtenu))
print("FAIL:" + "; ".join(erreurs) if erreurs else "OK")
PYEOF
} > "$EXTRAIRE_JETON_TEST_SCRIPT"
extraire_jeton_verdict="$(python3 "$EXTRAIRE_JETON_TEST_SCRIPT" 2>&1)"
if [ "$extraire_jeton_verdict" = "OK" ]; then
  echo "PASS extraire-jeton-direct-cas-positifs-negatifs"
else
  echo "FAIL extraire-jeton-direct-cas-positifs-negatifs : $extraire_jeton_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

# --- extraire_fil (fonction pure, correctif du 02/09 soir) : la ligne
# « Fil : <id> ... » du brief d'ouverture rend l'identifiant DEFINITIF du
# fil (horodate par le serveur depuis le 26/08). Meme extraction de source
# reelle que extraire_jeton (la fonction vit dans la meme zone du fichier). --
TOTAL_TESTS=$((TOTAL_TESTS+1))
EXTRAIRE_FIL_TEST_SCRIPT="$(mktemp /tmp/mycelora-test-extraire-fil.XXXXXX)"
{
  echo 'import re'
  printf '%s\n' "$EXTRAIRE_JETON_SRC"
  cat <<'PYEOF'
cas = [
    ("Fil : cowork-2026-09-02-2147-mycelora (l'identifiant « cowork-2026-09-02-mycelora » a été horodaté par le serveur)", "cowork-2026-09-02-2147-mycelora", "ligne_reelle_avec_parenthese"),
    ("═══ MNEMOS IN ═══\n\nNous sommes le 02/09/2026.\nFil : resume-2026-09-02-1015-tamis\n\n[Profil] x", "resume-2026-09-02-1015-tamis", "ligne_parmi_le_brief"),
    ("Fil : cowork-a\nFil : cowork-b", "cowork-b", "dernier_vu_gagne"),
    ("Fil : cowork-2026-09-02-2147-mycelora", "cowork-2026-09-02-2147-mycelora", "ligne_seule_fin_de_texte"),
    ("Le fil : cowork-pas-en-tete-de-ligne", None, "pas_en_tete_de_ligne"),
    ("Fil :\ncowork-a-cheval", None, "identifiant_a_cheval_sur_deux_lignes"),
    ("Fil : «cowork-guillemets»", None, "caractere_interdit_colle"),
    ("Aucune ligne de fil ici.", None, "pas_de_ligne"),
    (None, None, "non_str"),
]
erreurs = []
for texte, attendu, nom in cas:
    obtenu = extraire_fil(texte)
    if obtenu != attendu:
        erreurs.append("%s: attendu=%r obtenu=%r" % (nom, attendu, obtenu))
print("FAIL:" + "; ".join(erreurs) if erreurs else "OK")
PYEOF
} > "$EXTRAIRE_FIL_TEST_SCRIPT"
extraire_fil_verdict="$(python3 "$EXTRAIRE_FIL_TEST_SCRIPT" 2>&1)"
rm -f "$EXTRAIRE_FIL_TEST_SCRIPT"
if [ "$extraire_fil_verdict" = "OK" ]; then
  echo "PASS extraire-fil-direct-cas-positifs-negatifs"
else
  echo "FAIL extraire-fil-direct-cas-positifs-negatifs : $extraire_fil_verdict"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

# --- sessionLabel = identifiant RENDU PAR LE SERVEUR (ligne « Fil : »), pas
# input.sessionId de l'appel ; et une ligne « Fil : » citee dans le resultat
# d'un AUTRE outil (sans jeton ni bandeau MNEMOS IN) est ignoree. -----------
TOTAL_TESTS=$((TOTAL_TESTS+1))
FIL_TRANSCRIPT="$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/transcript-session-start-fil-serveur.jsonl"
rm -f "/tmp/mycelora-hook-s-fil-serveur-0001.json"
fil_out="$(
  source "$COMMON_SH"
  _mycelora_charger_fil "s-fil-serveur-0001" "$FIL_TRANSCRIPT"
)"
fil_label="$(printf '%s\n' "$fil_out" | sed -n '2p')"
fil_token="$(printf '%s\n' "$fil_out" | sed -n '4p')"
rm -f "/tmp/mycelora-hook-s-fil-serveur-0001.json"
if [ "$fil_label" = "cowork-2026-09-02-2147-mycelora" ] && [ "$fil_token" = "mk_sess_FIXTUREFIL0001" ]; then
  echo "PASS session-label-rendu-par-le-serveur-prime-sur-l-appel"
else
  echo "FAIL session-label-rendu-par-le-serveur-prime-sur-l-appel : label=$fil_label token=$fil_token"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

# --- format du content d'un tool_result : liste de blocs {type:text} (deja
# couvert par le cache-v2 ci-dessus, transcript avec-jeton) ET chaine directe
# (transcript dedie) : extraire_jeton doit fonctionner sur les DEUX. ---------
TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "/tmp/mycelora-hook-s-reflexes-6-jeton-string-0001.json"
str_out="$(
  source "$COMMON_SH"
  _mycelora_charger_fil "s-reflexes-6-jeton-string-0001" "$JETON_TRANSCRIPT_STRING"
)"
str_token="$(printf '%s\n' "$str_out" | sed -n '4p')"
if [ "$str_token" = "mk_sess_FIXTURE0123456789" ]; then
  echo "PASS charger-fil-format-content-chaine-directe"
else
  echo "FAIL charger-fil-format-content-chaine-directe : obtenu='$str_token'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -f "/tmp/mycelora-hook-s-reflexes-6-jeton-string-0001.json"

# --- mycelora_resolve_hook_token : les trois priorites du contrat figé, plus
# le cas explicite du DoD (zip substitue ET jeton de session presents en
# meme temps -> le substitue gagne). -----------------------------------------
resolve_hook_token_test() {
  local initial="$1" session="$2" transcript="$3"
  (
    source "$COMMON_SH"
    MYCELORA_HOOK_TOKEN="$initial"
    mycelora_resolve_hook_token "$session" "$transcript"
    printf '%s' "$MYCELORA_HOOK_TOKEN"
  )
}

TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "/tmp/mycelora-hook-s-reflexes-6-prio1.json"
prio1="$(resolve_hook_token_test "mk_live_SUBSTITUTED_ZIP_TEST" "s-reflexes-6-prio1" "$JETON_TRANSCRIPT")"
if [ "$prio1" = "mk_live_SUBSTITUTED_ZIP_TEST" ] && [ ! -f "/tmp/mycelora-hook-s-reflexes-6-prio1.json" ]; then
  echo "PASS resolve-hook-token-priorite-1-zip-substitue-gagne"
else
  echo "FAIL resolve-hook-token-priorite-1-zip-substitue-gagne : obtenu='$prio1', cache_cree=$([ -f "/tmp/mycelora-hook-s-reflexes-6-prio1.json" ] && echo oui || echo non)"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "/tmp/mycelora-hook-s-reflexes-6-prio2.json"
prio2="$(resolve_hook_token_test "__MYCELORA_HOOK_KEY__" "s-reflexes-6-prio2" "$JETON_TRANSCRIPT")"
if [ "$prio2" = "mk_sess_FIXTURE0123456789" ]; then
  echo "PASS resolve-hook-token-priorite-2-cache-v3"
else
  echo "FAIL resolve-hook-token-priorite-2-cache-v3 : obtenu='$prio2'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

TOTAL_TESTS=$((TOTAL_TESTS+1))
rm -f "/tmp/mycelora-hook-s-reflexes-6-prio3.json"
prio3="$(resolve_hook_token_test "__MYCELORA_HOOK_KEY__" "s-reflexes-6-prio3" "$NO_SESSION_START_TRANSCRIPT")"
if [ -z "$prio3" ]; then
  echo "PASS resolve-hook-token-priorite-3-vide"
else
  echo "FAIL resolve-hook-token-priorite-3-vide : obtenu='$prio3'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

TOTAL_TESTS=$((TOTAL_TESTS+1))
zip_session="s-reflexes-6-zip-et-session"
zip_cache="/tmp/mycelora-hook-${zip_session}.json"
rm -f "$zip_cache"
printf '%s' '{"v":3,"offset":0,"spaceId":"","sessionLabel":"","customTitle":"","hookToken":"mk_sess_DEPUIS_CACHE_DIFFERENT"}' > "$zip_cache"
zip_et_session="$(resolve_hook_token_test "mk_live_SUBSTITUE_DEPUIS_ZIP" "$zip_session" "$JETON_TRANSCRIPT")"
if [ "$zip_et_session" = "mk_live_SUBSTITUE_DEPUIS_ZIP" ]; then
  echo "PASS resolve-hook-token-zip-et-session-le-substitue-gagne"
else
  echo "FAIL resolve-hook-token-zip-et-session-le-substitue-gagne : obtenu='$zip_et_session'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -f "$zip_cache"

# --- Offset : une ligne de transcript NON terminee par "\n" (ecriture en
# cours) ne doit jamais etre consommee a moitie ; completee, elle est extraite
# au passage suivant. Fixture construite par printf SANS retour final. ------
offset_session="s-reflexes-6-offset-partiel"
offset_cache="/tmp/mycelora-hook-${offset_session}.json"
offset_transcript="$(mktemp /tmp/mycelora-test-offset-transcript.XXXXXX)"
rm -f "$offset_cache"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_offset","name":"mnemos_session_start","input":{"sessionId":"sess-offset","spaceId":"space-offset"}}]}}\n' > "$offset_transcript"
printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_offset","content":[{"type":"text","text":"[jeton-hook-session x] mk_sess_OFFSETPARTIEL_0"}]}]}}' >> "$offset_transcript"
# PAS de "\n" final ici : simule une ligne en cours d'ecriture.

TOTAL_TESTS=$((TOTAL_TESTS+1))
offset_pass1_out="$(
  source "$COMMON_SH"
  _mycelora_charger_fil "$offset_session" "$offset_transcript"
)"
offset_pass1_token="$(printf '%s\n' "$offset_pass1_out" | sed -n '4p')"
if [ -z "$offset_pass1_token" ]; then
  echo "PASS offset-ligne-non-terminee-pas-consommee-au-premier-passage"
else
  echo "FAIL offset-ligne-non-terminee-pas-consommee-au-premier-passage : obtenu='$offset_pass1_token'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

printf '\n' >> "$offset_transcript"

TOTAL_TESTS=$((TOTAL_TESTS+1))
offset_pass2_out="$(
  source "$COMMON_SH"
  _mycelora_charger_fil "$offset_session" "$offset_transcript"
)"
offset_pass2_token="$(printf '%s\n' "$offset_pass2_out" | sed -n '4p')"
if [ "$offset_pass2_token" = "mk_sess_OFFSETPARTIEL_0" ]; then
  echo "PASS offset-ligne-completee-extraite-au-passage-suivant"
else
  echo "FAIL offset-ligne-completee-extraite-au-passage-suivant : obtenu='$offset_pass2_token'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -f "$offset_cache" "$offset_transcript"

# --- Chaque hook, cas sans-jeton : transcript sans mnemos_session_start ->
# exit 0, AUCUN appel curl, log "auth"/"sans-jeton"/duree 0 litterale. Unset
# LOCAL de CLAUDE_PLUGIN_OPTION_HOOK_KEY (sous-shell) : sinon la fausse valeur
# globale (priorite 1, tests pre-existants) masquerait le cas reel. ---------
assert_sans_jeton() {
  local test_name="$1" hook_name="$2" hook_script="$3" stdin_fixture="$4" placeholder="${5:-no}"
  local tmp call_log out_file rc
  tmp="$(mktemp -d)"
  call_log="$tmp/call.log"
  out_file="$tmp/stdout"

  (
    unset CLAUDE_PLUGIN_OPTION_HOOK_KEY
    export MYCELORA_TEST_CURL_LOG="$call_log"
    export PATH="$FAKE_BIN_DIR:$PATH"
    if [ "$placeholder" = "yes" ]; then
      reflexe_stdin "$stdin_fixture" | "$REPO_ROOT/plugins/mycelora/hooks/$hook_script" > "$out_file" 2>"$tmp/stderr"
    else
      cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/$stdin_fixture" | "$REPO_ROOT/plugins/mycelora/hooks/$hook_script" > "$out_file" 2>"$tmp/stderr"
    fi
  )
  rc=$?

  local actual_stdout last_log_line log_hook log_event log_dur log_status log_size
  actual_stdout="$(cat "$out_file")"
  last_log_line="$(tail -n 1 /tmp/mycelora-hook.log 2>/dev/null)"
  IFS=$'\t' read -r _ log_hook log_event log_dur log_status log_size <<< "$last_log_line"

  TOTAL_TESTS=$((TOTAL_TESTS+1))
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $test_name : exit code $rc (stderr: $(cat "$tmp/stderr" 2>/dev/null))"
    FAILED_TESTS=$((FAILED_TESTS+1))
  elif [ -n "$actual_stdout" ]; then
    echo "FAIL $test_name : stdout attendu vide, obtenu '$actual_stdout'"
    FAILED_TESTS=$((FAILED_TESTS+1))
  elif [ -f "$call_log" ]; then
    echo "FAIL $test_name : appel curl inattendu"
    FAILED_TESTS=$((FAILED_TESTS+1))
  elif [ "$log_hook" != "$hook_name" ] || [ "$log_event" != "auth" ] || [ "$log_dur" != "0" ] || [ "$log_status" != "sans-jeton" ] || [ "$log_size" != "0" ]; then
    echo "FAIL $test_name : ligne de log inattendue : '$last_log_line'"
    FAILED_TESTS=$((FAILED_TESTS+1))
  else
    echo "PASS $test_name"
  fi
  rm -rf "$tmp"
}

assert_sans_jeton "sans-jeton-userpromptsubmit" "userpromptsubmit" "mycelora-userpromptsubmit.sh" "stdin-ups-sans-jeton.json"
assert_sans_jeton "sans-jeton-stop" "stop" "mycelora-stop.sh" "stdin-stop-sans-jeton.json"
assert_sans_jeton "sans-jeton-pretooluse" "pretooluse" "mycelora-pretooluse.sh" "stdin-pre-sans-jeton.json" "yes"
assert_sans_jeton "sans-jeton-posttooluse" "posttooluse" "mycelora-posttooluse.sh" "stdin-post-sans-jeton.json" "yes"

# --- Jeton resolu via le cache v3 reel (pas la fausse valeur globale) : la
# resolution end-to-end via un VRAI hook fonctionne (pas seulement en direct
# sur la fonction). ----------------------------------------------------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
ups_jeton_tmp="$(mktemp -d)"
cat > "$ups_jeton_tmp/resp.json" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"FACE-A CANNED TEXT"}]},"id":1}
EOF
ups_jeton_out="$(
  unset CLAUDE_PLUGIN_OPTION_HOOK_KEY
  export MYCELORA_TEST_CURL_LOG="$ups_jeton_tmp/call.log"
  export MYCELORA_TEST_CURL_RESPONSE="$ups_jeton_tmp/resp.json"
  export MYCELORA_TEST_CURL_HTTP_CODE="200"
  export MYCELORA_TEST_CAPTURE_CFG="$ups_jeton_tmp/cfg.txt"
  export PATH="$FAKE_BIN_DIR:$PATH"
  cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-jeton.json" | "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"
)"
if [ "$ups_jeton_out" = "FACE-A CANNED TEXT" ] && [ -f "$ups_jeton_tmp/call.log" ]; then
  echo "PASS ups-jeton-resolu-via-cache-v3-appel-reussi"
else
  echo "FAIL ups-jeton-resolu-via-cache-v3-appel-reussi : obtenu='$ups_jeton_out', curl_appele=$([ -f "$ups_jeton_tmp/call.log" ] && echo oui || echo non)"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi

# --- F1 (revue adversariale 02/09) : le bearer REELLEMENT envoye sur cet
# appel (fichier -K, pas --data-binary) n'etait jamais verifie. -------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
ups_bearer_line="$(grep '^header = "Authorization:' "$ups_jeton_tmp/cfg.txt" 2>/dev/null)"
if [ "$ups_bearer_line" = 'header = "Authorization: Bearer mk_sess_FIXTURE0123456789"' ]; then
  echo "PASS ups-bearer-reellement-envoye-cache-v3"
else
  echo "FAIL ups-bearer-reellement-envoye-cache-v3 : cfg='$ups_bearer_line'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$ups_jeton_tmp"

# --- F1/F2 (revue adversariale 02/09) : Stop, meme verification du bearer
# reellement envoye via le cache v3, sur le VRAI script (mycelora-stop.sh),
# avec la fixture stdin-stop-jeton.json (creee des l'origine mais jusqu'ici
# jamais utilisee par aucun test -- F2, trou comble en meme temps que F1).
# Le transcript associe contient un vrai message user en tete
# ("peux-tu demarrer la session mnemos...") et l'assistant final
# correspondant a last_assistant_message : le hook trouve un echange non
# vide et appelle reellement mnemos_log_exchange. -----------------------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
stop_bearer_tmp="$(mktemp -d)"
cat > "$stop_bearer_tmp/resp.json" <<'EOF'
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"{\"success\": true, \"sessionId\": \"whatever\"}"}]},"id":1}
EOF
stop_bearer_out="$(
  unset CLAUDE_PLUGIN_OPTION_HOOK_KEY
  export MYCELORA_TEST_CURL_LOG="$stop_bearer_tmp/call.log"
  export MYCELORA_TEST_CURL_RESPONSE="$stop_bearer_tmp/resp.json"
  export MYCELORA_TEST_CURL_HTTP_CODE="200"
  export MYCELORA_TEST_CAPTURE_CFG="$stop_bearer_tmp/cfg.txt"
  export PATH="$FAKE_BIN_DIR:$PATH"
  cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-jeton.json" | "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"
)"
stop_bearer_line="$(grep '^header = "Authorization:' "$stop_bearer_tmp/cfg.txt" 2>/dev/null)"
if [ -z "$stop_bearer_out" ] && [ -f "$stop_bearer_tmp/call.log" ] && [ "$stop_bearer_line" = 'header = "Authorization: Bearer mk_sess_FIXTURE0123456789"' ]; then
  echo "PASS stop-bearer-reellement-envoye-cache-v3"
else
  echo "FAIL stop-bearer-reellement-envoye-cache-v3 : stdout='$stop_bearer_out', cfg='$stop_bearer_line', curl_appele=$([ -f "$stop_bearer_tmp/call.log" ] && echo oui || echo non)"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$stop_bearer_tmp"

# --- UserPromptSubmit : 401 type (jeton_session_expire) -> ligne de relance
# EXACTE (comparaison stricte) ; 401 GENERIQUE (sans ce code) -> stdout VIDE,
# distinct du cas precedent. -------------------------------------------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
ups401_tmp="$(mktemp -d)"
cat > "$ups401_tmp/resp-401-typed.json" <<'EOF'
{"jsonrpc":"2.0","error":{"code":-32001,"message":"Unauthorized","data":{"code":"jeton_session_expire"}},"id":null}
EOF
ups401_out="$(
  export MYCELORA_TEST_CURL_LOG="$ups401_tmp/call.log"
  export MYCELORA_TEST_CURL_RESPONSE="$ups401_tmp/resp-401-typed.json"
  export MYCELORA_TEST_CURL_HTTP_CODE="401"
  export PATH="$FAKE_BIN_DIR:$PATH"
  cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-normal.json" | "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"
)"
ups401_expected="Mycelora : jeton de session expiré, relancez l'ouverture du fil (mnemos_session_start) pour rétablir la mémoire."
if [ "$ups401_out" = "$ups401_expected" ]; then
  echo "PASS ups-401-type-ligne-de-relance-exacte"
else
  echo "FAIL ups-401-type-ligne-de-relance-exacte : obtenu='$ups401_out'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$ups401_tmp"

TOTAL_TESTS=$((TOTAL_TESTS+1))
ups401g_tmp="$(mktemp -d)"
cat > "$ups401g_tmp/resp-401-generic.json" <<'EOF'
{"jsonrpc":"2.0","error":{"code":-32001,"message":"Unauthorized"},"id":null}
EOF
ups401g_out="$(
  export MYCELORA_TEST_CURL_LOG="$ups401g_tmp/call.log"
  export MYCELORA_TEST_CURL_RESPONSE="$ups401g_tmp/resp-401-generic.json"
  export MYCELORA_TEST_CURL_HTTP_CODE="401"
  export PATH="$FAKE_BIN_DIR:$PATH"
  cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-ups-normal.json" | "$REPO_ROOT/plugins/mycelora/hooks/mycelora-userpromptsubmit.sh"
)"
if [ -z "$ups401g_out" ]; then
  echo "PASS ups-401-generique-stdout-vide"
else
  echo "FAIL ups-401-generique-stdout-vide : obtenu='$ups401g_out'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$ups401g_tmp"

# --- Stop : 401 type -> TOUJOURS stdout vide (contrat "aucune sortie stdout,
# jamais" inchange), log dedie auth/jeton-expire. ----------------------------
TOTAL_TESTS=$((TOTAL_TESTS+1))
stop401_tmp="$(mktemp -d)"
cat > "$stop401_tmp/resp-401-typed.json" <<'EOF'
{"jsonrpc":"2.0","error":{"code":-32001,"message":"Unauthorized","data":{"code":"jeton_session_expire"}},"id":null}
EOF
stop401_out="$(
  export MYCELORA_TEST_CURL_LOG="$stop401_tmp/call.log"
  export MYCELORA_TEST_CURL_RESPONSE="$stop401_tmp/resp-401-typed.json"
  export MYCELORA_TEST_CURL_HTTP_CODE="401"
  export PATH="$FAKE_BIN_DIR:$PATH"
  cat "$REPO_ROOT/plugins/mycelora/hooks/tests/fixtures/stdin-stop-normal.json" | "$REPO_ROOT/plugins/mycelora/hooks/mycelora-stop.sh"
)"
stop401_last_log="$(tail -n 1 /tmp/mycelora-hook.log 2>/dev/null)"
IFS=$'\t' read -r _ stop401_hook stop401_event _ stop401_status _ <<< "$stop401_last_log"
if [ -z "$stop401_out" ] && [ "$stop401_hook" = "stop" ] && [ "$stop401_event" = "auth" ] && [ "$stop401_status" = "jeton-expire" ]; then
  echo "PASS stop-401-type-stdout-vide-log-jeton-expire"
else
  echo "FAIL stop-401-type-stdout-vide-log-jeton-expire : stdout='$stop401_out', log='$stop401_last_log'"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$stop401_tmp"
export MYCELORA_TEST_CURL_HTTP_CODE="200"

# --- PreToolUse : jeton resolu (cache v3 reel) mais 401/jeton_session_expire
# sur le LOOKUP (mnemos_impact_lookup) -> refuse quand meme (deny inchange,
# rapport vide assumé -- brief section 5, NE PAS toucher la logique de refus
# elle-meme). -----------------------------------------------------------------
rm -f "/tmp/mycelora-impact-s-reflexes-6-jeton-0001" "/tmp/mycelora-reflexes-s-reflexes-6-jeton-0001.jsonl"
TOTAL_TESTS=$((TOTAL_TESTS+1))
pre401_tmp="$(mktemp -d)"
cat > "$pre401_tmp/resp-401-typed.json" <<'EOF'
{"jsonrpc":"2.0","error":{"code":-32001,"message":"Unauthorized","data":{"code":"jeton_session_expire"}},"id":null}
EOF
pre401_out="$(
  unset CLAUDE_PLUGIN_OPTION_HOOK_KEY
  export MYCELORA_TEST_CURL_LOG="$pre401_tmp/call.log"
  export MYCELORA_TEST_CURL_RESPONSE="$pre401_tmp/resp-401-typed.json"
  export MYCELORA_TEST_CURL_HTTP_CODE="401"
  export PATH="$FAKE_BIN_DIR:$PATH"
  reflexe_stdin "stdin-pre-jeton-refus-quand-meme.json" | "$PRETOOLUSE"
)"
printf '%s' "$pre401_out" > "$pre401_tmp/stdout.json"
pre401_verdict="$(python3 - "$pre401_tmp/stdout.json" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
    ok = (
        d["hookSpecificOutput"]["permissionDecision"] == "deny"
        and "table_jeton_expire" in d["hookSpecificOutput"]["permissionDecisionReason"]
    )
    print("OK" if ok else "FAIL:%r" % d)
except Exception as e:
    print("FAIL:%s" % e)
PYEOF
)"
if [ "$pre401_verdict" = "OK" ]; then
  echo "PASS pretooluse-401-jeton-expire-sur-lookup-refuse-quand-meme"
else
  echo "FAIL pretooluse-401-jeton-expire-sur-lookup-refuse-quand-meme : $pre401_verdict (stdout='$pre401_out')"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$pre401_tmp"
rm -f "/tmp/mycelora-impact-s-reflexes-6-jeton-0001" "/tmp/mycelora-reflexes-s-reflexes-6-jeton-0001.jsonl"
export MYCELORA_TEST_CURL_HTTP_CODE="200"

# --- PostToolUse : jeton resolu (cache v3 reel) mais 401/jeton_session_expire
# sur le LOOKUP -> log dedie auth/jeton-expire, best-effort, SANS toucher au
# jalon qui se construit normalement ensuite (contrat "se taisent" du DoD,
# comme Stop : pas de sortie stdout supplementaire). --------------------------
rm -f "/tmp/mycelora-impact-s-reflexes-6-jeton-0001" "/tmp/mycelora-reflexes-s-reflexes-6-jeton-0001.jsonl"
TOTAL_TESTS=$((TOTAL_TESTS+1))
post401_tmp="$(mktemp -d)"
cat > "$post401_tmp/resp-401-typed.json" <<'EOF'
{"jsonrpc":"2.0","error":{"code":-32001,"message":"Unauthorized","data":{"code":"jeton_session_expire"}},"id":null}
EOF
# Le log auth/jeton-expire n'est pas forcement la DERNIERE ligne (le jalon se
# construit normalement ensuite et journalise a son tour) : on capture les
# lignes AJOUTEES par cet appel, pas seulement la derniere.
post401_lines_avant="$(wc -l < /tmp/mycelora-hook.log 2>/dev/null || echo 0)"
post401_out="$(
  unset CLAUDE_PLUGIN_OPTION_HOOK_KEY
  export MYCELORA_TEST_CURL_LOG="$post401_tmp/call.log"
  export MYCELORA_TEST_CURL_RESPONSE="$post401_tmp/resp-401-typed.json"
  export MYCELORA_TEST_CURL_HTTP_CODE="401"
  export PATH="$FAKE_BIN_DIR:$PATH"
  reflexe_stdin "stdin-post-jeton-401.json" | "$POSTTOOLUSE"
)"
post401_nouvelles_lignes="$(tail -n "+$((post401_lines_avant+1))" /tmp/mycelora-hook.log 2>/dev/null)"
post401_auth_trouve="0"
while IFS=$'\t' read -r _ p_hook p_event _ p_status p_size; do
  if [ "$p_hook" = "posttooluse" ] && [ "$p_event" = "auth" ] && [ "$p_status" = "jeton-expire" ] && [ "$p_size" = "0" ]; then
    post401_auth_trouve="1"
  fi
done <<< "$post401_nouvelles_lignes"
if [ "$post401_auth_trouve" = "1" ]; then
  echo "PASS posttooluse-401-jeton-expire-sur-lookup-log-dedie"
else
  echo "FAIL posttooluse-401-jeton-expire-sur-lookup-log-dedie : nouvelles lignes='$post401_nouvelles_lignes' (stdout='$post401_out')"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$post401_tmp"
rm -f "/tmp/mycelora-impact-s-reflexes-6-jeton-0001" "/tmp/mycelora-reflexes-s-reflexes-6-jeton-0001.jsonl"
export MYCELORA_TEST_CURL_HTTP_CODE="200"

# --- F1 (revue adversariale 02/09) : PreToolUse, le bearer REELLEMENT envoye
# sur l'appel reseau du reflexe d'impact (mycelora_reflexe_lookup_serveur ->
# mycelora_curl_post, fichier -K) n'etait jamais verifie -- seul le CORPS
# JSON-RPC l'etait. Meme fixture que le refus 401 ci-dessus
# (stdin-pre-jeton-refus-quand-meme.json), mais reponse 200 : l'appel reseau
# reussit, ce qui est le chemin nominal ou le bearer compte vraiment. --------
rm -f "/tmp/mycelora-impact-s-reflexes-6-jeton-0001" "/tmp/mycelora-reflexes-s-reflexes-6-jeton-0001.jsonl"
TOTAL_TESTS=$((TOTAL_TESTS+1))
pre_bearer_tmp="$(mktemp -d)"
pre_bearer_out="$(
  unset CLAUDE_PLUGIN_OPTION_HOOK_KEY
  export MYCELORA_TEST_CURL_LOG="$pre_bearer_tmp/call.log"
  export MYCELORA_TEST_CURL_RESPONSE="$REFLEXE_IMPACT_RESPONSE"
  export MYCELORA_TEST_CURL_HTTP_CODE="200"
  export MYCELORA_TEST_CAPTURE_CFG="$pre_bearer_tmp/cfg.txt"
  export PATH="$FAKE_BIN_DIR:$PATH"
  reflexe_stdin "stdin-pre-jeton-refus-quand-meme.json" | "$PRETOOLUSE"
)"
pre_bearer_line="$(grep '^header = "Authorization:' "$pre_bearer_tmp/cfg.txt" 2>/dev/null)"
if [ -f "$pre_bearer_tmp/call.log" ] && [ "$pre_bearer_line" = 'header = "Authorization: Bearer mk_sess_FIXTURE0123456789"' ]; then
  echo "PASS pretooluse-bearer-reellement-envoye-cache-v3"
else
  echo "FAIL pretooluse-bearer-reellement-envoye-cache-v3 : cfg='$pre_bearer_line', curl_appele=$([ -f "$pre_bearer_tmp/call.log" ] && echo oui || echo non) (stdout='$pre_bearer_out')"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$pre_bearer_tmp"
rm -f "/tmp/mycelora-impact-s-reflexes-6-jeton-0001" "/tmp/mycelora-reflexes-s-reflexes-6-jeton-0001.jsonl"
export MYCELORA_TEST_CURL_HTTP_CODE="200"

# --- F1 (revue adversariale 02/09) : PostToolUse, meme verification du
# bearer reellement envoye sur l'appel reseau du jalon (le meme point d'appel
# mycelora_reflexe_lookup_serveur que PreToolUse). Meme fixture que le test
# 401 ci-dessus (stdin-post-jeton-401.json), reponse 200 cette fois. --------
rm -f "/tmp/mycelora-impact-s-reflexes-6-jeton-0001" "/tmp/mycelora-reflexes-s-reflexes-6-jeton-0001.jsonl"
TOTAL_TESTS=$((TOTAL_TESTS+1))
post_bearer_tmp="$(mktemp -d)"
post_bearer_out="$(
  unset CLAUDE_PLUGIN_OPTION_HOOK_KEY
  export MYCELORA_TEST_CURL_LOG="$post_bearer_tmp/call.log"
  export MYCELORA_TEST_CURL_RESPONSE="$REFLEXE_IMPACT_RESPONSE"
  export MYCELORA_TEST_CURL_HTTP_CODE="200"
  export MYCELORA_TEST_CAPTURE_CFG="$post_bearer_tmp/cfg.txt"
  export PATH="$FAKE_BIN_DIR:$PATH"
  reflexe_stdin "stdin-post-jeton-401.json" | "$POSTTOOLUSE"
)"
post_bearer_line="$(grep '^header = "Authorization:' "$post_bearer_tmp/cfg.txt" 2>/dev/null)"
if [ -f "$post_bearer_tmp/call.log" ] && [ "$post_bearer_line" = 'header = "Authorization: Bearer mk_sess_FIXTURE0123456789"' ]; then
  echo "PASS posttooluse-bearer-reellement-envoye-cache-v3"
else
  echo "FAIL posttooluse-bearer-reellement-envoye-cache-v3 : cfg='$post_bearer_line', curl_appele=$([ -f "$post_bearer_tmp/call.log" ] && echo oui || echo non) (stdout='$post_bearer_out')"
  FAILED_TESTS=$((FAILED_TESTS+1))
fi
rm -rf "$post_bearer_tmp"
rm -f "/tmp/mycelora-impact-s-reflexes-6-jeton-0001" "/tmp/mycelora-reflexes-s-reflexes-6-jeton-0001.jsonl"
export MYCELORA_TEST_CURL_HTTP_CODE="200"

# Nettoyage des caches S-REFLEXES-6 crees par cette section.
rm -f /tmp/mycelora-hook-s-reflexes-6-*.json

# Nettoyage final des artefacts de test (marqueurs, journaux, reponse canned).
rm -f /tmp/mycelora-reflexes-*.jsonl /tmp/mycelora-impact-* "$REFLEXE_IMPACT_RESPONSE" "$REPO_ROOT/.carte-perimee" "$REPO_ROOT/.mycelora-reflexes-off"
unset MYCELORA_TEST_CAPTURE_BODY
export MYCELORA_TEST_CURL_HTTP_CODE="200"

# Compter les tests passés a partir des compteurs reels (pas un grep sur le
# code source du script).
PASSED_TESTS=$((TOTAL_TESTS-FAILED_TESTS))
echo "$PASSED_TESTS/$TOTAL_TESTS tests passes"

if [ "$FAILED_TESTS" -ne 0 ]; then
  exit 1
fi

exit 0
