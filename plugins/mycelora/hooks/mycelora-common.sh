#!/usr/bin/env bash
# Fonctions partagees par mycelora-userpromptsubmit.sh et mycelora-stop.sh.
# Ce fichier est SOURCE (via `source`), jamais execute directement.

MYCELORA_EDGE_URL="https://api.mycelora.ai/functions/v1/mycelora-mcp"
MYCELORA_LOG_FILE="/tmp/mycelora-hook.log"

# mycelora_log <hook> <event> <duration_ms> <status> <response_size>
# Ecrit une ligne dans MYCELORA_LOG_FILE. Si le fichier depasse 1000000 octets
# avant l'ecriture, le vider (troncature simple) avant d'ecrire la nouvelle ligne.
# Ne doit JAMAIS faire echouer le script appelant (toutes erreurs avalees).
mycelora_log() {
  local hook="$1" event="$2" duration_ms="$3" status="$4" response_size="${5:-0}"
  local ts size
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if [ -f "$MYCELORA_LOG_FILE" ]; then
    size="$(wc -c < "$MYCELORA_LOG_FILE" 2>/dev/null | tr -d ' ')"
    if [ -n "$size" ] && [ "$size" -gt 1000000 ] 2>/dev/null; then
      : > "$MYCELORA_LOG_FILE" 2>/dev/null || true
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$hook" "$event" "$duration_ms" "$status" "$response_size" >> "$MYCELORA_LOG_FILE" 2>/dev/null || true
}

# ============================================================================
# Etiquettes du fil (S-ALIAS-1, fil 76, 24/08/2026)
# ============================================================================
#
# Le watcher est le SEUL point du systeme qui voit a la fois l'identifiant
# interne du fil (recu sur stdin) et ses etiquettes lisibles (dans le
# transcript). Il en resout TROIS en une seule passe :
#
#   spaceId      : input.spaceId du dernier tool_use mnemos_session_start.
#   sessionLabel : input.sessionId du MEME appel. C'est le nom technique qui
#                  se retrouvera dans handovers.session_id a la cloture ;
#                  il rend exact l'appariement lots / compte rendu, aujourd'hui
#                  heuristique par fenetre temporelle.
#   customTitle  : dernier customTitle des entrees type=custom-title. C'est le
#                  titre HUMAIN, celui que l'utilisateur voit et renomme dans
#                  son interface.
#
# CACHE INCREMENTAL (v2). L'ancien cache figeait le resultat des le premier
# succes, ce qui interdisait de voir apparaitre plus tard une etiquette encore
# absente — or l'utilisateur peut renommer son fil a tout moment, et
# session_start peut etre appele apres le premier tour. Le cache garde donc
# desormais l'OFFSET en octets deja lu, et chaque appel ne lit que la QUEUE
# ajoutee depuis. Cout constant, et rien n'est fige.
#
# Un cache d'ancienne generation (sans "v": 2) est traite comme ABSENT, pas
# comme un resultat vide : sinon les fils deja en cours n'auraient jamais
# d'etiquette.
#
# LIMITE ASSUMEE, a connaitre avant d'en dependre : une etiquette n'est jamais
# EFFACEE, seulement remplacee par une autre non vide. Si l'utilisateur revient
# d'un titre choisi a un titre genere, le dernier titre choisi reste en cache
# et continue d'etre envoye. Ce comportement est volontaire (une etiquette vide
# n'apprend rien et ne doit pas ecraser une etiquette utile), mais il rend le
# cache sensible a la reutilisation d'un meme session_id sur deux transcripts
# differents — cas de test, pas cas reel.
#
# Format : {"v":2,"offset":<int>,"spaceId":"","sessionLabel":"","customTitle":""}

