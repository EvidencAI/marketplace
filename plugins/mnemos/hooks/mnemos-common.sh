#!/usr/bin/env bash
# Fonctions partagees par mnemos-userpromptsubmit.sh et mnemos-stop.sh.
# Ce fichier est SOURCE (via `source`), jamais execute directement.

MNEMOS_EDGE_URL="https://hpbsowihyydzdnxuzoxs.supabase.co/functions/v1/mnemos-mcp"
MNEMOS_LOG_FILE="/tmp/mnemos-hook.log"

# mnemos_log <hook> <event> <duration_ms> <status> <response_size>
# Ecrit une ligne dans MNEMOS_LOG_FILE. Si le fichier depasse 1000000 octets
# avant l'ecriture, le vider (troncature simple) avant d'ecrire la nouvelle ligne.
# Ne doit JAMAIS faire echouer le script appelant (toutes erreurs avalees).
mnemos_log() {
  local hook="$1" event="$2" duration_ms="$3" status="$4" response_size="${5:-0}"
  local ts size
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if [ -f "$MNEMOS_LOG_FILE" ]; then
    size="$(wc -c < "$MNEMOS_LOG_FILE" 2>/dev/null | tr -d ' ')"
    if [ -n "$size" ] && [ "$size" -gt 1000000 ] 2>/dev/null; then
      : > "$MNEMOS_LOG_FILE" 2>/dev/null || true
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$hook" "$event" "$duration_ms" "$status" "$response_size" >> "$MNEMOS_LOG_FILE" 2>/dev/null || true
}

# mnemos_resolve_space_id <session_id> <transcript_path>
# Affiche le spaceId resolu sur stdout (chaine vide si inconnu). Utilise
# python3 (jamais jq) pour tout parsing JSON.
# Regle de cache : si /tmp/mnemos-hook-<session_id>.json existe, on lit sa cle
# "spaceId" et on la retourne TELLE QUELLE (meme vide) SANS reparser le
# transcript. Sinon on parse transcript_path ligne par ligne (json.loads par
# ligne, ignorer silencieusement les lignes invalides), on cherche la
# DERNIERE entree de type "assistant" contenant un bloc
# content[].type=="tool_use" dont le champ "name" se termine par
# "mnemos_session_start" (str.endswith), on extrait input.spaceId tel quel
# (ne pas transformer, peut etre un nom ou un UUID). Si trouve et
# session_id non vide : ecrire le cache /tmp/mnemos-hook-<session_id>.json
# avec le contenu exact {"spaceId": "<valeur>"}. Si rien trouve apres lecture
# complete : NE PAS ecrire de cache.
mnemos_resolve_space_id() {
  local session_id="$1" transcript_path="$2"
  local cache_file=""
  if [ -n "$session_id" ]; then
    cache_file="/tmp/mnemos-hook-${session_id}.json"
  fi

  if [ -n "$cache_file" ] && [ -f "$cache_file" ]; then
    local cached_value
    cached_value="$(python3 - "$cache_file" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    print("HIT:" + (data.get("spaceId", "") or ""))
except Exception:
    print("MISS")
PYEOF
)"
    case "$cached_value" in
      HIT:*)
        echo "${cached_value#HIT:}"
        return 0
        ;;
      *)
        # Cache illisible ou JSON invalide (ex. fichier tronque par un kill
        # en plein ecriture) : on ne retourne PAS "" immediatement, on
        # retombe sur le parsing du transcript comme si le cache n'existait
        # pas.
        ;;
    esac
  fi

  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    echo ""
    return 0
  fi

  local space_id
  space_id="$(python3 - "$transcript_path" <<'PYEOF'
import json, sys

path = sys.argv[1]
found = ""
try:
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue
            if entry.get("type") != "assistant":
                continue
            message = entry.get("message") or {}
            content = message.get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    name = block.get("name", "")
                    if isinstance(name, str) and name.endswith("mnemos_session_start"):
                        input_data = block.get("input") or {}
                        sid = input_data.get("spaceId")
                        if sid is not None:
                            found = sid
except Exception:
    pass
print(found)
PYEOF
)"

  if [ -n "$space_id" ] && [ -n "$cache_file" ]; then
    # Ecriture atomique : on ecrit dans un fichier temporaire puis on
    # renomme (os.replace) vers le chemin final, pour qu'un kill en plein
    # ecriture ne laisse jamais un cache tronque a la place du bon.
    python3 - "$cache_file" "$space_id" <<'PYEOF'
import json, os, sys
path, space_id = sys.argv[1], sys.argv[2]
tmp_path = path + ".tmp"
try:
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump({"spaceId": space_id}, f)
    os.replace(tmp_path, path)
except Exception:
    try:
        os.remove(tmp_path)
    except Exception:
        pass
PYEOF
  fi

  echo "$space_id"
}

# mnemos_curl_post <body_file> <cfgfile> <resp_file>
# POST body_file (fichier contenant le JSON-RPC deja construit) vers
# MNEMOS_EDGE_URL. cfgfile et resp_file DOIVENT etre crees (mktemp) et
# ajoutes a CLEANUP_FILES par le script APPELANT avant l'appel : cette
# fonction ne cree ni ne supprime plus aucun fichier temporaire elle-meme,
# pour qu'un kill (SIGTERM/SIGINT) en plein curl soit quand meme couvert
# par le trap de nettoyage du script appelant (cfgfile contient le jeton en
# clair, resp_file peut contenir du contenu memoire/PII).
# Le jeton d'authentification vit dans la variable globale MNEMOS_HOOK_TOKEN,
# qui DOIT deja etre definie par le script appelant AVANT d'appeler cette
# fonction (ne pas la definir ici, ne pas lui donner de valeur par defaut).
# Le corps de la reponse est ecrit directement dans resp_file (via curl -o),
# cette fonction n'ecrit rien sur stdout. Definit les variables globales
# MNEMOS_LAST_HTTP_CODE (code HTTP, "000" si inconnu) et MNEMOS_LAST_CURL_RC
# (code de retour de curl).
# Securite obligatoire : le jeton ne doit JAMAIS apparaitre en argument sur
# la ligne de commande curl (visible dans `ps aux`). Utiliser un fichier de
# config curl temporaire (-K), cree via heredoc bash (jamais via echo/printf
# avec le token en argument), chmod 600. curl --max-time 5 systematiquement.
mnemos_curl_post() {
  local body_file="$1" cfgfile="$2" resp_file="$3"
  local http_code curl_rc
  chmod 600 "$cfgfile"
  cat > "$cfgfile" <<CFGEOF
header = "Authorization: Bearer ${MNEMOS_HOOK_TOKEN}"
header = "Content-Type: application/json"
CFGEOF
  http_code="$(curl -s --max-time 5 -K "$cfgfile" -X POST --data-binary "@${body_file}" -o "$resp_file" -w '%{http_code}' "$MNEMOS_EDGE_URL" 2>/dev/null)"
  curl_rc=$?
  MNEMOS_LAST_HTTP_CODE="${http_code:-000}"
  MNEMOS_LAST_CURL_RC="$curl_rc"
}
