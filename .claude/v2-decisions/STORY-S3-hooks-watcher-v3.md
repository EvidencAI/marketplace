# Décisions tactiques — STORY S3 hooks watcher v3

Choix d'implémentation non évidents, non couverts mot à mot par la story, tranchés pendant l'exécution. Aucune décision produit : uniquement des choix techniques d'implémentation.

## Troisième passage : relecture croisée FIX-S3-RELECTURE.md (4 points)

1. **Majeur — find_last_user perdait la quasi-totalité des échanges réels.** Réécrit avec un algorithme à deux candidats collectés en une seule passe (pas d'arrêt sur la dernière entrée user tout court) : (a) dernière entrée `type=user` dont `promptId` (champ racine du JSONL) == `prompt_id` du stdin ET `message.content` est une string ; (b) repli, dernière entrée `type=user` à `message.content` string, sans condition de promptId. Les entrées à `content` liste (tool_result) ne sont plus jamais des points d'arrêt, seulement des non-candidats. `prompt_id` est désormais extrait du stdin (3e ligne de META_OUT).
2. **Moyen — isError ignoré, risque d'injecter un message d'erreur edge dans le contexte.** `mnemos-userpromptsubmit.sh` vérifie désormais `result.isError` avant d'écrire quoi que ce soit sur stdout ; si vrai, sortie vide et statut de log distinct `tool-error` (au lieu de `ok`/`empty`).
3. **Moyen — motif "Rappel interne :" absent des filtres.** Un wakeup `send_later` ne porte le préfixe `[SYSTEM NOTIFICATION - NOT USER INPUT]` qu'au niveau conversationnel du modèle, jamais au niveau des hooks (ni stdin.prompt, ni transcript). Ajouté aux deux hooks (sur le texte trimmé, cohérence avec le fix de trim du passage précédent) : `startswith("Rappel interne :")`. Limite documentée en commentaire : un wakeup au libellé libre passe quand même.
4. **Mineur optionnel — plafond de la query recall à 2000 caractères.** Aucune contre-indication trouvée dans `lib/embeddings.ts` (pas de troncature côté edge, appel direct à Voyage AI). Appliqué : la valeur envoyée en `query` est tronquée à 2000 caractères, le prompt original (utilisé pour le filtrage) n'est pas modifié.

**Effet de bord assumé sur `stdin-stop-missing-user` / `transcript-missing-last-user.jsonl` (fixture non modifiée).** Ce fixture contient un vrai message user en tête d'échange ("lance la commande de build stp") suivi d'un tool_result en dernière ligne. Sous l'ANCIEN algorithme (bug corrigé au point 1), ce message était perdu à tort (MISSING). Sous le NOUVEL algorithme (repli b, remontée de l'historique), il est légitimement retrouvé : ce n'est donc plus un cas "MISSING" mais un cas de repli réussi, et l'assertion du test associé (`mnemos-stop-13`) a été mise à jour en conséquence (curl attendu, userMessage vérifié). Conséquence : plus aucune fixture fournie ne couvre réellement le chemin retry-puis-abandon (MISSING) une fois le fix appliqué. Un cas synthétique `mnemos-stop-truly-missing-synthetic` a été ajouté dans `run-unit-tests.sh` (transcript généré à la volée, sans aucune entrée user à content string) pour ne pas perdre la couverture de ce chemin.

## Second passage : 7 corrections post-revue (commit de correction)

Après revue et tests d'exécution réels par le coordinateur (recall/log_exchange/outil interdit/port fermé réellement testés en 4/4 vert), 7 corrections ont été appliquées en diff chirurgical direct sur les fichiers déjà générés :

1. **Extraction du jeton cassée** : `HOOK-KEY.txt` porte 3 lignes de commentaire (`#...`) avant la ligne du jeton. `f.read().strip()` capturait tout le fichier, pas seulement le jeton — le zip produit par `build-plugin-zip.sh` aurait été non fonctionnel en prod. Corrigé dans `build-plugin-zip.sh` et `run-integration-tests.sh` : lecture ligne par ligne, ignore les lignes vides et celles commençant par `#`, prend la première ligne valide restante.
2. **Fichiers porteurs du jeton/PII non couverts par un kill signal** : `trap cleanup_and_exit EXIT` ne se déclenche pas sur un SIGTERM non piégé (Cowork tue les hooks vers 9-10s). Étendu en `trap cleanup_and_exit EXIT INT TERM` dans les deux hooks. `mnemos_curl_post` (mnemos-common.sh) ne crée plus ses propres cfgfile/resp_file en interne : elle reçoit désormais ces chemins en arguments, créés et enregistrés dans `CLEANUP_FILES` par l'appelant AVANT l'appel curl, pour qu'un kill en plein appel réseau déclenche quand même leur suppression via le trap du script appelant. Même principe dans `run-integration-tests.sh` (`mnemos_secure_curl`) via un `trap 'rm -f "$cfgfile"' RETURN` local à la fonction.
3. **Cache spaceId non atomique / sans repli si corrompu** : écriture désormais dans un fichier `.tmp` puis `os.replace()` (atomique). Si la lecture du cache existant échoue (JSON invalide, fichier tronqué), la fonction ne retourne plus `""` immédiatement : elle retombe sur le parsing du transcript comme si le cache n'existait pas.
4. **Incohérence trim entre filtre de longueur et filtres de préfixe** : `len(trimmed) < 10` utilisait `prompt.strip()` mais les `startswith(...)` testaient le prompt brut, laissant passer un prompt précédé d'un espace/saut de ligne. Tous les `startswith(...)` utilisent désormais `trimmed` (le test `"<task-notification>" in prompt` reste sur le brut, un `in` n'est pas sensible à un espace de tête). Même correction sur le filtre système de `mnemos-stop.sh`.
5. **Message vide archivable au Stop** : ajout d'une vérification juste avant construction du body JSON-RPC — si `userMessage` ou `assistantResponse` est vide après trim, log `empty-message` et `exit 0` sans appel réseau (l'edge ne valide rien côté serveur sur ces champs).
6. **Assertion "outil interdit" trop faible** : `run-integration-tests.sh` vérifiait seulement la présence d'une clé `error` générique. Resserré : vérifie que `error.code == -32601` ou que `error.message` contient `"not allowed for hook token"`.
7. **PII affichée dans le test d'intégration recall** : `test_recall` affichait jusqu'à 200 caractères du bloc FACE-A réel (contenu mémoire potentiellement sensible) sur stdout. Remplacé par une sortie non sensible (nombre de caractères uniquement, jamais le contenu).

Vérifications manuelles ciblées après correction (en plus des 15/15 tests unitaires) : cache atomique sans résidu `.tmp`, repli correct sur un cache corrompu, `empty-message` loggé sans appel réseau sur assistant vide, filtre `<system-reminder>` précédé d'un espace de tête désormais bien filtré.

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