# _mycelora_charger_fil <session_id> <transcript_path>
# Rend TROIS lignes sur stdout, dans cet ordre, chacune eventuellement vide :
#   spaceId / sessionLabel / customTitle
# Ne leve jamais, n'ecrit jamais sur stderr.
_mycelora_charger_fil() {
  local session_id="$1" transcript_path="$2"
  local cache_file=""
  if [ -n "$session_id" ]; then
    cache_file="/tmp/mycelora-hook-${session_id}.json"
  fi

  python3 - "$cache_file" "$transcript_path" <<'PYEOF'
import json, os, sys

cache_path, transcript_path = sys.argv[1], sys.argv[2]

etat = {"v": 2, "offset": 0, "spaceId": "", "sessionLabel": "", "customTitle": ""}

# Cache v2 uniquement. Une version anterieure (ou un fichier tronque par un
# kill en pleine ecriture) est traitee comme absente : on repart de l'offset 0
# et on reconstruit tout.
if cache_path and os.path.exists(cache_path):
    try:
        with open(cache_path, "r", encoding="utf-8") as f:
            ancien = json.load(f)
        if isinstance(ancien, dict) and ancien.get("v") == 2:
            for cle in ("offset", "spaceId", "sessionLabel", "customTitle"):
                if cle in ancien:
                    etat[cle] = ancien[cle]
    except Exception:
        pass


def propre(valeur):
    """Une etiquette est une ligne de texte. Jamais de saut de ligne (le
    protocole de sortie est en lignes), jamais autre chose qu'une chaine."""
    if not isinstance(valeur, str):
        return ""
    return " ".join(valeur.split()).strip()


modifie = False
if transcript_path and os.path.exists(transcript_path):
    try:
        taille = os.path.getsize(transcript_path)
        depart = etat.get("offset", 0)
        if not isinstance(depart, int) or depart < 0 or depart > taille:
            # Transcript remplace ou tronque : on ne devine pas, on relit tout.
            depart = 0
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as f:
            f.seek(depart)
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if not isinstance(entry, dict):
                    continue

                # Titre humain : une entree dediee, sans rapport avec les
                # appels d'outils. Le dernier vu gagne (regle R1).
                if entry.get("type") == "custom-title":
                    titre = propre(entry.get("customTitle"))
                    if titre:
                        etat["customTitle"] = titre
                        modifie = True
                    continue

                if entry.get("type") != "assistant":
                    continue
                message = entry.get("message") or {}
                content = message.get("content")
                if not isinstance(content, list):
                    continue
                for block in content:
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    name = block.get("name", "")
                    if not (isinstance(name, str) and name.endswith("mnemos_session_start")):
                        continue
                    input_data = block.get("input") or {}
                    # spaceId : conserve TEL QUEL (peut etre un nom ou un UUID),
                    # contrat historique de cette resolution.
                    sid = input_data.get("spaceId")
                    if isinstance(sid, str) and sid.strip():
                        etat["spaceId"] = sid
                        modifie = True
                    label = propre(input_data.get("sessionId"))
                    if label:
                        etat["sessionLabel"] = label
                        modifie = True
            etat["offset"] = f.tell()
            modifie = True
    except Exception:
        # Transcript illisible : on rend ce que le cache portait deja.
        pass

# Ecriture atomique (tmp + os.replace) : un kill en pleine ecriture ne doit
# jamais laisser un cache tronque a la place du bon.
if cache_path and modifie:
    tmp_path = cache_path + ".tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(etat, f)
        os.replace(tmp_path, cache_path)
    except Exception:
        try:
            os.remove(tmp_path)
        except Exception:
            pass

print(etat.get("spaceId", "") or "")
print(etat.get("sessionLabel", "") or "")
print(etat.get("customTitle", "") or "")
PYEOF
}

# mycelora_resolve_space_id <session_id> <transcript_path>
# Affiche le spaceId resolu sur stdout (chaine vide si inconnu).
# Contrat de sortie INCHANGE depuis la v1 : une seule ligne.
mycelora_resolve_space_id() {
  _mycelora_charger_fil "$1" "$2" | sed -n '1p'
}

# mycelora_resolve_etiquettes <session_id> <transcript_path>
# Affiche DEUX lignes sur stdout : sessionLabel puis customTitle (chacune
# eventuellement vide). S-ALIAS-1.
mycelora_resolve_etiquettes() {
  _mycelora_charger_fil "$1" "$2" | sed -n '2,3p'
}

# mycelora_curl_post <body_file> <cfgfile> <resp_file>
# POST body_file (fichier contenant le JSON-RPC deja construit) vers
# MYCELORA_EDGE_URL. cfgfile et resp_file DOIVENT etre crees (mktemp) et
# ajoutes a CLEANUP_FILES par le script APPELANT avant l'appel : cette
# fonction ne cree ni ne supprime plus aucun fichier temporaire elle-meme,
# pour qu'un kill (SIGTERM/SIGINT) en plein curl soit quand meme couvert
# par le trap de nettoyage du script appelant (cfgfile contient le jeton en
# clair, resp_file peut contenir du contenu memoire/PII).
# Le jeton d'authentification vit dans la variable globale MYCELORA_HOOK_TOKEN,
# qui DOIT deja etre definie par le script appelant AVANT d'appeler cette
# fonction (ne pas la definir ici, ne pas lui donner de valeur par defaut).
# Le corps de la reponse est ecrit directement dans resp_file (via curl -o),
# cette fonction n'ecrit rien sur stdout. Definit les variables globales
# MYCELORA_LAST_HTTP_CODE (code HTTP, "000" si inconnu) et MYCELORA_LAST_CURL_RC
# (code de retour de curl).
# Securite obligatoire : le jeton ne doit JAMAIS apparaitre en argument sur
# la ligne de commande curl (visible dans `ps aux`). Utiliser un fichier de
# config curl temporaire (-K), cree via heredoc bash (jamais via echo/printf
# avec le token en argument), chmod 600. curl --max-time 5 systematiquement.
# x-region: eu-west-1 (0.9.8, fil myy 29/08/2026) : l'edge function s'execute
# pres de l'APPELANT par defaut, or les conteneurs Cowork tournent aux US et
# la base est en eu-west-1 -- chaque aller-retour base payait l'Atlantique et
# le recall depassait le --max-time 5 (mesure : 4,6-7,9 s sans l'en-tete,
# 3,2-3,65 s avec). Cet en-tete epingle l'execution dans la region de la
# base ; ne pas le retirer sans re-mesurer depuis un conteneur Cowork.
mycelora_curl_post() {
  local body_file="$1" cfgfile="$2" resp_file="$3"
  local http_code curl_rc
  chmod 600 "$cfgfile"
  cat > "$cfgfile" <<CFGEOF
header = "Authorization: Bearer ${MYCELORA_HOOK_TOKEN}"
header = "Content-Type: application/json"
header = "x-region: eu-west-1"
CFGEOF
  http_code="$(curl -s --max-time 5 -K "$cfgfile" -X POST --data-binary "@${body_file}" -o "$resp_file" -w '%{http_code}' "$MYCELORA_EDGE_URL" 2>/dev/null)"
  curl_rc=$?
  MYCELORA_LAST_HTTP_CODE="${http_code:-000}"
  MYCELORA_LAST_CURL_RC="$curl_rc"
}
