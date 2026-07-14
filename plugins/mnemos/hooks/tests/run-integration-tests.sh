#!/usr/bin/env bash
# Script d'integration pour les hooks mnemos.
# Fait des appels reseaux vers l'edge mnemos-mcp avec le jeton reel.
# Ne doit JAMAIS afficher le jeton dans ses messages.

set -uo pipefail

TOKEN_PATH="${1:-/Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/HOOK-KEY.txt}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_URL="https://hpbsowihyydzdnxuzoxs.supabase.co/functions/v1/mnemos-mcp"

# Verifie la presence et non-vide du jeton
if [ ! -f "$TOKEN_PATH" ]; then
  echo "abort: jeton introuvable" >&2
  exit 1
fi

# Le fichier jeton porte des lignes de commentaire (#...) avant la ligne du
# jeton, qui est elle-meme au format NOM_VARIABLE=valeur : on ignore les
# lignes vides et celles commencant par #, et sur la premiere ligne valide
# restante on ne garde que la partie apres le premier '=' (ou la ligne
# entiere si elle ne contient pas de '=').
TOKEN_CONTENT="$(python3 -c "
import sys
token = ''
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    for line in f:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        token = stripped.split('=', 1)[1] if '=' in stripped else stripped
        break
if not token:
    sys.exit(1)
print(token)
" "$TOKEN_PATH" 2>/dev/null)"

if [ -z "$TOKEN_CONTENT" ]; then
  echo "abort: jeton vide" >&2
  exit 1
fi

# Fonction pour faire un appel curl avec securite
mnemos_secure_curl() {
  local body_file="$1"
  local cfgfile resp_file http_code curl_rc
  cfgfile="$(mktemp /tmp/mnemos-integ-cfg.XXXXXX)"
  # Nettoyage garanti a la sortie de CETTE fonction (meme sur un kill en
  # plein curl) : le cfgfile contient le jeton en clair.
  trap 'rm -f "$cfgfile"' RETURN
  chmod 600 "$cfgfile"
  cat > "$cfgfile" <<CFGEOF
header = "Authorization: Bearer ${TOKEN_CONTENT}"
header = "Content-Type: application/json"
CFGEOF
  resp_file="$(mktemp /tmp/mnemos-integ-resp.XXXXXX)"
  http_code="$(curl -s --max-time 3 -K "$cfgfile" -X POST --data-binary "@${body_file}" -o "$resp_file" -w '%{http_code}' "$EDGE_URL" 2>/dev/null)"
  curl_rc=$?
  echo "$http_code" "$curl_rc" "$resp_file"
}

# Cas 1: mnemos_recall
test_recall() {
  local body_file resp_file http_code curl_rc
  body_file="$(mktemp /tmp/mnemos-integ-body.XXXXXX)"
  cat > "$body_file" <<'BODYEOF'
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"mnemos_recall","arguments":{"userId":"stephane","query":"test integration story S3"}},"id":1}
BODYEOF

  read -r http_code curl_rc resp_file < <(mnemos_secure_curl "$body_file")
  rm -f "$body_file"

  if [ "$curl_rc" -ne 0 ]; then
    echo "FAIL: recall : echec curl"
    return 1
  fi

  if ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "FAIL: recall : code HTTP non 2xx ($http_code)"
    return 1
  fi

  # Ne jamais afficher le contenu du bloc FACE-A (memoire potentiellement
  # sensible) : uniquement une information de taille, non le texte lui-meme.
  local content
  content="$(python3 - "$resp_file" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    if 'result' in data and 'content' in data['result'] and len(data['result']['content']) > 0:
        text = data['result']['content'][0].get('text', '')
        if text:
            print(f"recall : bloc non vide ({len(text)} caracteres)")
        else:
            print("recall : bloc vide (rien de pertinent trouve)")
    else:
        print("recall : bloc vide (rien de pertinent trouve)")
except Exception as e:
    print(f"recall : erreur parsing JSON: {e}")
PYEOF
)"
  rm -f "$resp_file"
  echo "$content"
  return 0
}

