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
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    -o) i=$((i+1)); OUT_FILE="${args[$i]}" ;;
    --data-binary) i=$((i+1)); BODY_SRC="${args[$i]}" ;;
  esac
  i=$((i+1))
done

if [ -n "$BODY_SRC" ] && [ -n "${MYCELORA_TEST_CAPTURE_BODY:-}" ]; then
  case "$BODY_SRC" in
    @*) cp "${BODY_SRC#@}" "$MYCELORA_TEST_CAPTURE_BODY" 2>/dev/null || true ;;
  esac
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
# Restaure le faux curl "normal" pour la suite des tests.
cat > "$FAKE_BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
CALL_LOG="${MYCELORA_TEST_CURL_LOG:?MYCELORA_TEST_CURL_LOG non defini}"
RESP_BODY_FILE="${MYCELORA_TEST_CURL_RESPONSE:-}"
HTTP_CODE="${MYCELORA_TEST_CURL_HTTP_CODE:-200}"
SHOULD_FAIL="${MYCELORA_TEST_CURL_FAIL:-0}"
echo "CALLED" >> "$CALL_LOG"
OUT_FILE=""
BODY_SRC=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    -o) i=$((i+1)); OUT_FILE="${args[$i]}" ;;
    --data-binary) i=$((i+1)); BODY_SRC="${args[$i]}" ;;
  esac
  i=$((i+1))
done
if [ -n "$BODY_SRC" ] && [ -n "${MYCELORA_TEST_CAPTURE_BODY:-}" ]; then
  case "$BODY_SRC" in
    @*) cp "${BODY_SRC#@}" "$MYCELORA_TEST_CAPTURE_BODY" 2>/dev/null || true ;;
  esac
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
