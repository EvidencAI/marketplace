#!/usr/bin/env bash

set -uo pipefail

# Calculer le repertoire racine du repo
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# Nettoyage initial
rm -f /tmp/mnemos-hook.log /tmp/mnemos-hook-*.json

# Creer un dossier temporaire pour le faux curl
FAKE_BIN_DIR="$(mktemp -d)"
FAKE_CURL_SCRIPT="$FAKE_BIN_DIR/curl"
cat > "$FAKE_CURL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Faux curl pour les tests unitaires. Ne fait aucun appel reseau.
CALL_LOG="${MNEMOS_TEST_CURL_LOG:?MNEMOS_TEST_CURL_LOG non defini}"
RESP_BODY_FILE="${MNEMOS_TEST_CURL_RESPONSE:-}"
HTTP_CODE="${MNEMOS_TEST_CURL_HTTP_CODE:-200}"
SHOULD_FAIL="${MNEMOS_TEST_CURL_FAIL:-0}"

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

if [ -n "$BODY_SRC" ] && [ -n "${MNEMOS_TEST_CAPTURE_BODY:-}" ]; then
  case "$BODY_SRC" in
    @*) cp "${BODY_SRC#@}" "$MNEMOS_TEST_CAPTURE_BODY" 2>/dev/null || true ;;
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
  export MNEMOS_TEST_CURL_LOG="$call_log"
  export MNEMOS_TEST_CURL_RESPONSE="$response_file"
  export MNEMOS_TEST_CURL_HTTP_CODE="200"
  export MNEMOS_TEST_CAPTURE_BODY="$capture_body"

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
      mnemos-stop-*)
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
      
      if [ "$test_name" = "mnemos-userpromptsubmit-2" ]; then
        # Pour ce test, vérifier le prompt exact
        if [ "$query" != "peux-tu m'expliquer comment fonctionne le cache de spaceId dans les hooks ?" ]; then
          echo "FAIL $test_name : expected query 'peux-tu m'expliquer comment fonctionne le cache de spaceId dans les hooks ?', got '$query'"
          return 1
        fi
      elif [ "$test_name" = "mnemos-userpromptsubmit-9" ]; then
        # Pour ce test, vérifier le prompt
        if [ "$query" != "ceci est un prompt de test suffisamment long pour passer les filtres" ]; then
          echo "FAIL $test_name : expected query 'ceci est un prompt de test suffisamment long pour passer les filtres', got '$query'"
          return 1
        fi
      fi

      # Vérifier le spaceId pour mnemos_recall
      local space_id
      space_id="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('arguments', {}).get('spaceId', ''))" < "$capture_body")"
      
      if [ "$test_name" = "mnemos-userpromptsubmit-2" ]; then
        # Pour ce test, vérifier le spaceId
        if [ "$space_id" != "Développement Mnemos" ]; then
          echo "FAIL $test_name : expected spaceId 'Développement Mnemos', got '$space_id'"
          return 1
        fi
      elif [ "$test_name" = "mnemos-userpromptsubmit-9" ]; then
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
      
      if [ "$test_name" = "mnemos-stop-10" ]; then
        # Pour ce test, vérifier le userMessage exact
        if [ "$user_message" != "et maintenant, peux-tu lister les fichiers du dossier hooks ?" ]; then
          echo "FAIL $test_name : expected userMessage 'et maintenant, peux-tu lister les fichiers du dossier hooks ?', got '$user_message'"
          return 1
        fi
      elif [ "$test_name" = "mnemos-stop-14" ]; then
        # Pour ce test, vérifier le userMessage
        if [ "$user_message" != "ok" ]; then
          echo "FAIL $test_name : expected userMessage 'ok', got '$user_message'"
          return 1
        fi
      elif [ "$test_name" = "mnemos-stop-13" ]; then
        if [ "$user_message" != "lance la commande de build stp" ]; then
          echo "FAIL $test_name : expected userMessage 'lance la commande de build stp', got '$user_message'"
          return 1
        fi
      elif [ "$test_name" = "mnemos-stop-tool-heavy" ] || [ "$test_name" = "mnemos-stop-tool-heavy-no-promptid" ]; then
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
      
      if [ "$test_name" = "mnemos-stop-10" ]; then
        # Pour ce test, vérifier l'assistantResponse exact
        if [ "$assistant_response" != "Voici la liste des fichiers du dossier hooks : hooks.json, mnemos-userpromptsubmit.sh, mnemos-stop.sh." ]; then
          echo "FAIL $test_name : expected assistantResponse 'Voici la liste des fichiers du dossier hooks : hooks.json, mnemos-userpromptsubmit.sh, mnemos-stop.sh.', got '$assistant_response'"
          return 1
        fi
      fi

      local session_id
      session_id="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('arguments', {}).get('sessionId', ''))" < "$capture_body")"
      
      if [ "$test_name" = "mnemos-stop-10" ]; then
        # Pour ce test, vérifier le sessionId
        if [ "$session_id" != "726ec160-e1f5-5bd0-b3e7-3de9785ea2be" ]; then
          echo "FAIL $test_name : expected sessionId '726ec160-e1f5-5bd0-b3e7-3de9785ea2be', got '$session_id'"
          return 1
        fi
      fi

      local user_id
      user_id="$(python3 -c "import json, sys; data=json.loads(sys.stdin.read()); print(data.get('params', {}).get('arguments', {}).get('userId', ''))" < "$capture_body")"
      
      if [ "$test_name" = "mnemos-stop-10" ]; then
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

