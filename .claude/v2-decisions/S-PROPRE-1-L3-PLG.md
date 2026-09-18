# S-PROPRE-1-L3-PLG : décision et mesures (18/09/2026)

Story : renommage mnemos → mycelora du plugin Cowork, lots 3 et 4, plugin
0.13.0. Branche `feat/s-propre-1-renommage`, base `origin/main` fdf3e39.
PR à NE PAS MERGER SEULE (merge pendant la bascule, après le serveur).

## 1. Référence et fin de story

| | Référence fdf3e39 | Fin de story (94ec255) |
|---|---|---|
| `run-unit-tests.sh` | rc=0, `140/140 tests passes`, 140 PASS, 0 FAIL | rc=0, `142/142 tests passes`, 142 PASS, 0 FAIL |
| `preuve-jeton-session-reelle.sh` | rc=0, 108 lignes, « PREUVE TERMINEE, TOUT CONFORME. » | rc=0, 108 lignes, identique après normalisation |

Tests ajoutés (+2, nommés) : `capture-jeton-rupture-franche-ancien-nom-refuse`
(T2) et `noms-outils-envoyes-au-serveur-exactement-mycelora` (T1). Les 140
noms de la référence sont tous présents en fin de story (diff des noms
triés : seulement ces deux ajouts). Runs isolés, jamais deux en même temps.

Preuve jeton, écart après normalisation (`s/mnemos/mycelora/g` et casses) :
seulement les l.30-31, chemin `mktemp` aléatoire du faux curl
(`/var/folders/.../tmp.XXXXXXXXXX/bin/curl`).

## 2. Commits

| # | SHA | Objet | Preuve |
|---|---|---|---|
| C1 | 4cb4eb2 | lot 3 : hooks et miroirs appellent `mycelora_*`, capture sur `mycelora_session_start` | RENOMMAGE PUR, 140/140 |
| C2 | c7f47ef | lot 3 : contre-épreuves T1 et T2 (ajouts seuls) | 142/142, M1 à M5 |
| C3 | 17fb685 | lot 3 : tests d'intégration (3 noms) | RENOMMAGE PUR, `bash -n` ; NON exécuté |
| C4 | 6bc2d92 | lot 3 : commandes et skills | RENOMMAGE PUR |
| C4b | 3f77e3f | lot 3 : SYNC-MAIL-AGENDA-PROMPT, `mcp__mnemos__mnemos_<x>` → `mycelora_<x>` | 6 lignes (135, 136, 145, 146, 154, 167), étape 6 identique à origin/main |
| C5 | 15a20a4 | lot 3 : versions 0.13.0 | voir § 5 |
| C6 | 0c89a4e | lot 4 : commentaires qui nomment un outil | RENOMMAGE PUR, 28 lignes, toutes des commentaires `#` |
| C7 | f1a7177 | lot 4 : prose des données de test et miroirs | RENOMMAGE PUR, JSON valide, 142/142 |
| C8 | 968eace | lot 4 : textes affichés du démonstrateur | RENOMMAGE PUR, sortie identique après normalisation |
| Rev | 94ec255 | lot 3 : correctif de revue (m-2, m-4) sur `run-unit-tests.sh` | 142/142, M1 à M3 rejouées |

C4b n'est pas soumis à `verif_renommage_pur` par la story (seul commit de
consigne non mécanique : le préfixe `mcp__mnemos__` disparaît).

## 3. Contre-épreuves

- **T1** (`run-unit-tests.sh`, fin de fichier) : les DEUX générateurs du
  faux curl (tête du fichier et restauration après « fail-open sur serveur
  muet ») journalisent le `params.name` de chaque corps `--data-binary @…`
  dans `$FAKE_BIN_DIR/noms-outils.log` (chemin dérivé de `$0`, indépendant
  de toute variable d'environnement ; corps illisible → `ILLISIBLE`, qui
  rougit). Un marqueur `--- RESTAURATION FAUX CURL ---` est écrit juste
  après la restauration. Assertion exacte : ensemble =
  `[mycelora_impact_lookup, mycelora_log_exchange, mycelora_recall]`,
  marqueur présent une fois, au moins un nom postérieur. Run C2 : 54
  lignes, marqueur en l.31, 20 `mycelora_impact_lookup`, 22
  `mycelora_log_exchange`, 11 `mycelora_recall`. Le lookup d'impact est
  déclenché par le test préexistant `reflexe-pre-deny-alter-table`.
