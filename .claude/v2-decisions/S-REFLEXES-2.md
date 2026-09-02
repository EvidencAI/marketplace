# STORY-S-REFLEXES-2 — le réflexe d'impact

## Corrections post-relecture (reviewer Opus + ergonome, 02/09/2026, avant
## ouverture de PR)

Quatre findings, tous dans le périmètre de la story (bugs d'implémentation,
pas des dérogations au contrat figé). Détail des correctifs, tous vérifiés
par un test automatisé neuf en plus des 64 tests déjà verts (75/75 après
correction) :

**1. HIGH, confirmé en réel par le coordinateur.** `RE_UPDATE_DELETE =
r"\b(update|delete\s+from)\b"` matchait le mot anglais « update » n'importe
où dans une commande Bash quelconque : `npm update`, `sudo apt-get update`,
`brew update`, `git remote update`, `cargo update -p serde` déclenchaient
tous un deny absurde. Remplacé par deux motifs ANCRÉS en tête d'instruction
(même convention que `RE_DDL`, multiligne) : `RE_UPDATE_ANCRE = r"^\s*update
\s+[\w.\"'\`]+\s+set\b"` (exige une vraie clause SET — un simple ancrage
« update en tête de ligne » aurait encore laissé passer `update-alternatives
--config editor`, où « update » EST le premier mot mais ce n'est pas du SQL)
et `RE_DELETE_ANCRE = r"^\s*delete\s+from\b"`. Fixtures négatives ajoutées :
les 5 cas cités + `update-alternatives`. `extraire_uid_valeur`/
`RE_USER_ID_PRESENCE` inchangés (ils s'appliquent seulement une fois le
geste déjà confirmé par le motif ancré).

**2. MEDIUM, confirmé en réel.** `detecter_infra` cherchait ses motifs
(`docker restart`, `rsync`, `curl`+PATCH+`/envs`) n'importe où dans le texte
BRUT : `echo "docker restart plus tard"` et `git commit -m "add docker
restart step"` déclenchaient un deny infra absurde. Ajouté un gating de
POSITION D'INSTRUCTION (`RE_DEBUT_SEGMENT`, `_positions_debut_segment`) :
le mot-clé doit apparaître en tout début de commande, ou juste après un
séparateur shell réel (`&&`, `||`, `;`, `|`, saut de ligne) — sinon rejeté.
Contre-épreuve positive ajoutée (`cd /app && docker restart ...` déclenche
toujours) pour prouver que le gating n'est pas une régression déguisée en
faux négatif. **`ssh_psql` (docker exec + psql) reste volontairement SANS
gating** : c'est un motif COMPOSÉ (deux mots-clés distants requis, très
improbable en simple prose) et surtout INTRINSÈQUEMENT imbriqué dans un
wrapper (`ssh hôte "docker exec -i conteneur psql ..."`, forme réelle
UNIQUE de ce dépôt, section 9 du brief, mon propre fixture
`stdin-pre-infra-ssh-psql.json` le vérifie) — un gating de position aurait
cassé le cas d'usage même que ce motif vise. Gap assumé : `docker_restart`/
`coolify_patch` imbriqués de la même façon via ssh (`ssh hôte "docker
restart ..."`) ne seraient plus détectés après ce correctif — non observé
dans ce dépôt, faux négatif tolérable (doctrine du brief), documenté ici
plutôt que corrigé au prix d'une complexité de parsing shell disproportionnée
pour un cas non prouvé.

**3. LOW.** `mycelora_reflexe_construire_rapport` (le bloc python heredoc,
`2>/dev/null` sans repli) pouvait en théorie laisser `out_report` vide si
python levait avant d'écrire — le deny serait alors parti avec
`permissionDecisionReason: ""`, silencieux, contraire au piège 3 du brief.
Ajouté un filet de sécurité APRÈS l'appel python, dans la fonction bash
elle-même (donc valable pour tout appelant, pas seulement pretooluse.sh) :
si `out_report` est vide, écrit un motif générique de repli et force
`rapport_vide: true` dans `out_meta` (même si `out_meta` lui-même est
illisible). Testé directement (pas via le hook complet) en injectant
`objets_json = "42"` (JSON valide mais pas une LISTE : fait lever
`for o in objets:` — TypeError non gardée par le seul `try/except` qui
protège le PARSING JSON, pas la FORME rendue). Premier essai de preuve
écarté : un `out_report` pointant vers un dossier inexistant cassait AUSSI
l'écriture du repli lui-même (même chemin, même échec) — ne prouvait rien ;
le scénario retenu est neutre côté fichiers (comme le vrai hook, où
`out_report`/`out_meta` sont toujours des fichiers `mktemp` valides) et ne
fait échouer QUE la construction, ce qui est le cas réellement redouté.