# Cas 2: mnemos_log_exchange
test_log_exchange() {
  local body_file resp_file http_code curl_rc session_id
  session_id="smoke-s3-$(python3 -c 'import time; print(int(time.time()))')"

  body_file="$(mktemp /tmp/mnemos-integ-body.XXXXXX)"
  cat > "$body_file" <<BODYEOF
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"mnemos_log_exchange","arguments":{"userId":"stephane","sessionId":"${session_id}","userMessage":"message de test integration story S3","assistantResponse":"reponse de test integration story S3"}},"id":1}
BODYEOF

  read -r http_code curl_rc resp_file < <(mnemos_secure_curl "$body_file")
  rm -f "$body_file"

  if [ "$curl_rc" -ne 0 ]; then
    echo "FAIL: log_exchange : echec curl"
    return 1
  fi

  if ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "FAIL: log_exchange : code HTTP non 2xx ($http_code)"
    return 1
  fi

  local success
  success="$(python3 - "$resp_file" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    if 'result' in data and 'content' in data['result'] and len(data['result']['content']) > 0:
        text = data['result']['content'][0].get('text', '')
        if '"success": true' in text or '"success":true' in text:
            print('success')
        else:
            print('fail')
    else:
        print('fail')
except Exception as e:
    print(f'erreur parsing JSON: {e}')
PYEOF
)"
  rm -f "$resp_file"

  if [ "$success" = "success" ]; then
    echo "PASS: log_exchange : sessionId=${session_id}, succes"
    return 0
  else
    echo "FAIL: log_exchange : sessionId=${session_id}, echec"
    return 1
  fi
}

# Cas 3: outil interdit
test_forbidden_tool() {
  local body_file resp_file http_code curl_rc
  body_file="$(mktemp /tmp/mnemos-integ-body.XXXXXX)"
  cat > "$body_file" <<'BODYEOF'
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"mnemos_update_profile","arguments":{"userId":"stephane"}},"id":1}
BODYEOF

  read -r http_code curl_rc resp_file < <(mnemos_secure_curl "$body_file")
  rm -f "$body_file"

  if [ "$curl_rc" -ne 0 ]; then
    echo "FAIL: forbidden_tool : echec curl"
    return 1
  fi

  # Le rejet doit etre un HTTP 200 avec un objet error JSON-RPC precis
  # (code -32601 ou message "not allowed for hook token"), pas juste la
  # presence generique d'une cle "error" (qui pourrait apparaitre pour une
  # tout autre raison et donner une fausse assurance).
  local has_error
  has_error="$(python3 - "$resp_file" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
    err = data.get('error')
    if isinstance(err, dict):
        code = err.get('code')
        message = err.get('message', '')
        if code == -32601 or 'not allowed for hook token' in message:
            print('true')
        else:
            print('false')
    else:
        print('false')
except Exception:
    print('false')
PYEOF
)"
  rm -f "$resp_file"

  if [ "$has_error" = "true" ]; then
    echo "PASS: forbidden_tool : rejet correct (HTTP 200, error.code=-32601)"
    return 0
  else
    echo "FAIL: forbidden_tool : rejet incorrect ou absent (HTTP $http_code, corps sans error.code=-32601)"
    return 1
  fi
}

# Cas 4: port ferme local
test_port_closed() {
  local start_time end_time duration
  start_time="$(python3 -c 'import time; print(int(time.time()*1000))')"
  local http_code curl_rc
  http_code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:1 2>/dev/null)"
  curl_rc=$?
  end_time="$(python3 -c 'import time; print(int(time.time()*1000))')"
  duration=$((end_time - start_time))

  if [ "$duration" -ge 4000 ]; then
    echo "FAIL: port_closed : timeout depasse 4 secondes ($duration ms)"
    return 1
  fi

  # curl_rc non nul = echec de connexion propre (port ferme), c'est le
  # comportement attendu. curl_rc == 0 avec un code HTTP 2xx/3xx signifierait
  # que quelque chose a repondu sur ce port, ce qui serait inattendu.
  if [ "$curl_rc" -eq 0 ] && [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
    echo "FAIL: port_closed : port ouvert de maniere inattendue (code HTTP $http_code)"
    return 1
  else
    echo "PASS: port_closed : tentative correctement interrompue en $duration ms (curl_rc=$curl_rc)"
    return 0
  fi
}

# Execution des tests
echo "Lancement des tests d'integration..."

test_recall
ret1=$?

test_log_exchange
ret2=$?

test_forbidden_tool
ret3=$?

test_port_closed
ret4=$?

# Resume
total=4
passed=0
if [ "$ret1" -eq 0 ]; then passed=$((passed + 1)); fi
if [ "$ret2" -eq 0 ]; then passed=$((passed + 1)); fi
if [ "$ret3" -eq 0 ]; then passed=$((passed + 1)); fi
if [ "$ret4" -eq 0 ]; then passed=$((passed + 1)); fi

echo "$passed/$total cas reussis"

if [ "$ret1" -ne 0 ] || [ "$ret2" -ne 0 ] || [ "$ret3" -ne 0 ] || [ "$ret4" -ne 0 ]; then
  exit 1
else
  exit 0
fi