- **T2** : même brief (jeton `mk_sess_…` en première ligne, ligne `Fil :`),
  input vide (ni `sessionId` ni `spaceId`, pour que le label ne puisse venir
  que de la ligne `Fil :`) ; nom nouveau → jeton et label exacts ; ancien nom
  → `""` et `""` exacts, dans le même test. Caches `/tmp` et `mktemp`
  nettoyés. Retouche d'orchestrateur : bandeau `MNEMOS IN` retiré des deux
  transcripts de T2 (inutile, aucun hook ne le lit ; aurait ajouté 2 lignes
  au filet).

- Limite connue de T1 (revue, m-3) : le faux curl temporaire du cas
  « fail-open sur serveur muet » (`exit 28`, 3 lignes) ne journalise pas ;
  l'appel `impact_lookup` de ce seul test échappe à T1, sans effet pratique
  (même code de hook que les 20 lookups journalisés).
- Correctif de revue (m-2, 94ec255) : dans les deux générateurs,
  `CALL_LOG="${MYCELORA_TEST_CURL_LOG:?…}"` et `echo "CALLED"` passent APRÈS
  le journal des noms, qui ne dépend plus de cette variable.

### Mutations (après commit de C2, outil d'édition seul)

| # | Mutation | Résultat | Lignes FAIL |
|---|---|---|---|
| M1 | `userpromptsubmit.sh` : `mycelora_recall` → `mnemos_recall` | 135/142, rc=1 | `mycelora-userpromptsubmit-1`, `-2`, `-9`, `-tool-error`, `ups-question-courte-doit-passer`, `ups-validation-puis-question-doit-passer` (tous « expected tool name 'mycelora_recall', got 'mnemos_recall' »), `noms-outils-envoyes-au-serveur-exactement-mycelora : FAIL:ensemble=['mnemos_recall', 'mycelora_impact_lookup', 'mycelora_log_exchange'] marqueurs=1 apres_marqueur=True total_lignes=54` |
| M2 | `stop.sh` : `mycelora_log_exchange` → `mnemos_log_exchange` | 136/142, rc=1 | `mycelora-stop-10`, `-13`, `-14`, `-tool-heavy`, `-tool-heavy-no-promptid` (« expected tool name 'mycelora_log_exchange', got 'mnemos_log_exchange' »), `noms-outils-… : ensemble=['mnemos_log_exchange', 'mycelora_impact_lookup', 'mycelora_recall']` |
| M3 | `common.sh` : `mycelora_impact_lookup` → `mnemos_impact_lookup` | 141/142, rc=1 | `noms-outils-… : ensemble=['mnemos_impact_lookup', 'mycelora_log_exchange', 'mycelora_recall']` (seul filet : trou fermé) |
| M4 | `common.sh` : `endswith("mnemos_session_start")` | 122/142, rc=1 | T2 : `nouveau_token='' nouveau_label='' ancien_token='mk_sess_T2RUPTUREFRANCHE01' ancien_label='cowork-2026-09-18-t2-rupture-franche'` ; tests existants de capture : `mycelora-userpromptsubmit-2`, `alias-les-deux-etiquettes-partent`, `alias-sans-titre-humain-la-cle-est-absente`, `alias-le-spaceId-est-toujours-resolu`, `cache-v2-existant-traite-comme-absent-reconstruit-v3`, `session-label-rendu-par-le-serveur-prime-sur-l-appel`, `charger-fil-format-content-chaine-directe`, `s-jeton-2-ligne-jeton-parasite-autre-outil-ignoree`, `s-jeton-2-correlation-appel-et-reponse-en-deux-passes`, `s-jeton-2-jeton-en-tete-lu-dans-apercu-persisted-output`, `resolve-hook-token-priorite-2-cache-v3`, `offset-ligne-completee-extraite-au-passage-suivant`, `ups-jeton-resolu-via-cache-v3-appel-reussi`, `ups-bearer-reellement-envoye-cache-v3`, `stop-bearer-reellement-envoye-cache-v3`, `pretooluse-401-jeton-expire-sur-lookup-refuse-quand-meme`, `posttooluse-401-jeton-expire-sur-lookup-log-dedie`, `pretooluse-bearer-reellement-envoye-cache-v3`, `posttooluse-bearer-reellement-envoye-cache-v3` |
| M5 | `common.sh` : `endswith(("mycelora_session_start", "mnemos_session_start"))` | 141/142, rc=1 | T2 : `nouveau_token='mk_sess_T2RUPTUREFRANCHE01' nouveau_label='cowork-2026-09-18-t2-rupture-franche' ancien_token='mk_sess_T2RUPTUREFRANCHE01' ancien_label='cowork-2026-09-18-t2-rupture-franche'` (alias détecté) |

