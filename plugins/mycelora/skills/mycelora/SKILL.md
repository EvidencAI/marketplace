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
| Mode A | Outils MCP natifs mnemos_* (préféré) |
| Mode B | Fallback → voir FALLBACK-MODE-B.md |

OUTILS : fournis par le connecteur custom claude.ai "Mnemos" (35 outils, edge function). `quick_boot` N'EXISTE PAS côté connecteur : ne jamais l'appeler. get_stats, triage_atoms, garbage_collect, health_check sont des outils standalone.
USERID : Mode A → userId:USER_ALIAS (identifiant court, ex: "stephane", défini à l'onboarding). Mode B (curl) → userId:USER_UUID.
Fichiers associés (même dossier) : ONBOARDING.md, REFERENCE.md, FALLBACK-MODE-B.md, SYNC-MAIL-AGENDA-PROMPT.md

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
Retourne : profil, espaces actifs, 3 derniers handovers, atomes épinglés, codex de l'espace « Mémoire générale » (injecté systématiquement au boot).
Si profil vide ou erreur "user not found" → LIRE **ONBOARDING.md** et suivre le flow.

### Étape 2 : Bloc d'accueil
Vérifier l'heure via la commande `date` (Bash, Desktop Commander, ou tout shell disponible) pour la salutation.
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
Si l'espace n'était pas connu à l'étape 1 : attendre la réponse, puis re-appeler `session_start(userId:USER_ALIAS, sessionId:même valeur, spaceId:X)` pour attacher la session à l'espace.
Note : userId est TOUJOURS requis dans les appels MCP, sauf si la doc de l'outil le marque explicitement optionnel.
Résolution nom : `list_spaces` + matching souple insensible à la casse.

---

## REPRISE POST-COMPRESSION

Trigger : "continued from a previous conversation", "context compaction", résumé de session.

CE SCÉNARIO EST CRITIQUE : le LLM a perdu ~70% du contexte. Sans ce protocole, la session reprend sans mémoire.

1. Détecter l'espace actif dans le résumé compressé
2. `mnemos_session_start(userId:USER_ALIAS, sessionId:"resume-YYYY-MM-DD", spaceId:"[espace]")`
3. `mnemos_read_memory(userId:USER_ALIAS, spaceId:"[espace]", type:"all")`
4. Croiser résumé compressé + mémoire Mycelora
5. "Je reprends après compression. Voici ce que j'ai retrouvé : [résumé croisé]. On continue ?"

Si "Continue directly" ou "do not recap" → faire session_start QUAND MÊME, enchaîner sans attendre.
Si espace non identifiable → `list_spaces` puis demander.

---

## PROTOCOLE DE CLÔTURE

Triggers : "fin de fil" / "mémorise" / "on ferme" / "session end" / "mycelora out"

1. **workSummary** (600-800 mots) : résumé narratif exhaustif. Inclure : décisions (avec contexte), problèmes résolus (comment), travail produit, limitations, prochaines étapes, questions ouvertes.
2. **Handover** : `mnemos_session_end(userId:USER_ALIAS, workSummary:..., decisions:[...], pendingTasks:[...])`

   **FOURNIR LES DEUX LISTES, TOUJOURS.** Tu as vécu le fil ; le modèle serveur n'en verrait qu'un résumé de quelques milliers de caractères. Quand les deux listes sont fournies avec un `workSummary` de plus de 300 caractères, **le serveur ne fait AUCUN appel modèle pour le handover** : la clôture est nettement plus rapide et ne consomme pas de tokens. Sans elles, un modèle refait ton travail moins bien.

   `decisions` = faits tranchés pendant le fil, avec leur raison. `pendingTasks` = ce qui reste actionnable. **L'une des deux peut être vide** (un fil peut n'avoir aucune tâche restante), pas les deux. Écris-les en phrases complètes : elles sont réinjectées telles quelles à l'ouverture du fil suivant.
3. **Mémoire** : le codex de l'espace est régénéré automatiquement par `session_end` (en tâche de fond, fail-soft). **Aucun appel `read_memory`/`write_memory` manuel n'est nécessaire.**
4. **Vérifier** succès handover + mémoire. **Contrôler que `context_snapshot.source_listes` vaut `client` et non `modele`** : s'il vaut `modele`, tes deux listes n'ont pas été prises en compte (client trop ancien, ou `workSummary` sous le seuil). Si échec → voir REFERENCE.md § Gestion des erreurs.
5. **Confirmer** : "Session clôturée. Handover (XXX mots) et mémoire mise à jour pour [espace]."

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
| mycelora out, fin de fil | session_end(workSummary, decisions, pendingTasks) — le codex se régénère seul |
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
Ne pas mentionner modes A/B, outils MCP ou fichiers mémoire sauf demande explicite ou debug.
