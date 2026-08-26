---
name: mycelora
description: >
  Mémoire contextuelle et réflexive pour Claude. Graphe de connaissances avec
  atomes (10 types), espaces (projets), profil utilisateur et neurone cross-insights.
  Déclencher pour : ouverture/clôture de fil, "mycelora in/out", "souviens-toi",
  "cherche dans ma mémoire", "mes espaces", "retiens que", "brief matinal",
  "analyse les tensions", ou toute référence à la mémoire persistante.
---

# Mycelora — Mémoire contextuelle et réflexive

Graphe de connaissances : **atomes** (10 types), **espaces** (projets), **profil** (principes + portrait), **neurone** (cross-insights).

## QUICK REFERENCE

| Config | Valeur |
|--------|--------|
| Dashboard | https://mycelora.ai |
| Canal 1 | Plugin Cowork (skills + hooks automatiques, rien à configurer) |
| Canal 2 | Connecteur claude.ai / Claude Desktop "Mycelora" (OAuth) → outils MCP mnemos_* |

OUTILS : fournis par le connecteur custom claude.ai "Mycelora" (48 outils, edge function). `quick_boot` N'EXISTE PAS côté connecteur : ne jamais l'appeler. get_stats, triage_atoms, garbage_collect, health_check sont des outils standalone.
USERID : userId:USER_ALIAS (identifiant court, ex: "stephane", défini à l'onboarding), toujours requis dans les appels MCP.
Fichiers associés (même dossier) : ONBOARDING.md, REFERENCE.md, SYNC-MAIL-AGENDA-PROMPT.md

---

## POST-COMPACTION

Après toute compression de contexte :
1. Appeler `mnemos_get_profile(userId:USER_ALIAS)` puis suivre le protocole REPRISE POST-COMPRESSION ci-dessous
2. RELIRE ce skill en entier
3. Résumer ce qui a été retrouvé, demander confirmation
NE JAMAIS continuer en se fiant uniquement au résumé compressé.

---

## PROTOCOLE D'OUVERTURE (2 étapes)

Triggers : "ouvre un fil", "mycelora in", "session start", "lance Mycelora", ou appel implicite du skill.

### Étape 1 : Boot
Appeler `mnemos_session_start(userId:USER_ALIAS, sessionId:"cowork-AAAA-MM-JJ-sujet")` — sans spaceId si l'espace n'est pas encore connu, avec spaceId directement si l'utilisateur l'a nommé.

**L'IDENTIFIANT DÉFINITIF DU FIL EST CELUI QUE LE SERVEUR REND, pas celui que tu as envoyé.** Depuis le fil 86 (26/08/2026), le serveur horodate lui-même le sessionId à l'heure LOCALE et l'annonce en tête du bloc d'ouverture, sur la ligne `Fil : ...`. Ne calcule pas l'heure toi-même, ne la devine pas : **relis cette ligne et reprends cet identifiant-là dans TOUS les appels suivants**, jusqu'à la clôture comprise.

Motif : le sessionId est la clé de rattachement des atomes et des injections en base. Deux fils qui portent le même identifiant se disputent leur mémoire (cas réel : les fils 81 et 82 du 25/08 ont partagé un seau toute la journée). Le serveur réutilise le seau d'un fil encore ouvert et n'en crée un nouveau que si le précédent est clôturé, donc le second appel de `session_start` (celui qui apporte le spaceId) ne fabrique pas de doublon.

Retourne : la date, l'heure et le jour de la semaine courants dans TON fuseau (un modèle n'a pas d'horloge : ne recalcule jamais un jour de semaine, lis-le), l'identifiant du fil, les consignes de l'espace, le profil, les espaces actifs, 3 derniers handovers, atomes épinglés.
Si profil vide ou erreur "user not found" → LIRE **ONBOARDING.md** et suivre le flow.

### Étape 2 : Bloc d'accueil
L'heure de la salutation est celle que le bloc d'ouverture vient de te donner (`Nous sommes le ...`), dans le fuseau de l'utilisateur. Ne la recalcule pas, ne la devine pas ; `date` ne sert plus que si le bloc ne l'a pas rendue.
Présenter SYSTÉMATIQUEMENT :

```
---
Mycelora — [Salutation selon l'heure]

Espaces actifs :
  [Espace 1] — [JJ/MM] · [N1] atomes
  [Espace 2] — [JJ/MM] · [N2] atomes

Commandes : "ouvre [espace]" · "brief matinal" · "cherche [sujet]" · "fin de fil"

Dashboard : https://mycelora.ai
---
Sur quel espace on travaille ?
```

Le lien Dashboard DOIT apparaître à chaque ouverture de fil.
Si l'espace n'était pas connu à l'étape 1 : attendre la réponse, puis re-appeler `session_start(userId:USER_ALIAS, sessionId:L'IDENTIFIANT RENDU À L'ÉTAPE 1, spaceId:X)` pour attacher la session à l'espace. Le serveur rattache ce second appel au seau déjà ouvert, il n'en crée pas un second.
Note : userId est TOUJOURS requis dans les appels MCP, sauf si la doc de l'outil le marque explicitement optionnel.
Résolution nom : `list_spaces` + matching souple insensible à la casse.

---

## REPRISE POST-COMPRESSION

Trigger : "continued from a previous conversation", "context compaction", résumé de session.

CE SCÉNARIO EST CRITIQUE : le LLM a perdu ~70% du contexte. Sans ce protocole, la session reprend sans mémoire.

1. Détecter l'espace actif dans le résumé compressé
2. `mnemos_session_start(userId:USER_ALIAS, sessionId:"resume-AAAA-MM-JJ", spaceId:"[espace]")` — le serveur horodate, reprends l'identifiant qu'il rend
3. `mnemos_read_memory(userId:USER_ALIAS, spaceId:"[espace]", type:"all")`
4. Croiser résumé compressé + mémoire Mycelora
5. "Je reprends après compression. Voici ce que j'ai retrouvé : [résumé croisé]. On continue ?"

Si "Continue directly" ou "do not recap" → faire session_start QUAND MÊME, enchaîner sans attendre.
Si espace non identifiable → `list_spaces` puis demander.

---

## PROTOCOLE DE CLÔTURE

Triggers : "fin de fil" / "mémorise" / "on ferme" / "session end" / "mycelora out"

1. **workSummary** (8 lignes AU PLUS) : « où on s'est arrêté et pourquoi », pas un récit. Le détail vit dans les listes structurées ci-dessous, pas dans le résumé.
2. **Codex** (DOIT, pas PEUT — S-CODEX-1, décision du 23/08) : RÉDIGE le codex à jour de l'espace AVANT l'appel de clôture. C'est une MISE À JOUR, pas une réécriture : reprends le codex servi à l'ouverture du fil, applique-lui le delta du fil (ce qui est advenu, tranché, réfuté, fait), conserve chaque ligne ancienne ni contredite ni remplacée AVEC sa date et sa formulation. Forme imposée (même forme que le prompt serveur, `lib/codex-reflecteur.ts::construirePromptCodex` — tenir les deux en phase, renvoi croisé du 23/08/2026) :
   - markdown direct, SANS frontmatter, SANS fence, SANS emoji ni tableau ;
   - tête « EN BREF : » (avec les deux-points) : l'état de l'espace en une phrase, le plus structurant d'abord ; puis la prochaine échéance datée en une phrase ;
   - cinq sections, exactement : `## Situation`, `## Décisions en vigueur`, `## Réfuté ou abandonné`, `## En attente`, `## Repères chiffrés` — jamais de sixième section : les repères d'infrastructure entrent comme LIGNE DATÉE de Situation ;
   - lignes « - JJ/MM : ... », uniquement des dates citées par le fil, les handovers ou l'ancien codex ; « (antérieur) » si la date est inconnue ; prévu ≠ fait (le futur va dans En attente) ;
   - 1000 à 1500 mots en PLAFOND, la matière commande la longueur ; le codex grandit, il ne rétrécit que par retrait de lignes périmées ; une même chose ne figure jamais dans deux sections.
   Le serveur contrôle ce codex avec les MÊMES garde-fous que le modèle, sans exemption ; s'il est refusé, le repli modèle prend la main et l'ancien codex reste protégé.
3. **Handover** : `mnemos_session_end(userId:USER_ALIAS, spaceId:L'ESPACE DU FIL, workSummary:..., decisions:[...], pendingTasks:[...], refutations:[...], pieges:[...], pointeurs:[...], correctionsUtilisateur:[...], nonVerifie:[...], codex:"EN BREF : ...")`

   **`spaceId` EST OBLIGATOIRE À LA CLÔTURE, même si le fil a été ouvert avec.**
   Le serveur ne le retrouve pas tout seul : `sessionEnd` le résout depuis le
   paramètre reçu, et `resolveSpaceId` rend `undefined` quand il est absent.
   Sans lui, le handover s'écrit avec `space_id` à NULL, le codex n'est PAS
   régénéré (`"aucun espace résolu"`), et la clôture est à moitié perdue. Cas
   réel, fil 86 du 26/08/2026 : cette ligne omettait `spaceId`, et le fil l'a
   payé. Repasser l'UUID rendu à l'ouverture.

   **FOURNIR LES DEUX LISTES, TOUJOURS.** Tu as vécu le fil ; le modèle serveur n'en verrait qu'un résumé de quelques milliers de caractères. Quand les deux listes sont fournies avec un `workSummary` de plus de 300 caractères, **le serveur ne fait AUCUN appel modèle pour le handover** : la clôture est nettement plus rapide et ne consomme pas de tokens. Sans elles, un modèle refait ton travail moins bien.

   `decisions` = faits tranchés pendant le fil, avec leur raison. `pendingTasks` = ce qui reste actionnable, **la prochaine action en premier** (elle est rendue en tête à l'ouverture du fil suivant). **L'une des deux peut être vide** (un fil peut n'avoir aucune tâche restante), pas les deux. Écris-les en phrases complètes : elles sont réinjectées telles quelles à l'ouverture du fil suivant.

   **LA CLÔTURE STRUCTURÉE (obligatoire depuis le fil 69).** Sur ce chemin, le serveur REFUSE la clôture si l'un des cinq champs suivants est absent ou vide. Ce sont les champs que tu n'écris jamais spontanément : tu retiens tes conclusions, pas tes impasses.
   - `refutations` : essayé ou affirmé pendant le fil, puis révélé faux. Quoi, et pourquoi c'est écarté.
   - `pieges` : ce qu'il ne faut pas redécouvrir au fil suivant (comportements traîtres, limites d'outils, faux amis).
   - `pointeurs` : chemins, scripts, identifiants, commandes utiles pour reprendre. Du « où regarder », pas du contenu.
   - `correctionsUtilisateur` : ce que l'utilisateur a corrigé dans ce que tu affirmais. Ne te l'approprie pas : cite la correction.
   - `nonVerifie` : ce que tu affirmes sans preuve (non testé, non mesuré, repris d'un souvenir).

   **Une liste vide est refusée.** Si le fil n'a rien à mettre dans un champ, la justification EST l'entrée : `["aucune réfutation : fil de lecture seule"]`. Dates : cite la date de l'événement quand tu la connais. Ces champs sont rendus à l'ouverture du fil suivant dans l'ordre : prochaine action, réfutations, pièges, corrections, décisions, pointeurs, non vérifié, résumé ; et les réfutations et pièges alimentent la section « Réfuté ou abandonné » du codex.
4. **Mémoire** : ton codex accepté est écrit par `session_end` (frontmatter `author: client`) et la clôture ne fait alors AUCUN appel modèle. S'il est refusé, le serveur replie sur le modèle, et si le repli est refusé aussi l'ancien codex est conservé. **Aucun appel `read_memory`/`write_memory` manuel n'est nécessaire** — `write_memory` reste une issue de secours d'administration, non contrôlée, à ne pas utiliser en clôture.
5. **Vérifier** la réponse de l'outil. **`context_snapshot.source_listes` doit valoir `client`** (sinon tes listes n'ont pas été prises en compte : client trop ancien, ou `workSummary` sous le seuil). **Le bloc `codex` de la réponse doit porter `source:"client", accepte:true`** : s'il porte un refus, ANNONCE ses `raisons` à l'utilisateur (elles sont la seule trace lisible) et ne relance JAMAIS `session_end` pour retenter — le handover est déjà écrit, une relance créerait un doublon. Si échec → voir REFERENCE.md § Gestion des erreurs.
6. **Confirmer** : "Session clôturée. Handover (XXX mots) et codex mis à jour pour [espace]." — en citant qui a écrit le codex (toi ou le repli modèle).

---

## COMPORTEMENT AUTOMATIQUE

### Extraction d'atomes
Depuis le watcher v3 embarqué dans le plugin (0.8.0), la collecte est automatique : chaque échange est capturé puis transformé en atomes sans action de l'utilisateur (voir § Watcher v3 ci-dessous). La création proactive d'atomes ci-dessous reste recommandée pour les décisions importantes, mais n'est plus le seul canal d'alimentation de la mémoire.

### Création proactive d'atomes
Si l'utilisateur exprime une décision, leçon, contradiction, intention, fait notable...
Le LLM **DOIT** créer l'atome via `create_atom_manual` et informer : "Je retiens ça comme [type]."
DOIT, pas PEUT. "PEUT" = ne le fait jamais. L'utilisateur peut corriger le type ou refuser.

Exemples — ça mérite un atome :
- "On part sur Next.js pour le site" → decision
- "J'ai appris que les mails arrivent en double si le cron est < 1h" → apprentissage
- "Jean-Marc quitte le projet fin avril" → event + contact
Exemples — ça n'en mérite PAS :
- "Oui, bonne idée" (acquiescement sans contenu)
- "Passe-moi le fichier X" (instruction opérationnelle ponctuelle)
- Discussion technique transitoire qui sera dans le handover de clôture

**TAILLE : 1500 CARACTÈRES, PLAFOND DUR.** Un atome plus long est **coupé** à
l'écriture depuis S-PLAFOND-1 (26/08/2026) : ce qui dépasse n'est pas stocké,
donc pas récupérable. Écris sous la limite, ou **fais deux atomes** plutôt qu'un
gros. Ce n'est pas une préférence de style, c'est la taille servie : le rappel
coupe à 1500 depuis toujours, et l'embedding se calcule sur ce texte-là. Un
atome long dilue son propre vecteur sur trop de sujets et se retrouve moins
bien. Un fait par atome se retrouve mieux que trois faits dans un pavé.

### Hygiène mémoire
`triage_atoms` : quand > 30% d'atomes basse confiance, ou sur demande.
`garbage_collect` et `health_check` : automatisés via pg_cron, aussi appelables directement (outils du même nom). Détails dans REFERENCE.md.

### Watcher v3 (hooks du plugin)
Deux hooks embarqués dans le plugin assurent la mémoire automatique, sans action de l'utilisateur :
- **À chaque message utilisateur** : rappel contextuel FACE-A injecté avant la réponse.
- **À la fin de chaque échange** : l'échange est collecté automatiquement pour alimenter les atomes.

Un journal technique est tenu dans `/tmp/mycelora-hook.log` (diagnostic local). Les deux hooks ignorent les notifications système et les messages trop courts pour être utiles. Limite connue : un rappel planifié (wakeup) au libellé libre peut ne pas être filtré et apparaître comme un message utilisateur normal.

---

## COMMANDES EN LANGAGE NATUREL

| L'utilisateur dit | Action |
|-------------------|--------|
| (auto au 1er message) | session_start (sans spaceId) |
| mycelora in X, ouvre X | session_start(spaceId:X) |
| mycelora out, fin de fil | session_end(workSummary, decisions, pendingTasks, ..., codex) — le codex est RÉDIGÉ par toi (protocole de clôture, étape 2) |
| retiens que..., décision:, fait:, j'ai appris | create_atom_manual (type selon contenu) |
| cherche Y, dans ma mémoire | search_atoms(query:Y) |
| mes espaces, mes dossiers | list_spaces |
| crée dossier X | create_space(name:X) |
| analyse les tensions | cross_insights |
| brief matinal | get_context(mode:"auto") (brief complet à venir, chantier dédié) |
| stats, état mémoire | get_stats |
| mon profil, qui suis-je | get_profile |
| montre la mémoire de X | read_memory(spaceId:X, type:"codex") |
| injecte ce document | ingest_document |
| diagnostic, santé | health_check |
| contact:, qui est X | upsert_contact / search_contacts |
| mycelora help | afficher cette table en blocs thématiques |

---

## TÂCHES PLANIFIÉES

| Système | Tâche | Fréquence |
|---------|-------|-----------|
| Supabase pg_cron | garbage_collect | Dimanche 5h FR |
| Supabase pg_cron | health_check (Edge Function health-cron) | Quotidien 5h UTC |
| Supabase pg_cron | mnemos-collect-google (collecte cloud mail/agenda : Google Workspace + IMAP OVH, malgré son nom historique) | Toutes les 2h, indépendant du Mac/Cowork |
| Cowork scheduled-tasks | mnemos-sync-mail-agenda (macOS, legacy) | Toutes les 2h (quand Cowork ouvert) |

Note : au premier run d'une tâche Cowork, l'utilisateur doit approuver les outils MCP une fois ("Toujours autorisé").

### Collecte mail/agenda : cloud (recommandé) vs legacy Mac
Depuis S7, la collecte mail/agenda tourne côté serveur Mycelora
(`mnemos-collect-google`, pg_cron toutes les 2h) : **fonctionne sur
n'importe quelle plateforme, Mac éteint ou non, Cowork ouvert ou non.**
Détail architecture : REFERENCE.md § Collecte cloud mail/agenda.

La tâche Cowork macOS historique (`mnemos-sync-mail-agenda`) reste active
en parallèle pendant la période de transition (double-collecte, dédup
automatique côté serveur, aucun doublon observé) : sa mise en pause est un
geste manuel de l'utilisateur dans l'UI Scheduled, pas automatique. Ne pas
la présumer désactivée sans confirmation explicite.
Windows/Linux : la collecte cloud fonctionne nativement, aucune tâche
locale requise (contrairement à avant S7 où seuls les connecteurs
Anthropic natifs en conversation directe étaient disponibles hors macOS).

---

## TON

Mycelora est le nom de l'app, l'utiliser librement.
Dire "je me souviens que..." ou "dans le dossier X..." plutôt que détailler la mécanique.
Ne pas mentionner les canaux techniques, outils MCP ou fichiers mémoire sauf demande explicite ou debug.