Second passage de M1 à M3 après le correctif 94ec255 (T1 modifié), avec
`git diff` vide CONSTATÉ après chaque restauration : M1 135/142 (mêmes 7
lignes FAIL), M2 136/142 (mêmes 6), M3 141/142 (même ligne T1) ; après
chacune, `git diff` = `[]`. M4 et M5 non rejouées : le correctif ne touche
que des commentaires de T2, et le code de capture n'a pas bougé. Suite
finale : 142/142, 142 PASS, 0 FAIL.

Premier passage, restaurations par l'édition inverse : M1 → `git diff --stat` au run M2 ne
montre que `mycelora-stop.sh` ; M2 → au run M3 ne montre que
`mycelora-common.sh` (ligne impact) ; M3 → au run M4 ne montre que la ligne
`endswith` ; après M4 : `git diff` vide et `git status --porcelain` vide
constatés ; après M5 : `git diff` vide et `git status` vide constatés, puis
suite 142/142, 142 PASS, 0 FAIL.

## 4. Écarts de méthode, signalés

- Premier passage des mutations : après M1, M2 et M3, le retour à
  l'original n'a été prouvé qu'indirectement (`--stat` du run suivant),
  pas par un `git diff` vide (revue, m-1). Corrigé par le second passage
  (§ 3), où le diff vide est constaté après chaque restauration.
