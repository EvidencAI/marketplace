#!/usr/bin/env bash
# Fonctions partagees par mycelora-userpromptsubmit.sh et mycelora-stop.sh.
# Ce fichier est SOURCE (via `source`), jamais execute directement.

MYCELORA_EDGE_URL="https://api.mycelora.ai/functions/v1/mycelora-mcp"
MYCELORA_LOG_FILE="/tmp/mycelora-hook.log"

# 0.11.4 (03/09/2026) : outils porteurs d'une COMMANDE shell, donc du reflexe
# d'impact (refus en PreToolUse, jalon en PostToolUse). Rend l'etiquette
# courte de l'outil ("Bash", "Desktop_Commander"), ou rien si l'outil n'est
# pas concerne. Desktop Commander est reconnu par le SUFFIXE de son nom :
# "mcp__remote-devices__Desktop_Commander__start_process" sur un fil cloud
# relie au Mac, "mcp__Desktop_Commander__start_process" (ou autre prefixe)
# sur un fil local. Motivation : l'outil Bash de Cowork tourne dans la VM
# cloud, sans cle ssh ni sql.sh ; le seul chemin vers la prod est Desktop
# Commander, que la v1 (brief 4.2) laissait hors du reflexe. Decision
# Stephane du 03/09 : start_process seulement ; interact_with_process
# (texte envoye a un programme deja lance) reste en dette.
mycelora_outil_commande() {
  local nom_min
  case "$1" in
    Bash) printf 'Bash'; return 0 ;;
    *start_process) ;;
    *) printf ''; return 0 ;;
  esac
  # Seuls les noms finissant par start_process paient le tr (casse
  # normalisee, bash 3.2 du Mac sans ${var,,}).
  nom_min="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "$nom_min" in
    *desktop_commander__start_process|*desktop-commander__start_process) printf 'Desktop_Commander' ;;
    *) printf '' ;;
  esac
}

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
# CACHE INCREMENTAL (v3, S-REFLEXES-6). L'ancien cache figeait le resultat des
# le premier succes, ce qui interdisait de voir apparaitre plus tard une
# etiquette encore absente — or l'utilisateur peut renommer son fil a tout
# moment, et session_start peut etre appele apres le premier tour. Le cache
# garde donc l'OFFSET en octets deja lu, et chaque appel ne lit que la QUEUE
# ajoutee depuis. Cout constant, et rien n'est fige.
#
# Un cache d'ancienne generation (sans "v": 3, donc y compris un cache v2) est
# traite comme ABSENT, pas comme un resultat vide : sinon les fils deja en
# cours n'auraient jamais d'etiquette (meme regle qu'au passage v1 -> v2).
#
# LIMITE ASSUMEE, a connaitre avant d'en dependre : une etiquette n'est jamais
# EFFACEE, seulement remplacee par une autre non vide. Si l'utilisateur revient
# d'un titre choisi a un titre genere, le dernier titre choisi reste en cache
# et continue d'etre envoye. Ce comportement est volontaire (une etiquette vide
# n'apprend rien et ne doit pas ecraser une etiquette utile), mais il rend le
# cache sensible a la reutilisation d'un meme session_id sur deux transcripts
# differents — cas de test, pas cas reel. hookToken suit la meme regle
# ("dernier vu gagne", jamais efface par une absence).
#
# Format : {"v":3,"offset":<int>,"spaceId":"","sessionLabel":"","customTitle":"","hookToken":""}