**4. Trouvé par l'ergonome en réel.** `extraire_objets` utilisait
`.search()` (première occurrence SEULEMENT) sur `RE_ADD_COLUMN`/
`RE_DROP_COLUMN`/`RE_RENAME_COLUMN` pour un ALTER TABLE à plusieurs clauses
séparées par des virgules — un `ALTER TABLE ... ADD COLUMN a, ADD COLUMN b,
ADD COLUMN c, DROP COLUMN d` ne ressortait qu'avec `a` et `d` (une par
motif), `b` et `c` disparaissaient SANS AUCUN signal de troncature dans un
rapport qui a l'air complet — risque de confiance grave pour un rapport lu
vite. Remplacé par `.finditer()` (toutes les occurrences par motif).
Testé avec exactement le cas de l'ergonome (`priorite`, `statut`, `score`
ajoutées + `legacy` supprimée dans un seul ALTER) : les 4 colonnes
ressortent désormais, chacune sur sa propre ligne `Objet : memory_atoms.X
(colonne).`.

Preuves réelles (hors suite de tests, capturées pour le rapport de
clôture) : `npm update` → stdout vide, aucun appel curl. L'ALTER à 4
colonnes → rapport listant `memory_atoms`, `memory_atoms.priorite`,
`memory_atoms.statut`, `memory_atoms.score`, `memory_atoms.legacy`.

---

Worktree `evidencai-marketplace-worktrees/s-reflexes`, branche
`feat/reflexes-senior` (déjà positionnée en ouverture de story, pas créée
par ce geste — seule la création du worktree parent, déjà faite avant mon
entrée en jeu, restait à signaler). Codeur = Sonnet 5, code direct.

## Écart de contrat découvert (à signaler, pas à improviser)

Le contexte d'ouverture de story donnait `ImpactLookupResult` sous une forme
simplifiée (`objets: Record<string, LigneCarte | {inconnu:true}>`). Lecture
réelle de `supabase/functions/mycelora-mcp/tools/carte.ts` (S-REFLEXES-1,
déjà mergée) : la forme RÉELLEMENT implémentée est différente —

```ts
interface ImpactLookupResult {
  spaceId: string
  carteVide: boolean
  dateCarte: string | null
  carteperimee: boolean
  avertissement: string | null
  objets: Array<{ identifiant: string; inconnu: boolean; lignes: Record<string, unknown>[] }>
}
```

`objets` est un TABLEAU (une entrée par identifiant demandé, doublons
inclus), pas un dictionnaire indexé par identifiant. `tools.ts` (ligne
~1680) confirme que la réponse MCP est `JSON.stringify(result, null, 2)`
dans `result.content[0].text` — donc le JSON réellement reçu par le hook
est cette forme réelle, pas la forme simplifiée du contexte d'ouverture.
Codé contre le CONTRAT RÉEL (vérifié sur le fichier), pas contre le résumé
donné en amorce. Le champ `lignes[0]` de chaque objet connu porte le
gabarit `LigneCarte` de `scripts/carte-objets.ts` (`type, objet, colonnes,
lu_par, ecrit_par, rpc, section_carte, genere_le, empreinte`) : c'est ce
gabarit qui alimente le texte du rapport (`Lu par`, `Écrit par`, `RPC`,
`Carte : « <section_carte> »`).

Aucun outil MCP réel de la machine n'était disponible pour l'appel réel (la
sonde ci-dessous couvre Bash/Edit/Write) : le contrat côté serveur a été lu
sur le code source, pas exercé en intégration réelle contre l'edge function
(hors périmètre : `run-integration-tests.sh` fait des appels réseau réels
mais n'a pas été étendu, périmètre de la story ne le demande pas
explicitement — seul `run-unit-tests.sh` est cité).

## Sonde réelle des noms d'outils (ouverture de story)

Faite dans un répertoire jetable `/tmp/mycelora-s2-probe-<pid>` (git init,
`.claude/settings.json` avec un hook PreToolUse minimal qui journalise
`cat >> fichier` sans jamais refuser), détruit après la sonde. Run headless
`claude --dangerously-skip-permissions -p "..." --output-format json`
demandant Bash + Write + Edit + MultiEdit.

