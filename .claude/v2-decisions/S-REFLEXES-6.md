# STORY-S-REFLEXES-6 — le jeton de session hook, contexte marketplace

Contexte 2 (marketplace, hooks bash) uniquement. Le contexte 1 (edge-function,
migration + `identity.ts`/`index.ts`/`tools.ts`) est traité séparément dans
l'autre worktree (`edge-function-worktrees/s-reflexes`, déjà mergé, commit
f04851a) : le contrat serveur qu'il expose (401 typé
`error.data.code === "jeton_session_expire"`, `authLevel: "hook"`, format
exact de la ligne `[jeton-hook-session ...] mk_sess_...`) a été pris FIGÉ tel
que décrit dans le brief, sans le revérifier moi-même.

Worktree `evidencai-marketplace-worktrees/s-reflexes`, branche
`feat/reflexes-senior` (déjà à jour avec `main` 0.10.4, `git merge` fait par
l'orchestrateur avant mon entrée en jeu). Codeur = Sonnet 5, code direct.

## Conséquence assumée, EXPLICITE : les quatre hooks sont inertes avant le
## premier `mnemos_session_start` du fil (y compris PreToolUse)

Le contrat de la story place `mycelora_resolve_hook_token` + le cas
`sans-jeton` (`exit 0`, aucun appel réseau) JUSTE APRÈS que `SESSION_ID` et
`TRANSCRIPT_PATH` soient connus, AVANT toute autre logique — y compris, dans
`mycelora-pretooluse.sh`, avant le calcul de `DURATION_MS` et le test `OK`
qui décide si un geste structurant a été détecté. Résultat : sur un fil
marketplace qui n'a jamais appelé `mnemos_session_start`, le réflexe
d'impact de PreToolUse ne refuse RIEN, y compris un `ALTER TABLE` ou un
`DELETE FROM ... ` sans `WHERE` — aucune exception nommée pour ce hook dans
le brief ni dans la story.

C'est un changement de comportement PAR RAPPORT AU CANAL ZIP D'AUJOURD'HUI :
là, un jeton toujours présent (même invalide, `mk_live_...` révoqué ou
inconnu) produisait un refus local classique (rapport construit localement
sans appel réseau réussi, ou un 401 générique loggé mais le refus a quand
même lieu car la détection Bash/DDL est TOTALEMENT indépendante de la
résolution du jeton dans le code actuel). Avec S-REFLEXES-6, l'ABSENCE de
jeton court-circuite la détection elle-même, avant même qu'elle commence.

Le DoD de la story l'exige texto (« transcript sans session_start,
sans-jeton, aucun appel réseau, exit 0 », sans exception nommée pour
PreToolUse) et le brief le redit explicitement en interdisant de déplacer
l'insertion plus bas pour « optimiser » ce chemin. Je n'ai donc PAS
contourné ce point de moi-même — je le signale ici et dans mon rapport final
pour que Stéphane le voie et tranche si besoin (ex. : garder PreToolUse actif
même sans jeton résolu, en le faisant échouer seulement à l'appel réseau
plutôt qu'avant la détection). Testé et vérifié : `sans-jeton-pretooluse`
dans `run-unit-tests.sh` (ALTER TABLE détecté normalement dans un transcript
QUI CONTIENT un `session_start` réel, mais un transcript SANS
`session_start` ne refuse rien du tout, log `auth`/`sans-jeton`).

## Contrat de test : injecter une fausse valeur globale, pas modifier les 93
## fixtures existantes

Les 93 tests unitaires préexistants (`run-unit-tests.sh`) ont été écrits
avant cette story et ne portent AUCUNE ligne de jeton dans leurs transcripts
(`transcript-session-start.jsonl` etc.). Avec le nouveau gating
(`mycelora_resolve_hook_token` + sortie `sans-jeton` en tête de chaque hook),
tous ces tests auraient dû échouer en régression pure (plus aucun appel
curl, faute de jeton résolu) — ce que le brief interdit explicitement
(« Suite ENTIÈRE des 93 tests existants doit rester verte »).

Résolu en exportant GLOBALEMENT, en tête de `run-unit-tests.sh`,
`CLAUDE_PLUGIN_OPTION_HOOK_KEY="mk_live_TESTFAKE0000000000000000"` — une
valeur non vide et différente du placeholder `__MYCELORA_HOOK_KEY__`, qui
satisfait la PRIORITÉ 1 du contrat de `mycelora_resolve_hook_token` (« zip
substitué, gardée telle quelle ») pour tous les tests qui ne s'occupent pas
spécifiquement du jeton. Cette priorité-1 est un retour immédiat qui NE
touche jamais le cache v3 (`_mycelora_charger_fil` n'est même pas appelée),
donc aucune interférence avec les autres résolutions déjà faites par ces
mêmes tests (`mycelora_resolve_space_id`/`mycelora_resolve_etiquettes`, qui
continuent d'utiliser le même cache par ailleurs).

Les tests dédiés au canal marketplace (sans-jeton, priorités de résolution,
401 typé sur PreToolUse/PostToolUse) unsetent
`CLAUDE_PLUGIN_OPTION_HOOK_KEY` LOCALEMENT, dans un sous-shell dédié à
l'invocation testée, pour retomber sur la résolution réelle (cache v3 ou
vide) sans jamais toucher à la variable globale du reste de la suite.

## Session ids dédiés, pas de réutilisation de `726ec160-...`

La majorité des fixtures existantes partagent le même `session_id`
(`726ec160-e1f5-5bd0-b3e7-3de9785ea2be`), ce qui construit un cache partagé
entre elles au fil de la suite (déjà documenté dans le fichier — piège payé
au fil 76). Pour ne prendre aucun risque de pollution croisée avec le
nouveau champ `hookToken` du cache v3, toutes les fixtures et tests neufs de
cette story utilisent des `session_id` synthétiques dédiés
(`s-reflexes-6-*`), nettoyés explicitement (`rm -f
/tmp/mycelora-hook-s-reflexes-6-*.json`) en fin de section.

## `extraire_jeton` : test direct par extraction du code source réel, pas une
## réimplémentation

La fonction vit dans le heredoc python de `_mycelora_charger_fil` (pas un
module important). Pour la tester DIRECTEMENT (règle 8bis : « c'est CETTE
fonction qui reçoit la contre-épreuve par mutation ») sans dupliquer sa
logique dans le test (ce qui aurait rendu la contre-épreuve par mutation
inopérante — muter le fichier source n'aurait alors touché aucun test), le
script de test EXTRAIT le bloc source réel (`_RE_JETON = re.compile(...)`
jusqu'à `modifie = False`, deux ancres textuelles uniques dans le fichier) et
l'exécute isolément avec des cas positifs/négatifs. Fragile en théorie (si
une future édition renomme ces ancres, le test casse à l'extraction plutôt
qu'à l'assertion) mais c'est le prix pour tester le VRAI code, pas une copie
qui dérive.

Le premier jeu de cas négatifs ne suffisait PAS à faire tomber la mutation
« ancrage `^`/`$` retiré » suggérée par le brief : les cas choisis (pas de
ligne, ligne mal formée sans espace, jeton sans préfixe bracket) échouaient
tous pour d'autres raisons que l'ancrage (absence du préfixe littéral,
absence de l'espace `\s+`), donc restaient `None` avec OU sans les ancres.
Ajouté un cas dédié pour rendre CETTE mutation spécifique observable : une
ligne `[jeton-hook-session x] mk_sess_TRAILING1234 et voici du texte en
plus` — avec les ancres (code réel), rejetée entièrement (`None`, la ligne
n'est pas EXCLUSIVEMENT le jeton) ; sans elles (mutation), `findall` accepte
quand même le préfixe du match et rend `mk_sess_TRAILING1234`. Contre-épreuve
faite et confirmée : rouge sur ce cas précis avec la mutation appliquée via
l'outil d'édition, vert après restauration (jamais par une commande git).

## Offset : fixture non commitée, construite au runtime par `printf`

Le brief demande une fixture dont la DERNIÈRE ligne n'est PAS terminée par
`\n`, « construite avec printf, jamais touchée par un éditeur qui rajouterait
le retour ». Un fichier de ce type est fragile à committer tel quel (un
éditeur, un hook de formatage, ou même `git` selon la configuration locale
peut renormaliser la fin de fichier) : construite à la place DANS
`run-unit-tests.sh`, à l'exécution, via deux `printf` successifs (le second
sans `\n` final), jamais écrite sur disque comme fixture versionnée. Le
fichier temporaire est nettoyé en fin de test.

## `mycelora_reflexe_lookup_serveur` : vérification du 401 typé faite
## LOCALEMENT dans `posttooluse.sh`, `DURATION_MS` recalculé sur place

Le brief demandait la vérification locale (pas dans la fonction partagée de
`mycelora-common.sh`, pour ne rien changer à `mycelora-pretooluse.sh`) ; fait
tel quel, aux deux sites d'appel. Point non couvert littéralement par le
brief : à ces deux points d'insertion, `DURATION_MS` n'existe pas encore
dans `mycelora-posttooluse.sh` (il n'est calculé qu'à la toute fin, après la
construction du jalon) — l'utiliser tel quel aurait cassé le script sous
`set -u` (variable non liée). Recalculé une mesure de durée locale
(`AUTH_DURATION_MS`, même idiome `time.time() - START_MS` déjà utilisé
partout ailleurs dans ce fichier pour un log à mi-parcours) à chaque site
d'appel, plutôt que de réutiliser un `DURATION_MS` qui n'existe pas encore à
cet endroit du script. Comportement du jalon strictement inchangé (le log
`auth`/`jeton-expire` est un ajout pur, best-effort, avant la suite normale
du flux).

## `mktemp` : piège de template sur macOS (`X...` pas en fin de chaîne)

Premier essai de script python temporaire pour `extraire_jeton` :
`mktemp /tmp/mycelora-test-extraire-jeton.XXXXXX.py`. Sur le `mktemp` BSD de
cette machine, les `X` ne sont substitués QUE s'ils terminent le template —
ici suivis de `.py`, ils restent littéraux, et l'appel échoue
silencieusement en `mkstemp failed: File exists` dès la deuxième exécution
(la première crée le fichier littéral `...XXXXXX.py`). La variable capturait
alors soit une chaîne vide soit le message d'erreur selon l'ordre
d'exécution, d'où un run flaky observé une fois sur trois avant correction
(`python3 "$SCRIPT"` avec `$SCRIPT` vide se plaint de ne pas trouver
`__main__` dans le répertoire courant). Corrigé en retirant le suffixe
`.py` du template (l'extension ne sert à rien pour `python3 chemin`).

## Zip ET jeton de session en même temps : testé en DIRECT sur la fonction,
## pas via capture d'en-tête HTTP

Le faux `curl` de test ne capture que `-o`/`--data-binary` (le corps), pas
les en-têtes du fichier `-K` (donc pas la valeur de `Authorization` reçue).
Vérifier que le jeton substitué « gagne » quand le cache v3 porte AUSSI un
`hookToken` (différent) n'a donc pas de sens à travers un hook complet + curl
factice : testé directement sur `mycelora_resolve_hook_token` (source de
`mycelora-common.sh` dans un sous-shell, cache v3 pré-rempli à la main avec
une valeur volontairement différente de celle attendue), comme les trois
priorités du contrat. Plus simple, et couvre exactement l'assertion demandée
(quelle VALEUR ressort dans `MYCELORA_HOOK_TOKEN`), sans avoir à étendre le
faux `curl` pour un seul test.

**MIS À JOUR par le correctif F1 ci-dessous (02/09, post-revue) : le premier
paragraphe (« le faux curl ne capture que -o/--data-binary ») n'est plus
vrai** — le faux `curl` capture désormais aussi le fichier `-K` via
`MYCELORA_TEST_CAPTURE_CFG`. Ce test-ci (`mycelora_resolve_hook_token` en
direct) reste néanmoins la bonne façon de couvrir CETTE assertion précise
(quelle valeur gagne entre le zip substitué et le cache v3), et n'a pas été
retouché : le nouveau mécanisme `-K` sert aux tests F1 (bearer réellement
envoyé par les quatre hooks), une question différente (est-ce que la valeur
résolue part bien sur le fil), pas remplacée par lui.

## Fichiers de production restés hors périmètre (signalés, pas devinés)

`plugins/mon-greffier/` et son entrée dans `marketplace.json` : non touchés,
seule l'entrée `mycelora` et `plugins/mycelora/` sont dans le périmètre de
cette story. `run-integration-tests.sh` (appels réseau réels contre un jeton
`mk_live_` de prod) : lu en entier avant de décider — il n'utilise ni
`MYCELORA_HOOK_TOKEN` ni `mycelora_resolve_hook_token` (son propre flux
d'authentification, `TOKEN_CONTENT` lu depuis un fichier local), donc non
concerné par cette story, non modifié, non exécuté (geste réseau réel, hors
de ce que je dois faire).

## Non fait, à trancher par Stéphane

La révocation de la clé `mk_live_INu4gIVs` embarquée dans le zip 0.10.2 :
hors périmètre explicite de la story (« à faire par Stéphane quand le canal
marketplace vit »), non touchée. La preuve « exemplaire réel » de bout en
bout par la marketplace (plugin 0.11.0 livré, fil Cowork réel, `raw_exchanges`
et `last_used_at` en base) est un geste de Phase 4 explicitement hors de ma
mission (brief section « Vérification avant de rendre la main » : seuls
`run-unit-tests.sh`/`run-integration-tests.sh`/mutation/v2-decisions sont
attendus de moi côté marketplace).

## Correctifs post-revue adversariale (02/09/2026, cinq points)

Revue reçue après la première implémentation, sur ce même worktree, avant
tout commit. Cinq correctifs, tous appliqués :

### F1 (MEDIUM) — le bearer réellement envoyé n'était jamais vérifié

Constat exact de la revue : le faux `curl` de `run-unit-tests.sh` ne parsait
que `-o`/`--data-binary` (le corps JSON-RPC), jamais le contenu du fichier
`-K` (qui porte `header = "Authorization: Bearer ..."`, construit par
`mycelora_curl_post`). Aucun test n'assérait donc que les hooks envoient
réellement `Bearer mk_sess_...` — le mécanisme central de la story n'était
vérifié que côté RÉSOLUTION (`mycelora_resolve_hook_token`), jamais côté
TRANSPORT.

Corrigé en étendant le faux `curl` (case `-K`, capture du fichier de config
entier dans `MYCELORA_TEST_CAPTURE_CFG`, même convention que
`MYCELORA_TEST_CAPTURE_BODY`), puis en ajoutant six tests dédiés qui lancent
le VRAI script de chaque hook (jamais une réimplémentation) et vérifient que
la ligne `Authorization` capturée est EXACTEMENT
`header = "Authorization: Bearer mk_sess_FIXTURE0123456789"` :
`ups-bearer-reellement-envoye-cache-v3`, `stop-bearer-reellement-envoye-cache-v3`,
`pretooluse-bearer-reellement-envoye-cache-v3`,
`posttooluse-bearer-reellement-envoye-cache-v3` (les deux derniers vérifient
le point d'appel réseau réel du réflexe d'impact,
`mycelora_reflexe_lookup_serveur` → `mycelora_curl_post`, avec une réponse
200 — pas le test 401 déjà existant, qui ne prouvait que le comportement de
refus/log, pas le bearer).

**Piège trouvé et corrigé en même temps, plus grave que F1 lui-même** : une
FOIS le faux `curl` du haut du fichier étendu, les six nouveaux tests
échouaient quand même, bearer capturé vide. Cause : `run-unit-tests.sh`
contient une SECONDE écriture du faux `curl` (`~ligne 1090`, commentée
« Restaure le faux curl "normal" pour la suite des tests »), utilisée après
un test qui simule un serveur muet (timeout) en remplaçant temporairement le
faux `curl`. Cette « restauration » était une COPIE FIGÉE, antérieure à mon
ajout de la capture `-K` — donc TOUTE la suite de tests exécutée après ce
point (la quasi-totalité du fichier, dont l'intégralité de la section
S-REFLEXES-6 existante) tournait avec un faux `curl` qui ne savait PAS
capturer le bearer, alors même que le générateur du haut du fichier, lui,
le savait. Corrigé en répercutant le même ajout (`-K` + capture) dans cette
seconde écriture ; les deux générateurs doivent désormais rester
identiques. Sans ce second correctif, les tests F1 auraient semblé
« démontrer » l'absence de bug alors qu'ils ne testaient tout simplement
rien (`cfg=''` silencieux) — piège découvert par investigation empirique
(comptage des invocations réelles du faux `curl` vs. nombre d'appels
`mycelora_curl_post`, écart de moitié, tracé jusqu'à cette réécriture).

### F2 — fixture `stdin-stop-jeton.json` désormais utilisée

Réutilisée telle quelle (créée à l'origine mais orpheline) par le nouveau
test `stop-bearer-reellement-envoye-cache-v3` (F1 ci-dessus).

### F5 (LOW) — fenêtre d'exposition sur le fichier cache `.tmp`

Dans `_mycelora_charger_fil`, remplacé `open(tmp_path, "w")` + `os.chmod`
séparé par `os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)`
suivi de `os.fdopen(fd, "w")` : le fichier est désormais créé DIRECTEMENT en
0600, sans fenêtre où il existerait sous l'umask par défaut. `try/except`
existant conservé tel quel autour de cette section.

### F6 (LOW) — `extraire_jeton` acceptait un jeton à cheval sur deux lignes

`_RE_JETON` resserré : `\s+`/`\s*` (qui traversent `\n` en mode
`re.MULTILINE`) remplacés par `[ \t]+`/`[ \t]*` ; `re.MULTILINE` et
l'ancrage `^...$` par ligne conservés. Cas ajouté au test direct
`extraire-jeton-direct-cas-positifs-negatifs` :
`"[jeton-hook-session x]\nmk_sess_CROSSLINE"` → `None` (avant le correctif :
`"mk_sess_CROSSLINE"`, à tort). Contre-épreuve par mutation refaite pour ce
changement précis (la fonction touchée est la même que celle déjà couverte
par la contre-épreuve précédente) : régression manuelle de la regex vers
`\s+`/`\s*`, confirmé rouge (`FAIL:jeton_a_cheval_sur_deux_lignes: attendu=None
obtenu='mk_sess_CROSSLINE'`, 115/116), restauration, confirmé vert (116/116).

### Exemplaire réel — `scripts/preuve-jeton-session-reelle.sh`

Script autonome à la racine du dépôt (pas un test unitaire parmi d'autres,
un démonstrateur narré). Reprend le transcript réel
`transcript-session-start-avec-jeton.jsonl`, met en place le même faux
`curl` que les tests unitaires (aucun mock de bash, juste `curl` en tête de
`PATH`), puis lance RÉELLEMENT les quatre vrais scripts de hooks contre ce
transcript, affiche pour chacun le bearer effectivement capturé, puis simule
un 401 `jeton_session_expire` et relance `mycelora-userpromptsubmit.sh` pour
afficher la ligne de relance produite. Sortie complète d'une exécution réelle
committée dans `scripts/preuve-jeton-session-reelle.OUTPUT.txt` — c'est cet
artefact, pas un résumé, qui est joint au signal de fin de story.

Point trouvé en le faisant tourner une première fois : `mycelora-posttooluse.sh`,
en conditions réelles (vraie racine de dépôt en `cwd`, pas un `cwd` bidon),
pose réellement `.carte-perimee` à la racine du dépôt (comportement de
PRODUCTION correct — le jalon d'impact marque la carte comme périmée après
un geste structurant). Comme ce fichier n'est pas un artefact du DoD, le
script le nettoie dans son `trap cleanup` pour rester rejouable sans laisser
de trace non versionnée dans le worktree.

### Vérification faite

`run-unit-tests.sh` relancé six fois au total pendant ce correctif (3 avant
la découverte du piège de la double écriture du faux `curl`, en échec sur
les 4 nouveaux tests F1 ; 3 après le second correctif, toutes vertes) :
116/116 à chaque fois après correction, aucune instabilité observée sur les
tests `reflexe-stop-*`/S-REFLEXES-5b évoquée par la revue précédente (peut-
être spécifique à d'autres conditions d'exécution — signalé tel quel, pas
recherché plus loin, hors périmètre de ce correctif).