# _mycelora_charger_fil <session_id> <transcript_path>
# Rend QUATRE lignes sur stdout, dans cet ordre, chacune eventuellement vide :
#   spaceId / sessionLabel / customTitle / hookToken
# Ne leve jamais, n'ecrit jamais sur stderr.
_mycelora_charger_fil() {
  local session_id="$1" transcript_path="$2"
  local cache_file=""
  if [ -n "$session_id" ]; then
    cache_file="/tmp/mycelora-hook-${session_id}.json"
  fi

  python3 - "$cache_file" "$transcript_path" <<'PYEOF'
import json, os, re, sys

cache_path, transcript_path = sys.argv[1], sys.argv[2]

etat = {"v": 3, "offset": 0, "spaceId": "", "sessionLabel": "", "customTitle": "", "hookToken": ""}

# Cache v3 uniquement. Une version anterieure (v2, v1, ou un fichier tronque
# par un kill en pleine ecriture) est traitee comme absente : on repart de
# l'offset 0 et on reconstruit tout.
if cache_path and os.path.exists(cache_path):
    try:
        with open(cache_path, "r", encoding="utf-8") as f:
            ancien = json.load(f)
        if isinstance(ancien, dict) and ancien.get("v") == 3:
            for cle in ("offset", "spaceId", "sessionLabel", "customTitle", "hookToken"):
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


# S-REFLEXES-6 : le jeton de session hook voyage dans le TEXTE du brief rendu
# par mnemos_session_start (le tool_result), sur une ligne dediee. Fonction
# PURE, testee isolement et par mutation (regle 8bis).
_RE_JETON = re.compile(r"^\[jeton-hook-session[^\]]*\][ \t]+(mk_sess_[A-Za-z0-9_-]+)[ \t]*$", re.MULTILINE)


def extraire_jeton(texte):
    """str -> str | None. Dernier match si plusieurs lignes candidates dans
    le meme texte (rare, mais coherent avec 'le dernier vu gagne')."""
    if not isinstance(texte, str):
        return None
    matches = _RE_JETON.findall(texte)
    return matches[-1] if matches else None


# Correctif du 02/09/2026 soir (fil cowork-2026-09-02-2147-mycelora) : depuis
# le fil 86 (26/08), le serveur HORODATE lui-meme le sessionId envoye a
# mnemos_session_start et annonce l'identifiant DEFINITIF sur la ligne
# « Fil : ... » du brief (tool_result). C'est cet identifiant-la, pas celui
# de l'appel, qui signe le handover a la cloture. sessionLabel etait lu dans
# input.sessionId de l'appel : l'alias (session_aliases.session_label)
# divergeait donc du handover sur chaque fil ouvert depuis le 26/08, et
# l'appariement lots / compte rendu que ce champ doit rendre exact etait
# casse. Meme forme que extraire_jeton : fonction pure, ligne dediee, le
# dernier vu gagne, rien a cheval sur deux lignes.
_RE_FIL = re.compile(r"^Fil[ \t]*:[ \t]+([A-Za-z0-9._-]+)(?:[ \t]|$)", re.MULTILINE)


def extraire_fil(texte):
    """str -> str | None. Identifiant de fil rendu par le serveur sur la
    ligne « Fil : <id> ... » du brief d'ouverture ; dernier match si
    plusieurs."""
    if not isinstance(texte, str):
        return None
    matches = _RE_FIL.findall(texte)
    return matches[-1] if matches else None


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
            # Boucle manuelle (pas "for line in f") : une ligne renvoyee par
            # readline() SANS "\n" final est une ecriture en cours, elle ne
            # doit jamais etre consommee (sinon le contenu a moitie ecrit est
            # perdu pour toujours des qu'il se complete). L'offset n'avance
            # qu'apres une ligne confirmee "\n"-terminee.
            dernier_offset_complet = depart
            while True:
                ligne_brute = f.readline()
                if not ligne_brute:
                    break
                if not ligne_brute.endswith("\n"):
                    break  # ligne en cours d'ecriture : ne pas la consommer
                dernier_offset_complet = f.tell()
                line = ligne_brute.strip()
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

                # Resultat d'outil : c'est ICI, dans le texte du tool_result
                # de mnemos_session_start, que voyage le jeton hook (pas dans
                # l'appel type=assistant ci-dessous). PAS de correlation par
                # tool_use_id (contrat figé S-REFLEXES-6) : on regarde juste
                # si un bloc tool_result de cette entree porte la ligne
                # jeton, quel que soit l'appel qu'il repond.
                if entry.get("type") == "user":
                    message = entry.get("message") or {}
                    content = message.get("content")
                    if isinstance(content, list):
                        for block in content:
                            if not isinstance(block, dict) or block.get("type") != "tool_result":
                                continue
                            bcontent = block.get("content")
                            texte_bloc = None
                            if isinstance(bcontent, str):
                                texte_bloc = bcontent
                            elif isinstance(bcontent, list):
                                morceaux = []
                                for sous_bloc in bcontent:
                                    if isinstance(sous_bloc, dict) and sous_bloc.get("type") == "text":
                                        t = sous_bloc.get("text")
                                        if isinstance(t, str):
                                            morceaux.append(t)
                                if morceaux:
                                    texte_bloc = "\n".join(morceaux)
                            jeton = extraire_jeton(texte_bloc) if texte_bloc is not None else None
                            if jeton:
                                etat["hookToken"] = jeton
                                modifie = True
                            # Identifiant de fil rendu par le serveur (ligne
                            # « Fil : ... ») : il PRIME sur input.sessionId de
                            # l'appel, lu plus bas dans l'entree assistant, car
                            # le tool_result arrive toujours APRES l'appel dans
                            # le transcript (le dernier vu gagne, regle R1).
                            # Garde : seulement dans un brief d'ouverture
                            # (jeton present dans le meme bloc, ou bandeau
                            # MNEMOS IN), jamais dans le resultat d'un autre
                            # outil qui citerait une ligne « Fil : ... ».
                            est_brief = bool(jeton) or (texte_bloc is not None and "MNEMOS IN" in texte_bloc)
                            fil = extraire_fil(texte_bloc) if (est_brief and texte_bloc is not None) else None
                            if fil:
                                etat["sessionLabel"] = fil
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
            etat["offset"] = dernier_offset_complet
            modifie = True
    except Exception:
        # Transcript illisible : on rend ce que le cache portait deja.
        pass

# Ecriture atomique (tmp + os.replace) : un kill en pleine ecriture ne doit
# jamais laisser un cache tronque a la place du bon. Le fichier porte
# desormais un secret vivant (hookToken) : os.open(..., 0o600) CREE le
# fichier DIRECTEMENT en 0600 (pas d'ouverture "w" suivie d'un chmod
# separe), pour ne jamais laisser de fenetre ou le fichier existe sous
# l'umask par defaut (souvent 0644, secret brievement lisible par d'autres
# comptes locaux) avant d'etre resserre.
if cache_path and modifie:
    tmp_path = cache_path + ".tmp"
    try:
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
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
print(etat.get("hookToken", "") or "")
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

# mycelora_resolve_hook_token <session_id> <transcript_path>
# AFFECTE la variable globale MYCELORA_HOOK_TOKEN (ne la retourne pas sur
# stdout). Contrat figé S-REFLEXES-6 :
#   1) MYCELORA_HOOK_TOKEN deja non vide ET != "__MYCELORA_HOOK_KEY__" -> gardee
#   2) sinon, hookToken du cache v3 (peut declencher sa lecture/reconstruction)
#   3) sinon, chaine vide
mycelora_resolve_hook_token() {
  local session_id="$1" transcript_path="$2"
  if [ -n "${MYCELORA_HOOK_TOKEN:-}" ] && [ "$MYCELORA_HOOK_TOKEN" != "__MYCELORA_HOOK_KEY__" ]; then
    return 0
  fi
  MYCELORA_HOOK_TOKEN="$(_mycelora_charger_fil "$session_id" "$transcript_path" | sed -n '4p')"
}

# mycelora_curl_post <body_file> <cfgfile> <resp_file> [timeout_secondes]
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
# timeout_secondes (S-REFLEXES-2, 02/09/2026) : optionnel, defaut 5 (contrat
# historique inchange pour les appelants existants qui ne le passent pas).
# mnemos_impact_lookup se donne un budget de 4 s (mesure du 29/08 : 3,2-3,65 s
# par appel depuis un conteneur Cowork), distinct des 5 s de mnemos_recall/
# mnemos_log_exchange.
# Securite obligatoire : le jeton ne doit JAMAIS apparaitre en argument sur
# la ligne de commande curl (visible dans `ps aux`). Utiliser un fichier de
# config curl temporaire (-K), cree via heredoc bash (jamais via echo/printf
# avec le token en argument), chmod 600. curl --max-time systematiquement.
# x-region: eu-west-1 (0.9.8, fil myy 29/08/2026) : l'edge function s'execute
# pres de l'APPELANT par defaut, or les conteneurs Cowork tournent aux US et
# la base est en eu-west-1 -- chaque aller-retour base payait l'Atlantique et
# le recall depassait le --max-time 5 (mesure : 4,6-7,9 s sans l'en-tete,
# 3,2-3,65 s avec). Cet en-tete epingle l'execution dans la region de la
# base ; ne pas le retirer sans re-mesurer depuis un conteneur Cowork.
mycelora_curl_post() {
  local body_file="$1" cfgfile="$2" resp_file="$3" timeout="${4:-5}"
  local http_code curl_rc
  chmod 600 "$cfgfile"
  cat > "$cfgfile" <<CFGEOF
header = "Authorization: Bearer ${MYCELORA_HOOK_TOKEN}"
header = "Content-Type: application/json"
header = "x-region: eu-west-1"
CFGEOF
  http_code="$(curl -s --max-time "$timeout" -K "$cfgfile" -X POST --data-binary "@${body_file}" -o "$resp_file" -w '%{http_code}' "$MYCELORA_EDGE_URL" 2>/dev/null)"
  curl_rc=$?
  MYCELORA_LAST_HTTP_CODE="${http_code:-000}"
  MYCELORA_LAST_CURL_RC="$curl_rc"
}

# ============================================================================
# RÉFLEXE D'IMPACT (S-REFLEXES-2, 02/09/2026) — fonctions partagees par
# mycelora-pretooluse.sh et mycelora-posttooluse.sh. Voir les deux scripts
# pour l'orchestration ; ce qui suit ne fait qu'implementer les briques
# communes (detection, enrichissement, journal, interrupteur).
# ============================================================================

MYCELORA_REFLEXES_LOG_MAX_BYTES=1000000

# mycelora_repo_root <dir>
# Remonte depuis <dir> jusqu'a trouver un .git dont la racine contient
# supabase/ OU plugins/mycelora/ (edge-function ou evidencai-marketplace).
# Affiche le chemin trouve sur stdout ; rien si aucun (jamais d'erreur).
mycelora_repo_root() {
  local dir="$1"
  case "$dir" in
    /*) ;;
    *) return 0 ;;
  esac
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -e "$dir/.git" ] && { [ -d "$dir/supabase" ] || [ -d "$dir/plugins/mycelora" ]; }; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 0
}

# mycelora_reflexe_desarme <repo_root_ou_vide>
# Affiche "1" si le reflexe d'impact est desarme (MYCELORA_REFLEXE_IMPACT=0
# OU fichier .mycelora-reflexes-off a la racine du depot resolu), "0" sinon.
# Necessaire aussi parce que le sprint lui-meme modifie les fichiers que le
# reflexe surveille (brief section 4.2).
mycelora_reflexe_desarme() {
  local repo_root="${1:-}"
  if [ "${MYCELORA_REFLEXE_IMPACT:-}" = "0" ]; then
    printf '1'
    return 0
  fi
  if [ -n "$repo_root" ] && [ -f "$repo_root/.mycelora-reflexes-off" ]; then
    printf '1'
    return 0
  fi
  printf '0'
}

# mycelora_purge_markers_anciens
# Purge les marqueurs /tmp/mycelora-impact-* de plus de 24h, a appeler UNE
# fois au demarrage du hook PreToolUse, avant toute lecture/ecriture de
# marqueur (contrat figé : "purge des marqueurs de plus de 24h au demarrage
# du hook").
mycelora_purge_markers_anciens() {
  find /tmp -maxdepth 1 -name 'mycelora-impact-*' -type f -mmin +1440 -delete 2>/dev/null || true
}

# mycelora_reflexe_log <session_id> <evt> <outil> <objets_json_array> <empreinte> <rapport_vide 0|1> [carte_age_jours]
# Ecrit une ligne JSONL dans /tmp/mycelora-reflexes-<session_id>.jsonl,
# tronque a 1 Mo comme mycelora_log (contrat FIGÉ, brief section 4.2). N'ecrit
# rien si session_id est vide. Erreurs toujours avalees.
# carte_age_jours (S-REFLEXES-5b) : 7e argument OPTIONNEL, chaine vide =
# absent. N'ecrit la cle "carte_age_jours" dans le JSON QUE si la valeur
# recue est non vide et numerique (jamais une cle a null, jamais une chaine
# vide) -- meme discipline que tools.ts cote serveur pour ce meme champ.
mycelora_reflexe_log() {
  local session_id="$1" evt="$2" outil="$3" objets_json="$4" empreinte="$5" rapport_vide="$6" carte_age_jours="${7:-}"
  local safe_session
  safe_session="$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._-')"
  [ -z "$safe_session" ] && return 0
  local journal_file="/tmp/mycelora-reflexes-${safe_session}.jsonl"
  if [ -f "$journal_file" ]; then
    local size
    size="$(wc -c < "$journal_file" 2>/dev/null | tr -d ' ')"
    if [ -n "$size" ] && [ "$size" -gt "$MYCELORA_REFLEXES_LOG_MAX_BYTES" ] 2>/dev/null; then
      : > "$journal_file" 2>/dev/null || true
    fi
  fi
  python3 - "$journal_file" "$evt" "$outil" "$objets_json" "$empreinte" "$rapport_vide" "$carte_age_jours" <<'PYEOF' 2>/dev/null || true
import json, sys, time

journal_path, evt, outil, objets_json, empreinte, rapport_vide, carte_age_jours = sys.argv[1:8]
try:
    objets = json.loads(objets_json)
    if not isinstance(objets, list):
        objets = []
except Exception:
    objets = []

ligne = {
    "t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "evt": evt,
    "outil": outil,
    "objets": objets,
    "empreinte": empreinte,
    "rapport_vide": rapport_vide == "1",
}
if carte_age_jours.strip().isdigit():
    ligne["carte_age_jours"] = int(carte_age_jours.strip())
try:
    with open(journal_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(ligne, ensure_ascii=False) + "\n")
except Exception:
    pass
PYEOF
}

# mycelora_reflexe_detecter <stdin_json_path> <out_json_path>
# FONCTION D'ORCHESTRATION DE LA DETECTION (brief section 4.2, contrat
# FIGÉ). Lit l'evenement PreToolUse/PostToolUse (stdin_json_path), et si
# tool_input.command (outil Bash) correspond a un geste structurant, ecrit
# dans out_json_path un objet {"ok":true,"geste":...,"sous_type":...,
# "uid_valeur":...,"objets":[...],"session_id":...,"cwd":...,
# "transcript_path":...,"tool_use_id":...,"fichier_lu":...,"empreinte":...}.
# Sinon {"ok":false}. N'ecrit jamais sur stdout, ne leve jamais.
#
# Contient la FONCTION PURE DE DETECTION (nettoyer_sql, detecter_ddl,
# detecter_update_delete_risque) exigee testable par mutation (regle 8bis) :
# nettoyage des commentaires/litteraux SQL AVANT tout matching, motifs DDL
# ancres en tete d'instruction (un SELECT ne peut jamais matcher).
mycelora_reflexe_detecter() {
  local stdin_path="$1" out_path="$2"
  python3 - "$stdin_path" "$out_path" <<'PYEOF' 2>/dev/null || true
import hashlib
import json
import os
import re
import sys

stdin_path, out_path = sys.argv[1], sys.argv[2]

def echouer():
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"ok": False}, f)
    sys.exit(0)

try:
    with open(stdin_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    echouer()

tool_input = data.get("tool_input")
if not isinstance(tool_input, dict):
    tool_input = {}
commande = tool_input.get("command", "")
if not isinstance(commande, str):
    commande = ""
session_id = data.get("session_id", "") or ""
cwd = data.get("cwd", "") or ""
transcript_path = data.get("transcript_path", "") or ""
tool_use_id = data.get("tool_use_id", "") or ""

if not commande.strip():
    echouer()

# ==========================================================================
# FONCTION PURE DE DETECTION (testable par mutation, regle 8bis).
# ==========================================================================

def nettoyer_sql(texte):
    """Retire d'abord les commentaires SQL puis les litteraux, AVANT tout
    matching : un "alter" cite dans un commentaire ou une chaine ne doit
    jamais declencher."""
    texte = re.sub(r"/\*.*?\*/", " ", texte, flags=re.DOTALL)
    texte = re.sub(r"--[^\n]*", " ", texte)
    texte = re.sub(r"'(?:[^'\\]|\\.)*'", "''", texte)
    return texte

RE_DDL = re.compile(
    r"^\s*(alter\s+table|drop\s+(table|function)|create\s+(or\s+replace\s+)?function|create\s+table|truncate)\b",
    re.IGNORECASE | re.MULTILINE,
)

def detecter_ddl(texte_nettoye):
    """Un SELECT ne peut matcher aucun de ces motifs par construction
    (ancrage en tete d'instruction)."""
    return bool(RE_DDL.search(texte_nettoye))

# CORRECTION (relecture reviewer/ergonome du 02/09) : l'ancien motif
# \b(update|delete\s+from)\b, applique sans ancrage, matchait le mot anglais
# "update" n'importe ou dans une commande Bash quelconque -- confirme en
# reel : "npm update", "sudo apt-get update", "brew update",
# "git remote update", "cargo update -p serde" declenchaient tous un deny
# absurde. Deux motifs ANCRES en tete d'instruction (meme convention que
# RE_DDL, multiligne) : UPDATE doit etre suivi d'une vraie clause SET
# (structure SQL reelle, pas seulement le mot en tete -- une commande
# "update-alternatives --config editor" est un vrai risque sinon, "update"
# y est bien le premier mot mais ce n'est pas du SQL) ; DELETE FROM ancre
# comme les motifs DDL.
RE_UPDATE_ANCRE = re.compile(r"^\s*update\s+[\w.\"'`]+\s+set\b", re.IGNORECASE | re.MULTILINE)
RE_DELETE_ANCRE = re.compile(r"^\s*delete\s+from\b", re.IGNORECASE | re.MULTILINE)
RE_WHERE = re.compile(r"\bwhere\b", re.IGNORECASE)
# Presence BOOLEENNE seulement (pas de capture de valeur ici) : applique sur
# le texte NETTOYE (litteraux deja remplaces par ''), donc "user_id = ''"
# matche encore ce motif meme si la vraie valeur a ete effacee par
# nettoyer_sql. L'extraction de la valeur pour l'affichage se fait a part,
# sur le texte BRUT (cf. extraire_uid_valeur) : deux besoins distincts,
# risque (booleen) et cosmetique (valeur), qui ne peuvent pas partager la
# meme passe puisque le nettoyage detruit la valeur avant la detection.
RE_USER_ID_PRESENCE = re.compile(r"user_id\s*=", re.IGNORECASE)
RE_USER_ID_VALEUR = re.compile(r"user_id\s*=\s*'([0-9a-fA-F-]{4,})'", re.IGNORECASE)

def detecter_update_delete_risque(texte_nettoye):
    """Rend (True,"user_id") | (True,"sans_where") | (False,None). Cherche
    UPDATE ... SET ou DELETE FROM ANCRES en tete d'instruction, puis verifie
    l'absence de WHERE dans la suite de l'instruction (jusqu'au ';' suivant),
    OU la presence de user_id= dans la clause trouvee."""
    m = RE_UPDATE_ANCRE.search(texte_nettoye)
    if not m:
        m = RE_DELETE_ANCRE.search(texte_nettoye)
    if not m:
        return (False, None)
    suite = texte_nettoye[m.end():]
    fin = suite.find(";")
    clause = suite if fin == -1 else suite[:fin]
    if RE_USER_ID_PRESENCE.search(clause):
        return (True, "user_id")
    if not RE_WHERE.search(clause):
        return (True, "sans_where")
    return (False, None)

def extraire_uid_valeur(texte_brut):
    """Best-effort, cosmetique UNIQUEMENT (n'entre pas dans la decision de
    risque) : cherche la vraie valeur user_id= sur le texte BRUT (non
    nettoye, donc pas encore ampute de ses litteraux) pour l'afficher dans le
    rapport. Rend None si absente ou introuvable — le rapport se rabat alors
    sur un texte generique."""
    m = RE_USER_ID_VALEUR.search(texte_brut)
    return m.group(1) if m else None

# Motifs infra (texte BRUT, pas nettoye : pas des enonces SQL). Decides au
# cliquet Q4 (S-REFLEXES-AUDIT-REPONSES.md).
RE_SSH_PSQL = re.compile(r"docker\s+exec\b.*\bpsql\b", re.IGNORECASE | re.DOTALL)
RE_RSYNC_MOT = re.compile(r"\brsync\b", re.IGNORECASE)
RE_VOLUMES_FUNCTIONS = re.compile(r"volumes/functions", re.IGNORECASE)
RE_DOCKER_RESTART = re.compile(r"\bdocker\s+restart\b", re.IGNORECASE)
RE_CURL = re.compile(r"\bcurl\b", re.IGNORECASE)
RE_PATCH_VERBE = re.compile(r"(-X\s*PATCH\b|--request\s+PATCH\b)", re.IGNORECASE)
RE_ENVS_URL = re.compile(r"/envs\b", re.IGNORECASE)

# CORRECTION (relecture reviewer/ergonome du 02/09) : "docker restart",
# "rsync" et "curl" (Coolify) declenchaient depuis N'IMPORTE OU dans la
# chaine -- confirme en reel : echo "docker restart plus tard" et
# git commit -m "add docker restart step" declenchaient un deny absurde.
# Ces trois motifs sont desormais GATES en position de debut d'instruction
# shell reelle : tout debut de chaine, ou juste apres un separateur
# &&/||/;/|/saut de ligne. ssh_psql reste SANS gating : c'est un motif
# COMPOSE (docker exec ET psql) deja peu propice a la prose, et surtout
# INTRINSEQUEMENT imbrique dans un wrapper ("ssh hote \"docker exec -i
# conteneur psql ...\"", forme reelle unique de ce depot, section 9 du
# brief) -- un gating de position aurait casse son propre cas d'usage
# vise. Gap assume pour docker_restart/coolify_patch imbriques de la meme
# facon via ssh (non observe dans ce depot), documente en v2-decisions.
RE_DEBUT_SEGMENT = re.compile(r"(?:\A|&&|\|\||;|\||\n)\s*")

def _positions_debut_segment(texte):
    return {m.end() for m in RE_DEBUT_SEGMENT.finditer(texte)}

def detecter_infra(texte_brut):
    if RE_SSH_PSQL.search(texte_brut):
        return "ssh_psql"

    positions = _positions_debut_segment(texte_brut)

    m = RE_RSYNC_MOT.search(texte_brut)
    if m and m.start() in positions and RE_VOLUMES_FUNCTIONS.search(texte_brut[m.end():]):
        return "rsync"

    m = RE_DOCKER_RESTART.search(texte_brut)
    if m and m.start() in positions:
        return "docker_restart"

    m = RE_CURL.search(texte_brut)
    if m and m.start() in positions and RE_PATCH_VERBE.search(texte_brut) and RE_ENVS_URL.search(texte_brut):
        return "coolify_patch"

    return None

# ==========================================================================
# EXTRACTION D'IDENTIFIANTS (brief section 4.2). Une instruction a la fois
# (split sur ';') pour supporter N objets dans une meme commande.
# ==========================================================================

RE_ALTER_TABLE = re.compile(r"alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?[\"'`]?([a-zA-Z_][\w.]*)", re.IGNORECASE)
RE_DROP_TABLE = re.compile(r"drop\s+table\s+(?:if\s+exists\s+)?[\"'`]?([a-zA-Z_][\w.]*)", re.IGNORECASE)
RE_DROP_FUNCTION = re.compile(r"drop\s+function\s+[\"'`]?([a-zA-Z_][\w.]*)", re.IGNORECASE)
RE_UPDATE_TABLE = re.compile(r"update\s+(?:only\s+)?[\"'`]?([a-zA-Z_][\w.]*)", re.IGNORECASE)
RE_DELETE_TABLE = re.compile(r"delete\s+from\s+[\"'`]?([a-zA-Z_][\w.]*)", re.IGNORECASE)
RE_CREATE_FUNCTION = re.compile(r"create\s+(?:or\s+replace\s+)?function\s+[\"'`]?([a-zA-Z_][\w.]*)", re.IGNORECASE)
RE_CREATE_TABLE = re.compile(r"create\s+table\s+(?:if\s+not\s+exists\s+)?[\"'`]?([a-zA-Z_][\w.]*)", re.IGNORECASE)
RE_TRUNCATE = re.compile(r"truncate\s+(?:table\s+)?[\"'`]?([a-zA-Z_][\w.]*)", re.IGNORECASE)
RE_ADD_COLUMN = re.compile(r"add\s+(?:column\s+)?(?:if\s+not\s+exists\s+)?[\"'`]?(\w+)", re.IGNORECASE)
RE_DROP_COLUMN = re.compile(r"drop\s+(?:column\s+)?(?:if\s+exists\s+)?[\"'`]?(\w+)", re.IGNORECASE)
RE_RENAME_COLUMN = re.compile(r"rename\s+column\s+[\"'`]?(\w+)", re.IGNORECASE)
RE_EDGE_FOLDER = re.compile(r"supabase/functions/([a-zA-Z0-9_-]+)/")

# 0.11.3 : la carte vive nomme les tables SANS schema ("session_hook_tokens",
# jamais "public.session_hook_tokens"). Un DDL qualifie par le schema par
# defaut ne resolvait donc rien (objet inconnu, rapport vide) et le rapport
# l'etiquetait "(colonne)" a cause du point. On retire le prefixe "public."
# seulement ; un autre schema (cron.job, vault.secrets) est garde tel quel,
# il n'est pas dans la carte et reste lisible dans le rapport.
def _nom(m):
    if not m:
        return None
    nom = m.group(1).strip("\"'`")
    if nom.lower().startswith("public."):
        nom = nom[len("public."):]
    return nom

def extraire_objets(texte_nettoye, texte_brut, geste):
    objets = []
    vus = set()

    def ajouter(nom):
        if nom and nom not in vus:
            vus.add(nom)
            objets.append(nom)

    for instruction in texte_nettoye.split(";"):
        if geste == "ddl":
            m = RE_ALTER_TABLE.search(instruction)
            if m:
                table = _nom(m)
                ajouter(table)
                reste = instruction[m.end():]
                # CORRECTION (relecture ergonome du 02/09) : .search() ne
                # rendait que la PREMIERE occurrence de chaque motif -- un
                # ALTER TABLE a plusieurs clauses ADD/DROP COLUMN separees
                # par des virgules perdait silencieusement les colonnes du
                # milieu (confirme en reel : 4 colonnes dans un seul ALTER,
                # seules la 1re et la derniere ressortaient, sans aucun
                # signal de troncature dans le rapport). .finditer() capture
                # TOUTES les occurrences de chaque motif dans l'instruction.
                for rc in (RE_ADD_COLUMN, RE_DROP_COLUMN, RE_RENAME_COLUMN):
                    for mc in rc.finditer(reste):
                        ajouter(f"{table}.{mc.group(1)}")
                continue
            for rc in (RE_DROP_TABLE, RE_CREATE_TABLE, RE_CREATE_FUNCTION, RE_TRUNCATE, RE_DROP_FUNCTION):
                m = rc.search(instruction)
                if m:
                    ajouter(_nom(m))
                    break
        elif geste == "update_delete":
            m = RE_UPDATE_TABLE.search(instruction)
            if m:
                ajouter(_nom(m))
                continue
            m = RE_DELETE_TABLE.search(instruction)
            if m:
                ajouter(_nom(m))

    if not objets:
        m = RE_EDGE_FOLDER.search(texte_brut)
        if m:
            ajouter(m.group(1))

    return objets

# ==========================================================================
# < fichier.sql : lit le fichier reference (borne 200 Ko), l'ajoute au texte
# analyse. Chemin relatif au cwd de l'evenement. Un heredoc, lui, est deja
# inclus tel quel dans `commande` : rien de plus a faire pour lui.
# ==========================================================================

RE_REDIRECTION_FICHIER = re.compile(r"<\s*([^\s;|&]+\.sql)\b")

texte_a_analyser = commande
fichier_lu = None
m_fichier = RE_REDIRECTION_FICHIER.search(commande)
if m_fichier:
    chemin = m_fichier.group(1)
    if not os.path.isabs(chemin) and cwd:
        chemin = os.path.join(cwd, chemin)
    try:
        with open(chemin, "r", encoding="utf-8", errors="replace") as f:
            contenu_fichier = f.read(200 * 1024)
        texte_a_analyser = commande + "\n" + contenu_fichier
        fichier_lu = chemin
    except Exception:
        pass

# 0.11.4 (fil du 03/09/2026) : psql -c "…" / -c '…' / --command=… . Le motif
# DDL est ancre en tete d'instruction (un SELECT ne matche jamais, une prose
# "alter table" dans un echo non plus) : un ALTER passe EN LIGNE a psql etait
# donc invisible, et pire avec des guillemets simples, nettoyer_sql effacant le
# litteral avant le matching. Prouve en reel le 03/09 : psql "postgresql://…"
# -c "ALTER TABLE atoms ADD COLUMN …" = no-match. Correctif : chaque argument
# de -c est extrait AVANT le nettoyage et ajoute comme ligne propre du texte
# analyse, meme traitement que le fichier < x.sql. Marche aussi dans un ssh
# (guillemets echappes \" a l'interieur d'une chaine double). Seulement si la
# commande invoque psql : un `bash -c` ordinaire n'est pas concerne.
RE_PSQL_MOT = re.compile(r"\bpsql\b")
RE_PSQL_C = re.compile(
    r"(?:^|\s)(?:-c|--command)(?:=|\s+)"
    r"(?:\\\"((?:[^\"\\]|\\.)*?)\\\""     # \"…\" (echappe dans un ssh)
    r"|\"((?:[^\"\\]|\\.)*)\""            # "…"
    r"|'((?:[^'\\]|\\.)*)'"               # '…'
    r"|(\S+))",                           # mot nu
    re.DOTALL,
)

# Separateurs de segment shell : le mot psql doit preceder le -c DANS LE
# MEME segment (revue adversariale 0.11.4, defaut confirme : `grep -c
# "alter table" /var/log/psql.log` satisfaisait le gate global \bpsql\b et
# produisait un refus absurde, la famille de faux positifs deja corrigee le
# 02/09 sur npm update / docker restart).
RE_SEPARATEUR_SEGMENT = re.compile(r"&&|\|\||;|\||\n")

def extraire_arguments_psql_c(commande_brute):
    """Rend la liste des arguments de -c/--command dont le segment shell
    contient psql AVANT le -c, guillemets retires et \" desechappes.
    Fonction pure, testable."""
    if not RE_PSQL_MOT.search(commande_brute):
        return []
    resultats = []
    for m in RE_PSQL_C.finditer(commande_brute):
        avant = commande_brute[:m.start()]
        seps = list(RE_SEPARATEUR_SEGMENT.finditer(avant))
        debut_segment = seps[-1].end() if seps else 0
        if not RE_PSQL_MOT.search(avant[debut_segment:]):
            continue
        valeur = next((g for g in m.groups() if g is not None), "")
        valeur = valeur.replace('\\"', '"').strip()
        if valeur:
            resultats.append(valeur)
    return resultats

arguments_c = extraire_arguments_psql_c(commande)

# Nettoyage FRAGMENT PAR FRAGMENT (revue adversariale 0.11.4, defaut
# confirme) : nettoyer_sql apparie les apostrophes sur tout le texte et
# [^'\\] traverse les sauts de ligne ; une apostrophe impaire dans la
# commande (`# l'admin`, `don't`) s'appariait avec la premiere apostrophe de
# la ligne ajoutee et EFFACAIT le DDL, seul endroit ou il est ancre en tete
# de ligne. Chaque argument -c est donc nettoye seul, puis les morceaux
# sont joints.
texte_nettoye = "\n".join([nettoyer_sql(texte_a_analyser)] + [nettoyer_sql(a) for a in arguments_c])

geste = None
sous_type = None
uid_valeur = None

if detecter_ddl(texte_nettoye):
    geste = "ddl"
else:
    risque, sous = detecter_update_delete_risque(texte_nettoye)
    if risque:
        geste = "update_delete"
        sous_type = sous
        if sous == "user_id":
            uid_valeur = extraire_uid_valeur(commande)

if geste is None:
    infra = detecter_infra(commande)
    if infra:
        geste = "infra"
        sous_type = infra

if geste is None:
    echouer()

if geste == "infra":
    objets = [f"infra:{sous_type}"]
else:
    objets = extraire_objets(texte_nettoye, commande, geste)
    if not objets:
        objets = [f"{geste}:non-identifie"]
    # 0.11.4 (revue adversariale, regression confirmee) : un DDL arrive par
    # le wrapper ssh + docker exec + psql etait classe infra:ssh_psql en
    # 0.11.3 (refus aveugle, mais UN SEUL par fil pour toute la forme). Le
    # classer ddl avec objets, sans plus, laissait un second refus infra au
    # premier SELECT ssh suivant, et perdait l'avertissement "acces direct a
    # la base de prod". L'objet infra est donc AJOUTE aux objets du geste :
    # le marqueur du fil le consomme (refus unique tenu), le rapport garde
    # la ligne infra (voir mycelora_reflexe_construire_rapport).
    if detecter_infra(commande) == "ssh_psql":
        objets.append("infra:ssh_psql")

empreinte = hashlib.sha1(
    json.dumps(tool_input, sort_keys=True, ensure_ascii=False).encode("utf-8")
).hexdigest()

sortie = {
    "ok": True,
    "geste": geste,
    "sous_type": sous_type,
    "uid_valeur": uid_valeur,
    "objets": objets,
    "session_id": session_id,
    "cwd": cwd,
    "transcript_path": transcript_path,
    "tool_use_id": tool_use_id,
    "fichier_lu": fichier_lu,
    "empreinte": empreinte,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(sortie, f, ensure_ascii=False)
PYEOF
}

# mycelora_reflexe_grep_local <repo_root_ou_vide> <objets_json> <out_json_path>
# Grep FRAIS (privilégié sur la carte serveur, potentiellement perimee) des
# lecteurs/ecrivains d'une table par recherche `.from('table')` dans le
# depot local, borne a un budget de 2 s (deadline logicielle : `timeout`
# n'existe pas sur macOS, verifiee absente le 02/09). Une colonne
# ("table.colonne") reprend le resultat de sa table.
mycelora_reflexe_grep_local() {
  local repo_root="$1" objets_json="$2" out_path="$3"
  if [ -z "$repo_root" ]; then
    printf '{"resultats": {}, "epuise": false}' > "$out_path"
    return 0
  fi
  python3 - "$repo_root" "$objets_json" "$out_path" <<'PYEOF' 2>/dev/null || printf '{"resultats": {}, "epuise": false}' > "$out_path"
import json, os, re, sys, time

repo_root, objets_json, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    objets = json.loads(objets_json)
except Exception:
    objets = []

deadline = time.monotonic() + 2.0
EXCLUS = {"node_modules", ".git", "dist", "build", ".supabase", ".deno", "coverage"}
EXTS = (".ts", ".tsx", ".js", ".jsx")

tables = sorted({o.split(".")[0] for o in objets if o}, key=len, reverse=True)
resultats = {t: {"lu_par": [], "ecrit_par": []} for t in tables}
motifs = {t: (f".from('{t}')", f'.from("{t}")') for t in tables}

def classifier(contexte):
    return "ecrit" if re.search(r"\.(insert|update|upsert|delete)\s*\(", contexte) else "lu"

epuise = False
for courant, dirs, fichiers in os.walk(repo_root):
    if time.monotonic() > deadline:
        epuise = True
        break
    dirs[:] = [d for d in dirs if d not in EXCLUS and not d.startswith(".")]
    for nom in fichiers:
        if not nom.endswith(EXTS):
            continue
        chemin = os.path.join(courant, nom)
        try:
            with open(chemin, "r", encoding="utf-8", errors="replace") as f:
                lignes = f.read().split("\n")
        except Exception:
            continue
        relatif = os.path.relpath(chemin, repo_root)
        for table, mots in motifs.items():
            for i, ligne in enumerate(lignes):
                if any(mot in ligne for mot in mots):
                    fin = min(i + 4, len(lignes))
                    contexte = "\n".join(lignes[i:fin])
                    cible = classifier(contexte)
                    liste = resultats[table]["ecrit_par" if cible == "ecrit" else "lu_par"]
                    if relatif not in liste:
                        liste.append(relatif)
    if time.monotonic() > deadline:
        epuise = True
        break

resultats_complets = {}
for o in objets:
    base = o.split(".")[0]
    resultats_complets[o] = resultats.get(base, {"lu_par": [], "ecrit_par": []})

with open(out_path, "w", encoding="utf-8") as f:
    json.dump({"resultats": resultats_complets, "epuise": epuise}, f)
PYEOF
}

# mycelora_reflexe_objets_non_resolus <local_json_path> <objets_json> <out_json_path>
# Ecrit le sous-ensemble d'objets sans aucun lu_par/ecrit_par local (candidats
# au fallback serveur).
mycelora_reflexe_objets_non_resolus() {
  local local_path="$1" objets_json="$2" out_path="$3"
  python3 - "$local_path" "$objets_json" "$out_path" <<'PYEOF' 2>/dev/null || printf '[]' > "$out_path"
import json, sys
local_path, objets_json, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(local_path, encoding="utf-8") as f:
        local = json.load(f)
except Exception:
    local = {}
resultats = local.get("resultats") or {}
try:
    objets = json.loads(objets_json)
except Exception:
    objets = []
non_resolus = [o for o in objets if not o.startswith("infra:") and not (resultats.get(o) or {}).get("lu_par") and not (resultats.get(o) or {}).get("ecrit_par")]
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(non_resolus, f)
PYEOF
}

# mycelora_reflexe_lookup_serveur <space_id> <objets_json> <out_resp_path> <cfgfile> <curl_resp_file>
# Construit le corps JSON-RPC mnemos_impact_lookup, appelle mycelora_curl_post
# avec un budget de 4 s, ecrit la reponse brute (ou {} en echec) dans
# out_resp_path. Definit MYCELORA_REFLEXE_LOOKUP_EVT ("" si ok,
# "lookup_timeout" ou "lookup_erreur" sinon) — fail-open : jamais bloquant,
# toujours compte.
mycelora_reflexe_lookup_serveur() {
  local space_id="$1" objets_json="$2" out_resp_path="$3" cfgfile="$4" curl_resp_file="$5"
  local body_file
  body_file="$(mktemp /tmp/mycelora-hook-reflexe-lookup-body.XXXXXX)"
  MYCELORA_REFLEXE_LOOKUP_BODY_FILE="$body_file"

  python3 - "$space_id" "$objets_json" "$body_file" <<'PYEOF' 2>/dev/null
import json, sys
space_id, objets_json, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    objets = json.loads(objets_json)
except Exception:
    objets = []
payload = {
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {"name": "mnemos_impact_lookup", "arguments": {"spaceId": space_id, "identifiants": objets}},
    "id": 1,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF

  mycelora_curl_post "$body_file" "$cfgfile" "$curl_resp_file" 4
  rm -f "$body_file"
  MYCELORA_REFLEXE_LOOKUP_EVT=""

  if [ "${MYCELORA_LAST_CURL_RC:-1}" -ne 0 ]; then
    if [ "${MYCELORA_LAST_CURL_RC:-1}" -eq 28 ]; then
      MYCELORA_REFLEXE_LOOKUP_EVT="lookup_timeout"
    else
      MYCELORA_REFLEXE_LOOKUP_EVT="lookup_erreur"
    fi
    printf '{}' > "$out_resp_path"
    return 0
  fi

  case "${MYCELORA_LAST_HTTP_CODE:-000}" in
    2??)
      if [ -f "$curl_resp_file" ]; then
        cp "$curl_resp_file" "$out_resp_path" 2>/dev/null || printf '{}' > "$out_resp_path"
      else
        printf '{}' > "$out_resp_path"
      fi
      ;;
    *)
      MYCELORA_REFLEXE_LOOKUP_EVT="lookup_erreur"
      printf '{}' > "$out_resp_path"
      ;;
  esac
}

# mycelora_reflexe_construire_rapport <objets_json> <geste> <sous_type> <uid_valeur> <fichier_lu> <lookup_evt> <local_json_path> <server_json_path> <out_report_path> <out_meta_path>
# Combine grep local + reponse serveur (mnemos_impact_lookup) en un rapport
# texte (contrat FIGÉ, brief section 4.2) et un meta {"rapport_vide":bool,
# "lookup_evt":str}.
mycelora_reflexe_construire_rapport() {
  local objets_json="$1" geste="$2" sous_type="$3" uid_valeur="$4" fichier_lu="$5" lookup_evt="$6" local_path="$7" server_path="$8" out_report="$9" out_meta="${10}"
  python3 - "$objets_json" "$geste" "$sous_type" "$uid_valeur" "$fichier_lu" "$lookup_evt" "$local_path" "$server_path" "$out_report" "$out_meta" <<'PYEOF' 2>/dev/null
import datetime, json, re, sys

(objets_json, geste, sous_type, uid_valeur, fichier_lu, lookup_evt,
 local_path, server_path, out_report, out_meta) = sys.argv[1:11]

sous_type = sous_type or None
uid_valeur = uid_valeur or None
fichier_lu = fichier_lu or None
lookup_evt = lookup_evt or None

objets = json.loads(objets_json)

try:
    with open(local_path, encoding="utf-8") as f:
        local = json.load(f)
except Exception:
    local = {}
local_resultats = local.get("resultats") or {}

try:
    with open(server_path, encoding="utf-8") as f:
        server_raw = json.load(f)
except Exception:
    server_raw = {}

server_objets = {}
server_carte_vide = None
server_erreur_outil = False
try:
    result = server_raw.get("result")
    if isinstance(result, dict):
        if result.get("isError"):
            server_erreur_outil = True
        else:
            texte = result["content"][0]["text"]
            payload = json.loads(texte)
            server_carte_vide = payload.get("carteVide")
            for o in payload.get("objets") or []:
                server_objets[o.get("identifiant")] = o
except Exception:
    pass

if server_erreur_outil and not lookup_evt:
    lookup_evt = "lookup_erreur"

def format_date(iso):
    try:
        dt = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return dt.strftime("%d/%m %H:%M")
    except Exception:
        return iso or "?"

def age_jours(iso):
    try:
        dt = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
        maintenant = datetime.datetime.now(datetime.timezone.utc)
        return max(0, int((maintenant - dt).total_seconds() // 86400))
    except Exception:
        return None

def resume_liste(liste, max_affiches=3):
    if not liste:
        return "aucun"
    if len(liste) <= max_affiches:
        return ", ".join(liste)
    return ", ".join(liste[:max_affiches]) + f" (+{len(liste) - max_affiches})"

lignes_objets = []
vide_par_objet = []
# carte_age_jours (S-REFLEXES-5b) : un candidat d'age par objet resolu,
# collecte au fil de la boucle ci-dessous (voir choix documente en
# .claude/v2-decisions/S-REFLEXES-5b.md) : 0 pour une resolution LOCALE
# (grep frais, fraicheur immediate), age_jours(genere_le) pour une
# resolution SERVEUR d'age connu. Un objet inconnu/non resolu ne contribue
# aucun candidat (ne force pas l'absence globale). Le resultat final est le
# MAXIMUM des candidats (le plus defavorable), sauf priorite absolue de
# l'echec de lookup (voir plus bas).
candidats_age = []

for o in objets:
    # 0.11.4 : pseudo-objet infra accompagnant un DDL/UPDATE-DELETE arrive
    # par ssh + docker exec + psql. Pas de carte, pas de grep : une ligne
    # d'avertissement, qui ne compte ni pour rapport_vide ni pour l'age.
    if o == "infra:ssh_psql":
        lignes_objets.append(
            "Objet : accès direct à la base de prod par SSH + docker exec + psql "
            "(hors migration versionnée). Existe-t-il une procédure versionnée à la place ?"
        )
        continue
    loc = local_resultats.get(o) or {}
    lu_local = loc.get("lu_par") or []
    ecrit_local = loc.get("ecrit_par") or []
    # 0.11.3 : "schema.table" n'est pas une colonne. Le prefixe public. est
    # deja retire a l'extraction ; pour un autre schema (cron.job), le
    # premier segment est un schema Postgres connu, pas une table.
    _SCHEMAS = ("public", "cron", "vault", "auth", "storage", "net", "extensions", "pg_catalog", "information_schema", "realtime", "supabase_functions")
    if "." in o and o.split(".", 1)[0].lower() not in _SCHEMAS:
        type_txt = "colonne"
    else:
        type_txt = "table"

    if lu_local or ecrit_local:
        lignes_objets.append(
            f"Objet : {o} ({type_txt}). Lu par : {resume_liste(lu_local)}. "
            f"Écrit par : {resume_liste(ecrit_local)}. (grep local frais)"
        )
        vide_par_objet.append(False)
        candidats_age.append(0)
        continue

    srv = server_objets.get(o)
    if srv is not None and not srv.get("inconnu"):
        lignes_srv = srv.get("lignes") or []
        premiere = lignes_srv[0] if lignes_srv else {}
        type_srv = premiere.get("type") or type_txt
        lu = premiere.get("lu_par") or []
        ecrit = premiere.get("ecrit_par") or []
        rpc = premiere.get("rpc") or []
        section = premiere.get("section_carte") or ""
        genere_le = premiere.get("genere_le")
        age = age_jours(genere_le) if genere_le else None
        if age is not None:
            candidats_age.append(age)
        section_txt = ""
        if section:
            m = re.match(r"^(.*)\s\(l\.(\d+)\)$", section)
            if m:
                section_txt = f" « {m.group(1)} » l.{m.group(2)},"
            else:
                section_txt = f" « {section} »,"
        rpc_txt = f" RPC : {resume_liste(rpc)}." if rpc else ""
        carte_txt = ""
        if genere_le:
            age_txt = age if age is not None else "?"
            carte_txt = f" Carte :{section_txt} générée le {format_date(genere_le)} ({age_txt} j)."
        lignes_objets.append(
            f"Objet : {o} ({type_srv}). Lu par : {resume_liste(lu)}. "
            f"Écrit par : {resume_liste(ecrit)}.{rpc_txt}{carte_txt}"
        )
        vide_par_objet.append(False)
        continue

    if lookup_evt == "lookup_timeout":
        detail = "Carte : indisponible (timeout), grep local : néant."
    elif lookup_evt == "lookup_erreur":
        detail = "Carte : indisponible (erreur), grep local : néant."
    elif server_carte_vide:
        detail = "Carte : jamais indexée pour cet espace, grep local : néant."
    elif srv is not None and srv.get("inconnu"):
        detail = "Inconnu de la carte (jamais vu par le générateur), grep local : néant."
    else:
        detail = "Carte : indisponible, grep local : néant."
    lignes_objets.append(f"Objet : {o} ({type_txt}). {detail} Vérifiez vous-même qui lit {o}.")
    vide_par_objet.append(True)

rapport_vide = all(vide_par_objet) if vide_par_objet else True

# carte_age_jours (S-REFLEXES-5b) : priorite absolue a l'echec REEL de
# l'appel serveur (lookup_timeout/lookup_erreur) -- "absent sur echec",
# meme si par ailleurs un objet a ete resolu localement (candidat 0).
# Sinon, le pire (max) des candidats collectes, ou None si aucun objet
# resolu n'a pu fournir de candidat (rapport entierement construit sur de
# l'inconnu).
if lookup_evt in ("lookup_timeout", "lookup_erreur"):
    carte_age_jours = None
elif candidats_age:
    carte_age_jours = max(candidats_age)
else:
    carte_age_jours = None

if geste == "ddl":
    portee = "Portée : changement de PRODUIT (schéma), tous les comptes."
elif geste == "update_delete":
    if sous_type == "user_id":
        cible = uid_valeur if uid_valeur else "(valeur non extraite, vérifiez la commande)"
        portee = (
            f"Portée : UPDATE/DELETE ciblant user_id {cible} : ceci corrige les données d'UN compte. "
            "Si le défaut vient du produit, où est le correctif produit ?"
        )
    else:
        portee = "Portée : UPDATE/DELETE SANS clause WHERE : toutes les lignes de la table, tous les comptes."
else:
    portee = "Portée : geste à impact large, vérifiez la portée réelle vous-même."

if fichier_lu:
    lignes_objets.append(f"(analysé aussi depuis le fichier lu par redirection : {fichier_lu})")

texte = "\n".join(
    ["RÉFLEXE D'IMPACT (refus unique, rejouez la commande telle quelle si les incidences sont traitées)."]
    + lignes_objets
    + [portee]
)

with open(out_report, "w", encoding="utf-8") as f:
    f.write(texte)
with open(out_meta, "w", encoding="utf-8") as f:
    json.dump({"rapport_vide": rapport_vide, "lookup_evt": lookup_evt, "carte_age_jours": carte_age_jours}, f)
PYEOF

  # CORRECTION (relecture reviewer du 02/09, piege 3 du brief : "fail-open
  # jamais silencieux") : si le bloc python ci-dessus a leve AVANT d'ecrire
  # out_report (JSON invalide en entree, cle inattendue, etc. -- avale par
  # le "2>/dev/null" ci-dessus), out_report resterait un fichier VIDE
  # (cree par mktemp chez l'appelant) et le deny partirait avec un motif
  # vide : jamais acceptable. Repli textuel generique + rapport_vide forcé
  # a true dans le meta, MEME si out_meta lui-meme est illisible.
  if [ ! -s "$out_report" ]; then
    printf '%s' "RÉFLEXE D'IMPACT : geste structurant détecté, incidences non calculables, vérifiez manuellement." > "$out_report"
    python3 - "$out_meta" "$lookup_evt" <<'PYEOF' 2>/dev/null || printf '{"rapport_vide": true, "lookup_evt": null}' > "$out_meta"
import json, sys
out_meta, lookup_evt = sys.argv[1], sys.argv[2]
try:
    with open(out_meta, encoding="utf-8") as f:
        meta = json.load(f)
    if not isinstance(meta, dict):
        meta = {}
except Exception:
    meta = {}
meta["rapport_vide"] = True
if not meta.get("lookup_evt"):
    meta["lookup_evt"] = lookup_evt or None
with open(out_meta, "w", encoding="utf-8") as f:
    json.dump(meta, f)
PYEOF
  fi
  # Meme discipline pour out_meta seul (rapport ecrit mais meta illisible/
  # vide pour une autre raison) : ne jamais laisser un aval bash retomber
  # silencieusement sur "rapport_vide=0" par defaut faute de fichier.
  if [ ! -s "$out_meta" ]; then
    printf '{"rapport_vide": true, "lookup_evt": null}' > "$out_meta"
  fi
}

# mycelora_reflexe_fichier_sensible <file_path>
# Detection PURE (bash, pas de python) niveau 2 (INFORMATION, PostToolUse
# seul) : chemins sensibles du brief section 4.2. Affiche une categorie non
# vide si sensible, rien sinon.
mycelora_reflexe_fichier_sensible() {
  local chemin="${1:-}"
  [ -z "$chemin" ] && return 0
  case "$chemin" in
    */supabase/migrations/*|supabase/migrations/*)
      printf 'migration' ;;
    */supabase/functions/_shared/*|supabase/functions/_shared/*)
      printf 'shared' ;;
    */supabase/functions/*/index.ts|supabase/functions/*/index.ts)
      printf 'edge_index' ;;
    */config.toml|config.toml)
      printf 'config_toml' ;;
    */hooks/*.sh|hooks/*.sh)
      printf 'hook_script' ;;
    */plugin.json|plugin.json)
      printf 'plugin_json' ;;
    */.env|.env|*/.env.*|.env.*)
      printf 'env' ;;
    *)
      return 0 ;;
  esac
}