**Payload PreToolUse réel reçu (clés triées)** : `cwd, effort,
hook_event_name, permission_mode, prompt_id, session_id, tool_input,
tool_name, tool_use_id, transcript_path`. Exemples de `tool_input` capturés
tels quels :
- Bash : `{"command": "echo probe-bash-ok", "description": "Afficher probe-bash-ok"}`
- Write : `{"file_path": "/private/tmp/.../nouveau.txt", "content": "hello write\n"}`
- Edit : `{"file_path": "/private/tmp/.../seed.txt", "old_string": "ligne1", "new_string": "LIGNE-UN", "replace_all": false}`

**MultiEdit absent du catalogue d'outils de cette session** (ni chargé, ni
dans les outils différés — `ToolSearch select:MultiEdit` ne retourne rien
non plus dans MA propre session de codage). Le modèle a explicitement
refusé de simuler l'étape plutôt que fausser la sonde. Le matcher
`hooks.json` et la détection niveau 2 gardent quand même `MultiEdit` (le
contrat de la story l'exige, et son schéma `tool_input.file_path` suit la
même convention qu'Edit/Write — cohérent même non vérifié en direct ici) :
point NON prouvé par cette sonde, à confirmer par Stéphane sur sa propre
machine si l'outil existe dans son installation.

Aucun outil MCP réel de la machine (`mcp__<serveur>__<outil>`) n'a pu être
sondé (aucun serveur MCP tiers actif dans le répertoire jetable) — le
matcher générique `mcp__.*` couvre cette incertitude sans blocage, comme
prévu par le cliquet Q4. Aucune règle de REFUS en v1 ne dépend du contenu
d'un outil MCP de toute façon (voir plus bas).

## `mycelora_curl_post` : timeout optionnel ajouté (extension de fonction
partagée, pas une réécriture)

Le contexte d'ouverture affirmait « `mycelora_curl_post` reçoit déjà un
timeout optionnel, défaut 5 ». Faux à la lecture réelle : la fonction
n'avait que 3 paramètres, `--max-time 5` en dur. Ajouté un 4e paramètre
optionnel (`timeout="${4:-5}"`), les deux appelants existants
(userpromptsubmit/stop, 3 arguments) restent inchangés en comportement.
`mnemos_impact_lookup` appelle avec `4`. Vérifié : 34 tests préexistants
toujours verts après ce changement, avant même d'ajouter du code neuf.

## Chemin rapide sans python : bug trouvé et corrigé en cours de route

Version initiale : `START_MS="$(python3 -c '...')"` était calculé AVANT le
test `if [ "$TOOL_NAME" != "Bash" ]; then exit 0; fi` dans les deux hooks —
ça aurait démarré python même sur un outil hors périmètre, violant le DoD
littéralement. Déplacé après le test dans les deux fichiers. Preuve
comportementale dans la suite de tests : un faux `python3` placé avant le
vrai dans `PATH`, qui journalise son appel et échoue s'il est invoqué —
`reflexe-pre-chemin-rapide-sans-python-outil-hors-perimetre` et son
pendant PostToolUse le confirment (le faux python3 n'est jamais appelé).

## `user_id` : bug trouvé et corrigé (nettoyage détruisait la valeur avant
détection)

`nettoyer_sql` remplace tout littéral `'...'` par `''` AVANT tout matching
(contrat figé, anti faux-positifs). Première version de la détection
user_id cherchait `user_id\s*=\s*'?([0-9a-fA-F-]{4,})'?` sur le texte DÉJÀ
nettoyé — la valeur venait toujours d'être effacée par le nettoyage, donc
`UPDATE ... WHERE user_id = '2ba47612-...'` n'était JAMAIS détecté comme
ciblant un compte (testé, confirmé en échec avant correction). Corrigé en
séparant deux passes distinctes :
- `detecter_update_delete_risque` (fonction pure, texte nettoyé) ne
  cherche plus qu'une PRÉSENCE booléenne `user_id\s*=` (matche encore
  `user_id = ''`, la valeur n'a pas besoin de survivre pour ce test) ;
- `extraire_uid_valeur` (cosmétique, hors de la fonction de décision) relit
  le texte BRUT (non nettoyé) pour afficher la vraie valeur dans le
  rapport. Absence de valeur extractible (best-effort) : le rapport dit
  « (valeur non extraite, vérifiez la commande) » plutôt que d'inventer.

