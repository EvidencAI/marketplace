# Décisions tactiques — STORY S3 hooks watcher v3

Choix d'implémentation non évidents, non couverts mot à mot par la story, tranchés pendant l'exécution. Aucune décision produit : uniquement des choix techniques d'implémentation.

## Algorithme "dernier message user" au Stop (mnemos-stop.sh)

Point ambigu dans la spec technique : "le dernier message dont type=='user' ET content est une string". Deux lectures possibles :
1. Scanner tout le fichier et garder la dernière entrée qui satisfait CONJOINTEMENT les deux conditions (permet de remonter loin en arrière si la toute dernière entrée user est un tool_result).
2. Trouver la dernière entrée de type "user" (peu importe la forme du content), puis exiger que CETTE entrée précise ait un content de type string ; sinon, aucun message trouvé (pas de repli sur une entrée plus ancienne).

Vérifié empiriquement contre les 5 fixtures transcript-*.jsonl fournies (notamment transcript-missing-last-user.jsonl, qui contient une première entrée user texte suivie d'un tool_use puis d'un tool_result, et qui DOIT produire "no-user-message" selon la spec) : seule la lecture n°2 reproduit le comportement attendu sur les 5 fixtures. La lecture n°1 aurait retourné le texte de la première entrée (ancienne) au lieu de "missing" pour cette fixture. Implémenté selon la lecture n°2.

## Mesure de durée (duration_ms) portable macOS/Linux

`date +%s%N` (nanosecondes) n'existe pas sur macOS/BSD (seulement GNU date). Utilisé `python3 -c "import time; print(int(time.time()*1000))"` avant/après chaque étape mesurée, dans les 3 scripts hooks et dans run-integration-tests.sh, pour un calcul de durée en millisecondes qui fonctionne identiquement sur le Mac de dev et la VM cloud (Linux).

## MNEMOS_HOOK_TOKEN défini dans les scripts appelants, pas dans mnemos-common.sh

Le test unitaire imposé par la story vérifie la présence littérale de `__MNEMOS_HOOK_KEY__` dans hooks.json, mnemos-userpromptsubmit.sh et mnemos-stop.sh (voir divergence signalée plus bas concernant hooks.json). Pour que les DEUX scripts .sh portent réellement le placeholder (et pas seulement le fichier commun sourcé), la constante `MNEMOS_HOOK_TOKEN="__MNEMOS_HOOK_KEY__"` est déclarée séparément en tête de mnemos-userpromptsubmit.sh ET de mnemos-stop.sh (légère duplication assumée), tandis que la fonction `mnemos_curl_post` (dans mnemos-common.sh) se contente de lire cette variable globale déjà positionnée par l'appelant. `build-plugin-zip.sh` remplace le placeholder dans tous les `hooks/*.sh`, donc les deux occurrences sont injectées correctement au build.

## Sécurité : jeton jamais en argument, même pour python3

La contrainte "jamais le jeton en argument curl visible" a été étendue par cohérence à `build-plugin-zip.sh` : le remplacement du placeholder par python3 ne reçoit jamais le jeton en argument de ligne de commande (visible dans `ps aux`), seulement le CHEMIN d'un fichier temporaire chmod 600 contenant le jeton, supprimé immédiatement après usage.

## run-integration-tests.sh : bug corrigé sur la mesure du cas "port fermé"

Le premier jet généré utilisait `http_code="$(curl ... || echo "N/A")"`. Ce pattern est cassé : quand curl échoue après avoir déjà écrit "000" sur stdout (via `-w '%{http_code}'`), le `||` déclenche AUSSI `echo "N/A"`, et les deux sorties se concatènent dans la capture (`"000N/A"` au lieu de `"N/A"`), faussant la comparaison qui suit. Vérifié empiriquement en isolant la commande. Corrigé en capturant explicitement `curl_rc=$?` séparément du corps de sortie, et en basant le verdict PASS/FAIL sur `curl_rc` plutôt que sur une comparaison de chaîne.

## run-unit-tests.sh : bugs corrigés après génération

Deux bugs bloquants trouvés après première génération et test réel :
1. `set -euo pipefail` combiné à des appels `assert "..."` en instruction nue faisait avorter tout le script au premier test en échec (`set -e` tue le script dès qu'une commande simple retourne non-zéro). Remplacé par `set -uo pipefail` (sans `-e`), chaque appel `assert` est maintenant explicitement suivi de `|| FAILED_TESTS=$((FAILED_TESTS+1))`.
2. Le comptage final faisait `grep -c "^PASS" "$0"` — comptait les occurrences du mot PASS dans le CODE SOURCE du script lui-même, pas les résultats d'exécution réels. Remplacé par des compteurs `TOTAL_TESTS`/`FAILED_TESTS` incrémentés à l'exécution.
3. `local cleanup_temp() { ... }` (déclaration de fonction locale) est une syntaxe bash invalide, faisait planter le script avant même le premier test. Remplacé par `trap 'rm -rf "$temp_dir"' RETURN` (trap sur retour de fonction, propre à chaque invocation de `assert`).
4. La vérification du nom d'outil JSON-RPC attendu (`mnemos_recall` vs `mnemos_log_exchange`) ne couvrait que 2 noms de test en dur (`mnemos-userpromptsubmit-2`, `mnemos-stop-10`), faisant échouer à tort `mnemos-stop-14`. Remplacé par un `case "$test_name" in mnemos-stop-*) ... *) ... esac` générique basé sur le préfixe du nom de test.

Ces 4 corrections ont été faites directement (diff chirurgical sur fichier existant généré), pas via une nouvelle régénération complète par Qwen, conformément à la règle de routing (petit diff précis dans un fichier déjà produit).