# mycelora_reflexe_construire_jalon <objets_json> <action_libelle> <local_json_path> <server_json_path> <out_report_path>
# PostToolUse UNIQUEMENT : rapport du jalon apres un geste structurant
# EXECUTE (contrat FIGÉ, brief section 4.2) : "JALON D'IMPACT : <objets>
# <action>. Lecteurs : <résumé>. Lancez le reviewer frais avec ces
# références avant de continuer." local_json_path/server_json_path peuvent
# etre des fichiers vides ({}) quand aucun enrichissement n'a ete tente
# (geste infra, fichier sensible sans objet de schema) : "Lecteurs : aucun
# connu" dans ce cas.
mycelora_reflexe_construire_jalon() {
  local objets_json="$1" action="$2" local_path="$3" server_path="$4" out_path="$5"
  python3 - "$objets_json" "$action" "$local_path" "$server_path" "$out_path" <<'PYEOF' 2>/dev/null
import json, sys

objets_json, action, local_path, server_path, out_path = sys.argv[1:6]
try:
    objets = json.loads(objets_json)
except Exception:
    objets = []

try:
    with open(local_path, encoding="utf-8") as f:
        local = json.load(f)
except Exception:
    local = {}
local_resultats = local.get("resultats") or {}

try:
    with open(server_path, encoding="utf-8") as f:
        server_raw = json.load(f)
except Exception:
    server_raw = {}

server_objets = {}
try:
    result = server_raw.get("result")
    if isinstance(result, dict) and not result.get("isError"):
        texte = result["content"][0]["text"]
        payload = json.loads(texte)
        for o in payload.get("objets") or []:
            server_objets[o.get("identifiant")] = o
except Exception:
    pass

def resume_liste(liste, max_affiches=3):
    if not liste:
        return None
    if len(liste) <= max_affiches:
        return ", ".join(liste)
    return ", ".join(liste[:max_affiches]) + f" (+{len(liste) - max_affiches})"

lecteurs = []
for o in objets:
    loc = local_resultats.get(o) or {}
    lu = list(loc.get("lu_par") or [])
    if not lu:
        srv = server_objets.get(o)
        if srv and not srv.get("inconnu"):
            lignes = srv.get("lignes") or []
            if lignes:
                lu = list(lignes[0].get("lu_par") or [])
    for c in lu:
        if c not in lecteurs:
            lecteurs.append(c)

lecteurs_txt = resume_liste(lecteurs) or "aucun connu"
objets_txt = ", ".join(objets) if objets else "objet non identifié"

texte = (
    f"JALON D'IMPACT : {objets_txt} {action}. Lecteurs : {lecteurs_txt}. "
    "Lancez le reviewer frais avec ces références avant de continuer."
)

with open(out_path, "w", encoding="utf-8") as f:
    f.write(texte)
PYEOF
}

# mycelora_reflexe_marquer_carte_perimee <repo_root_ou_vide> <objets_json>
# Marqueur .carte-perimee (contrat figé) : une ligne JSONL par jalon,
# ajoutee a la racine du depot resolu. Silencieux si repo_root est vide
# (aucun depot local resolu — limite assumee, documentee en decisions).
mycelora_reflexe_marquer_carte_perimee() {
  local repo_root="${1:-}" objets_json="${2:-[]}"
  [ -z "$repo_root" ] && return 0
  python3 - "$repo_root" "$objets_json" <<'PYEOF' 2>/dev/null || true
import json, sys, time
repo_root, objets_json = sys.argv[1], sys.argv[2]
try:
    objets = json.loads(objets_json)
except Exception:
    objets = []
ligne = {"t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "objets": objets}
try:
    with open(f"{repo_root}/.carte-perimee", "a", encoding="utf-8") as f:
        f.write(json.dumps(ligne, ensure_ascii=False) + "\n")
except Exception:
    pass
PYEOF
}