- `.cc-attente-decision.md` (Q-S-PROPRE-1-L3-PLG-1, description > 500) est
  écrit en fin de story, avec le signal de fin (la revue l'a trouvé absent
  au moment de sa lecture : il n'était pas encore posé).

- Codeur C4b : les l.135 et 145 sont des titres qui citent le nom nu
  `mnemos_<x>` (pas la forme `mcp__mnemos__`) ; listées par la story et
  absentes de la liste fermée, elles relèvent de la règle C4. Renommées par
  l'orchestrateur (retouche triviale).
- Codeur C6 : a commité lui-même (interdit) et joint un fichier
  `.claude/v2-decisions/S-PROPRE-1-L3-PLG-C6.md` hors liste. Commit local non
  poussé, corrigé par `git commit --amend` (fichier retiré du commit et du
  worktree), code inchangé : 0c89a4e, RENOMMAGE PUR.
- C8 (6 lignes d'`echo`) appliqué par l'orchestrateur par `sed` ciblé sur les
  numéros de ligne, sans codeur : écart à « un codeur par commit », jugé
  sans risque (renommage pur prouvé, sortie comparée).

## 5. Versions (C5)

`plugin.json` 0.12.1 → 0.13.0 ; entrée `mycelora` de `marketplace.json`
0.11.5 → 0.13.0. `git grep -n '0\.12\.1\|0\.11\.5'` hors archives :
seulement `mycelora-common.sh:683` et `run-unit-tests.sh:968` (commentaires
historiques datés, ex-938 à fdf3e39). Aucune version dans
`build-plugin-zip.sh` (argument) ni `README.md`.

**Case DoD non tenue : description de `plugin.json` = 530 caractères (> 500).**
Préexistant, prouvé : longueur 478 à 029adc4, 530 à partir de 737d888
(12/09/2026, « skill mycelora : … 51 outils », plugin 0.12.0), inchangée à
fdf3e39 et e849f70 (0.12.1). La description de `plugin.json` est hors
périmètre explicite de la story : non touchée. Selon
`packaging-mnemos.md:104`, la limite n'est contrôlée qu'à l'upload d'un zip,
pas par le canal Git (0.12.0 et 0.12.1 sont sortis à 530). Décision réservée
remontée (`.cc-attente-decision.md`, Q-S-PROPRE-1-L3-PLG-1) : dette D8.

## 6. Filet final (après C8)

Commande 1 (hors `.md` racine, archives, décisions) : 42 lignes = liste
fermée (41) + 1 ligne de T2 (45 avant le correctif de revue, qui a
reformulé trois commentaires).

| Groupe | Lignes | Justification |
|---|---|---|
| Chemin `MNEMOS 07 26/` | `run-integration-tests.sh:8` | hors sprint |
| D1 | `build-plugin-zip.sh:2, 6, 8, 9, 14, 15, 55, 91, 123, 125, 126` (11) | hors lot, fichier intact |
| Trace datée | `preuve-jeton-session-reelle.OUTPUT.txt:14, 43, 48, 53, 69, 84, 94, 99` (8) | non réécrite |
| Bandeau `MNEMOS IN` | `mycelora-common.sh:260` ; `transcript-s-jeton-2-parasite-autre-outil.jsonl:2, 4` ; `…-persisted-output-apercu.jsonl:2` ; `transcript-session-start-avec-jeton.jsonl:3` ; `…-fil-serveur.jsonl:2` ; `…-jeton-content-string.jsonl:2` ; `run-unit-tests.sh:2423, 2451, 2488, 2529, 2669, 2675` (= 2368, 2396, 2433, 2474, 2571, 2577 à fdf3e39) (13) | sortie serveur hors table, jamais lue par les hooks |
| D4 | `ONBOARDING.md:67`, `SKILL.md:327`, `SYNC-MAIL-AGENDA-PROMPT.md:2` | `mnemos-sync-mail-agenda` |
| D5 | `SKILL.md:323`, `REFERENCE.md:143` | `mnemos-collect-google` |
| Fait historique | `REFERENCE.md:87` | dispatcher `mnemos_admin` |
| D3 | `SYNC-MAIL-AGENDA-PROMPT.md:157, 158` | étape 6 intacte |
| **T2 (nouveau)** | `run-unit-tests.sh:2587` | transcript à l'ancien nom : la contre-épreuve le cite par construction (jamais construit par concaténation) |

Commande 2 (`README.md`) : l.9, 10, 28 (D2).

Commande 3 (jetons) :
```
  16 MNEMOS
   1 MNEMOS_HOOK_KEY__
   1 Mnemos
   7 mnemos
   1 mnemos-build-token
   2 mnemos-collect-google
   1 mnemos-plugin-build
   3 mnemos-sync-mail-agenda
   1 mnemos__mnemos_admin
   2 mnemos_admin
   2 mnemos_impact_lookup
   1 mnemos_log_exchange
   2 mnemos_recall
   3 mnemos_session_start
```
Les `mnemos_recall`, `mnemos_log_exchange`, `mnemos_impact_lookup` restants
sont tous dans `.OUTPUT.txt` ; les 3 `mnemos_session_start` : 2 dans
`.OUTPUT.txt`, 1 dans T2.

## 7. Périmètre

`git diff origin/main --stat` : 22 fichiers, tous dans la liste autorisée
(plus ce fichier de décision). `git diff origin/main` vide sur
`build-plugin-zip.sh`, `README.md`, `.OUTPUT.txt`, `plugins/mon-greffier`,
`hooks.json`, `mycelora-pretooluse.sh`, `mycelora-posttooluse.sh` ; lignes
155-165 de `SYNC-MAIL-AGENDA-PROMPT.md` identiques à origin/main. `bash -n`
OK sur les 6 `.sh` touchés. `run-integration-tests.sh` et
`build-plugin-zip.sh` NON exécutés. Story et prompt non suivis (exclus par
`info/exclude`), jamais ajoutés.

## 8. Dettes nommées (non traitées)

- **D1** `scripts/build-plugin-zip.sh` : mode legacy `mnemos` (défaut du
  troisième argument l.15, zip `plugin-mnemos<version>.zip` l.126, préfixes
  temporaires `mnemos-*` l.55 et 91). Probablement mort : plugin `mnemos`
  retiré par 5c98d3e (29/08/2026, « retrait du plugin legacy mnemos 0.8.8 »,
  `plugins/` ne contient plus que `mon-greffier` et `mycelora`) ; la preuve et
  le retrait sont un geste à part.
- **D2** `README.md` : ligne `Mnemos` « Available » (l.9) et mention de
  transition (l.10), fausses depuis 5c98d3e ; l.28 historique.
- **D3** `SYNC-MAIL-AGENDA-PROMPT.md` étape 6 : appelle un dispatcher
  `mnemos_admin` qui n'existe plus (`REFERENCE.md:87`) ; un remplacement par
  `triage_atoms` avec `autoAssign` changerait le comportement d'une tâche
  sans témoin.
- **D4** `mnemos-sync-mail-agenda` : `taskId` créé par ONBOARDING, existence
  non vérifiée ; `SKILL.md:327` affirme que la tâche « reste active »,
  affirmation non vérifiée.
- **D5** `mnemos-collect-google` : nom de job probablement faux depuis le
  renommage des jobnames du 21/08.
- **D6** `commands/start.md:3` : `mycelora_login` et `mycelora_signup`
  autorisés alors qu'aucun outil de ce nom n'existe côté serveur (présents
  depuis 0404f6d, 20/08/2026, copie rebrandée de mnemos).
- **D7** description de `marketplace.json` (« 48 outils MCP ») périmée,
  depuis d34ab5b (21/08/2026) ; `packaging-mnemos.md` (hors dépôt) documente
  encore le défaut `mnemos` du script de build.
- **D8** (nouvelle) description de `plugin.json` à 530 caractères depuis
  737d888, au-delà de la limite de 500 de l'upload zip Cowork
  (`packaging-mnemos.md:104`) ; sans effet sur le canal Git.

- **D9** (nouvelle, revue m-5) l'échec silencieux lui-même reste en
  place : une réponse HTTP 200 portant une erreur JSON-RPC (-32601, outil
  inconnu) passe par `2??) : ;;` (`mycelora-userpromptsubmit.sh:228`) puis
  sort en statut `empty` (l.263-266), sans trace distincte. Un statut de
  journal `jsonrpc-error` le rendrait visible ; c'est une refonte, hors
  story.
- Hors story, préexistant (revue m-6) : `run-unit-tests.sh` ne supprime
  jamais `$FAKE_BIN_DIR` (`mktemp -d` l.12, aucun `rm` de ce dossier) ; un
  dossier `tmp.*` reste par run.

## 9. Retour arrière

Revert du commit publié avec une version montée (0.13.1), puis mise à jour
du plugin sur les deux Mac.

## 10. Revue et test

- Revue fraîche `reviewer` (claude-opus-5) : aucun bloquant ; M-1
  (escalade annoncée, fichier pas encore posé) traité en fin de story ;
  m-1 et m-2 et m-4 corrigés (94ec255, second passage M1 à M3) ; m-3, m-5
  (D9), m-6 consignés ci-dessus. Non rejoué par la revue : « suite verte à
  chaque commit » (demande un checkout) ; chaque commit a été suivi d'un run
  vert par l'orchestrateur ou le codeur au même contenu (C1 140/140, C2
  142/142, C3 à C5 sans code exécuté par la suite, C6 et C7 142/142, C8 et
  correctif 142/142), à rejouer par Cowork dans un worktree jetable.
- `testeur` (claude-sonnet-5) à 94ec255 : CONFORME. Suite 142/142 (142
  PASS, 0 FAIL), preuve jeton identique après normalisation (l.30-31
  mktemp), filet 42 + README 3 + jetons identiques au § 6, mutation M5
  rejouée (141/142, seule FAIL `capture-jeton-rupture-franche-ancien-nom-refuse`),
  restaurée, `git diff` = `[]`, suite 142/142 ; `git diff origin/main` vide
  sur les fichiers intacts exigés.