## Interprétation de l'ancrage `^\s*` (motifs DDL) : gap assumé, pas corrigé

Le contrat fige `^\s*(alter table|...)`  en mode multiligne (`^` matche
chaque début de LIGNE physique après nettoyage). Conséquence testée et
assumée : une commande à UNE seule ligne `psql -c "ALTER TABLE ..."` (le
mot-clé n'est PAS en tête de ligne, précédé de `psql -c "` sur la même
ligne) ne déclenche PAS le refus avec ce regex pris à la lettre. Un
ALTER TABLE dans un heredoc (`psql <<'SQL'\nALTER TABLE ...\nSQL`) ou après
un `;` suivi d'un saut de ligne EST détecté. C'est cohérent avec le seul
patron réel de ce dépôt pour envoyer du SQL à psql
(`scripts/carte-objets.ts::requeteSqlProdReelle`, script complet sur stdin
via un pipe, jamais `-c "..."`), donc pas corrigé unilatéralement (le
contrat est FIGÉ, « ne pas modifier ») — signalé ici plutôt qu'improvisé.
Toutes les fixtures de test utilisent la forme heredoc, réaliste.

## Contre-épreuve par mutation (règle 8bis) — 3 mutations, toutes ciblées

Faite manuellement sur `plugins/mycelora/hooks/mycelora-common.sh`
(sauvegarde/restauration via `cp`, jamais commitée en l'état muté),
`run-unit-tests.sh` relancé après chaque mutation, résultat comparé au
64/64 nominal :

1. **`nettoyer_sql` neutralisée en no-op.** Résultat : 61/63 (2 tests neufs
   introduits pour CETTE preuve — voir plus bas — échouent, tout le reste
   identique). Confirme que le nettoyage compte réellement pour ces deux
   cas précis (alter dans un commentaire BLOC `/* */` et alter dans un
   littéral MULTILIGNE, tous deux construits pour que le mot-clé tombe en
   tête de sa propre ligne une fois les délimiteurs retirés — les cas plus
   simples `-- commentaire` et littéral mono-ligne restent sûrs par le seul
   ANCRAGE, indépendamment du nettoyage, donc ne bougent pas sous cette
   mutation : découverte faite en écrivant la preuve, pas anticipée).
2. **Ancrage `^\s*` retiré de `RE_DDL`.** Résultat : 63/64, UN SEUL test
   neuf (`reflexe-pre-alter-hors-tete-instruction-ne-declenche-pas`,
   commande `echo "reminder: alter table is scary..."` — chaîne bash
   double-quotée, jamais touchée par `nettoyer_sql` qui ne nettoie que les
   littéraux SQL simple-quotés) échoue. Preuve que l'ancrage, seul, protège
   ce cas précis là où le nettoyage ne peut rien.
3. **Détection « sans WHERE » neutralisée** (`if not RE_WHERE.search(...)`
   → `if False:`). Résultat : 63/64, seul
   `reflexe-pre-delete-sans-where` échoue (plus d'appel curl, le DELETE
   sans WHERE n'est plus vu comme risqué).

Chaque mutation a fait échouer EXACTEMENT les tests visés, jamais plus,
jamais moins — signal fort que la suite est bien alignée sur la fonction
pure, pas sur un comportement accidentel. Mutations non commitées :
fichier restauré (`diff` vérifié identique) après chaque essai, suite
repassée à 64/64 avant de continuer.

## Marqueur de dédoublonnage : un fichier par fil, liste d'identifiants

Le contrat dit « marqueur `/tmp/mycelora-impact-<session_id>` » (un SEUL
chemin, pas paramétré par objet) mais aussi « refus unique PAR OBJET ET par
fil ». Résolu en un fichier unique par session, contenant UNE LIGNE PAR
IDENTIFIANT déjà refusé (pas un fichier par objet) : une commande à N
objets est refusée si AU MOINS UN des N n'a jamais été vu, et marque alors
les N (pas seulement les nouveaux) — un rejeu ultérieur sur N'IMPORTE LEQUEL
des N objets déjà couverts passe ensuite silencieusement.

## Gestes infra (ssh+psql, rsync, docker restart, PATCH Coolify) : pas de
recherche carte

Ces quatre gestes n'ont pas d'« objet de schéma » extractible au sens du
contrat (pas de table/colonne/fonction) : identifiant synthétique
`infra:<type>` pour le dédoublonnage, rapport à texte FIXE par type (pas de
tentative `mnemos_impact_lookup`, aucun appel curl — vérifié par les tests
`reflexe-pre-infra-*`, `expect_curl_call=no` implicite car aucun call.log
créé). Texte de « Portée » pour ces cas et pour le sous-cas UPDATE/DELETE
« sans WHERE » (pas de valeur user_id) : non donnés littéralement par le
contrat (qui ne fige que l'exemple DDL et l'exemple user_id) — rédigés par
cohérence avec le ton du contrat, pas une invention de périmètre.

## PostToolUse : jalon sans dédoublonnage (contrairement au refus)

Le contrat de dédoublonnage (« refus unique par objet et par fil ») est
attaché explicitement au REFUS (PreToolUse). Rien d'équivalent n'est écrit
pour le jalon (« après un geste structurant EXÉCUTÉ ») : le jalon
PostToolUse tire donc À CHAQUE exécution d'un geste structurant, y compris
les répétitions déjà passées côté PreToolUse. Choix délibéré : le jalon
signale un ÉTAT (« la carte peut être périmée »), pas un événement à ne
signaler qu'une fois.

## `.carte-perimee` : silencieux si le dépôt local n'est pas résolu

Le marqueur est écrit à la racine du dépôt résolu par
`mycelora_repo_root`. Si le hook tourne hors de tout dépôt reconnu (ni
`supabase/` ni `plugins/mycelora/` trouvés en remontant depuis `cwd`), rien
n'est écrit (pas de repli `/tmp`) : limite assumée, pas de convention de
repli donnée par le contrat.

## Fichiers sensibles (niveau 2, PostToolUse) : enrichissement seulement
pour `edge_index`

Parmi les 6 catégories (`migration`, `shared`, `edge_index`, `config_toml`,
`hook_script`, `plugin_json`, `env`), seule `edge_index`
(`supabase/functions/<nom>/index.ts`) tente un `mnemos_impact_lookup` (nom
de dossier de fonction edge extrait du chemin, type `outil_mcp`/
`edge_function` selon ce que la carte connaît). Les autres catégories
n'ont pas d'identifiant de type carte naturel : jalon avec le CHEMIN du
fichier comme « objet », sans tentative de lookup — cohérent avec le
niveau INFORMATION (pas de refus, pas d'urgence à enrichir).

## `mycelora_log` (télémétrie générique) en plus du journal dédié

Le style demandé cite explicitement `mycelora_log` comme patron à
reprendre. Les deux nouveaux hooks écrivent donc aussi dans
`/tmp/mycelora-hook.log` (hook="pretooluse"/"posttooluse", event="detect",
status parmi skip-not-bash/no-match/desarme/passage/refus/jalon/
skip-out-of-scope/skip-not-sensitive), EN PLUS du journal dédié
`reflexes_journal` (contrat métier figé, format JSONL distinct). Les deux
coexistent, aucun ne remplace l'autre.

## Base de tests : 34 préexistants (pas 30)

La story annonçait « 30 tests existants ». Mesuré en ouverture (avant tout
changement) : 34/34 déjà verts. Écart mineur, signalé par honnêteté de
mesure — la Definition of Done (« 30 tests existants + les tests neufs »)
reste satisfaite dans l'esprit : 34 préexistants + 30 neufs = 64/64.

## Sonde réelle des noms d'outils MCP, session Cowork cloud liée au Mac (Cowork, 02/09/2026 06h33 UTC)

Hook PreToolUse de journalisation posé dans une session Cowork réelle (Fable 5.1), trois appels d'outils consécutifs. Noms reçus dans `tool_name`, tels quels :

```
2026-09-02T06:33:14 event=PreToolUse tool_name=mcp__remote-devices__device_list_dir input_keys=['path']
2026-09-02T06:33:18 event=PreToolUse tool_name=mcp__remote-devices__Desktop_Commander__start_process input_keys=['command', 'timeout_ms']
2026-09-02T06:33:23 event=PreToolUse tool_name=Bash input_keys=['command', 'description']
```

Conséquences : la convention `mcp__<serveur>__<outil>` est confirmée sur une machine réelle ; `Desktop_Commander__start_process` porte la commande dans `tool_input.command`, même clef que `Bash`, donc la détection SQL et infra s'applique telle quelle ; `device_list_dir` ne porte qu'un `path`. Le matcher générique `mcp__.*` du plugin 0.10.0 est correct.