# Vérifier que __MNEMOS_HOOK_KEY__ est présent dans les deux scripts
TOTAL_TESTS=$((TOTAL_TESTS+1))
if ! grep -q "__MNEMOS_HOOK_KEY__" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"; then
  echo "FAIL placeholder-15 : __MNEMOS_HOOK_KEY__ not found in mnemos-userpromptsubmit.sh"
  FAILED_TESTS=$((FAILED_TESTS+1))
elif ! grep -q "__MNEMOS_HOOK_KEY__" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-stop.sh"; then
  echo "FAIL placeholder-15 : __MNEMOS_HOOK_KEY__ not found in mnemos-stop.sh"
  FAILED_TESTS=$((FAILED_TESTS+1))
else
  echo "PASS placeholder-15"
fi

# Exécuter les tests (chaque appel incremente TOTAL_TESTS et, en cas
# d'echec de assert (return 1), incremente FAILED_TESTS sans interrompre la
# suite : set -e est desactive volontairement pour ce script).
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-userpromptsubmit-1" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-ups-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"' \
  0 \
  "FACE-A CANNED TEXT" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-userpromptsubmit-2" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-ups-valid-long.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"' \
  0 \
  "FACE-A CANNED TEXT" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-userpromptsubmit-3" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-ups-short.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-userpromptsubmit-4" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-ups-uploaded-files.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-userpromptsubmit-5" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-ups-system-reminder.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-userpromptsubmit-6" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-ups-continued.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-userpromptsubmit-7" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-ups-system-notification.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-userpromptsubmit-8" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-ups-task-notification.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

# Test synthétique pour mnemos-userpromptsubmit-9
temp_synthetic_stdin="$(mktemp)"
cat > "$temp_synthetic_stdin" <<EOF
{
  "session_id": "synthetic-no-session-start-0001",
  "transcript_path": "plugins/mnemos/hooks/tests/fixtures/transcript-no-session-start.jsonl",
  "cwd": "/home/claude",
  "prompt_id": "daa83436-ac05-41b8-890b-2e2769ad9ce5",
  "permission_mode": "default",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "ceci est un prompt de test suffisamment long pour passer les filtres"
}
EOF

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-userpromptsubmit-9" \
  "cat '$temp_synthetic_stdin' | PATH='$FAKE_BIN_DIR:$PATH' '$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh'" \
  0 \
  "FACE-A CANNED TEXT" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

# Nettoyer le fichier temporaire
rm -f "$temp_synthetic_stdin"

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-stop-10" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-stop-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-stop.sh"' \
  0 \
  "" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-stop-11" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-stop-task-notification.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-stop.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-stop-12" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-stop-system-notification.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-stop.sh"' \
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
assert "mnemos-stop-13" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-stop-missing-user.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-stop.sh"' \
  0 \
  "" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-stop-14" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-stop-short-user.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-stop.sh"' \
  0 \
  "" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

# Non-regression : transcript se terminant par un tool_result (cas reel
# majoritaire des tours Cowork qui utilisent des outils). Avec l'ancienne
# logique de find_last_user (arret sur la seule derniere entree user), ces
# deux cas echouaient en MISSING. promptId present dans le stdin : doit
# retrouver le vrai message user via le critere (a).
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-stop-tool-heavy" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-stop-tool-heavy.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-stop.sh"' \
  0 \
  "" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

# Meme transcript mais SANS prompt_id dans le stdin : doit retrouver le
# meme message user via le repli (b), en remontant l'historique.
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-stop-tool-heavy-no-promptid" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-stop-tool-heavy-no-promptid.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-stop.sh"' \
  0 \
  "" \
  "yes" || FAILED_TESTS=$((FAILED_TESTS+1))

# Filtre "Rappel interne :" (wakeups send_later, ne portent pas le prefixe
# "[SYSTEM NOTIFICATION - NOT USER INPUT]" au niveau des hooks).
TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-userpromptsubmit-rappel-interne" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-ups-rappel-interne.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

TOTAL_TESTS=$((TOTAL_TESTS+1))
assert "mnemos-stop-rappel-interne" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-stop-rappel-interne.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-stop.sh"' \
  0 \
  "" \
  "no" || FAILED_TESTS=$((FAILED_TESTS+1))

# Cas synthetique : transcript sans AUCUNE entree type=user a content
# string (uniquement une entree tool_result). C'est le seul vrai test du
# chemin retry-puis-abandon (MISSING), plus aucune fixture fournie ne le
# couvre depuis le fix du nouvel algorithme find_last_user (voir
# commentaire sur mnemos-stop-13 plus haut).
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
assert "mnemos-stop-truly-missing-synthetic" \
  "cat '$temp_synthetic_stop_stdin' | PATH='$FAKE_BIN_DIR:$PATH' '$REPO_ROOT/plugins/mnemos/hooks/mnemos-stop.sh'" \
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
assert "mnemos-userpromptsubmit-tool-error" \
  'cat "$REPO_ROOT/plugins/mnemos/hooks/tests/fixtures/stdin-ups-normal.json" | PATH="$FAKE_BIN_DIR:$PATH" "$REPO_ROOT/plugins/mnemos/hooks/mnemos-userpromptsubmit.sh"' \
  0 \
  "" \
  "yes" \
  "$tool_error_response" || FAILED_TESTS=$((FAILED_TESTS+1))

rm -f "$tool_error_response"

# Compter les tests passés a partir des compteurs reels (pas un grep sur le
# code source du script).
PASSED_TESTS=$((TOTAL_TESTS-FAILED_TESTS))
echo "$PASSED_TESTS/$TOTAL_TESTS tests passes"

if [ "$FAILED_TESTS" -ne 0 ]; then
  exit 1
fi

exit 0
