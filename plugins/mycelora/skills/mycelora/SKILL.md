---
name: mycelora
description: >
  Mémoire contextuelle et réflexive pour Claude. Graphe de connaissances avec
  atomes (6 types, grille 2.1), espaces (projets), profil utilisateur et neurone cross-insights.
  Déclencher pour : ouverture/clôture de fil, "mycelora in/out", "souviens-toi",
  "cherche dans ma mémoire", "mes espaces", "retiens que", "brief matinal",
  "analyse les tensions", ou toute référence à la mémoire persistante.
---

# Mycelora — Mémoire contextuelle et réflexive

Graphe de connaissances : **atomes** (6 types, grille 2.1), **espaces** (projets), **profil** (principes + portrait), **neurone** (cross-insights).

## QUICK REFERENCE

| Config | Valeur |
|--------|--------|
| Dashboard | https://mycelora.ai |
| Canal 1 | Plugin Cowork (skills + hooks automatiques, rien à configurer) |
| Canal 2 | Connecteur claude.ai / Claude Desktop "Mycelora" (OAuth) → outils MCP mycelora_* |

OUTILS : fournis par le connecteur custom claude.ai "Mycelora" (51 outils, edge function). `quick_boot` N'EXISTE PAS côté connecteur : ne jamais l'appeler. get_stats, triage_atoms, garbage_collect, health_check sont des outils standalone.
USERID : `userId` est IGNORÉ par le serveur (identité résolue depuis la connexion, S-USERID-1 du 25/08/2026, écrasement inconditionnel dans `mycelora-mcp/index.ts`) : OMETS-LE dans tous les appels, sur toutes les surfaces. Seule exception : le chemin de la clé de service (tâches planifiées avec `x-mycelora-key`), où il désigne le compte cible en UUID.
Fichiers associés (même dossier) : ONBOARDING.md, REFERENCE.md, SYNC-MAIL-AGENDA-PROMPT.md

---

## POST-COMPACTION

Après toute compression de contexte :
1. Appeler `mycelora_get_profile()` puis suivre le protocole REPRISE POST-COMPRESSION ci-dessous
2. RELIRE ce skill en entier
3. Résumer ce qui a été retrouvé, demander confirmation
NE JAMAIS continuer en se fiant uniquement au résumé compressé.

---

## PROTOCOLE D'OUVERTURE (2 étapes)

Triggers : "ouvre un fil", "mycelora in", "session start", "lance Mycelora", ou appel implicite du skill.

### Étape 1 : Boot
Appeler `mycelora_session_start(sessionId:"cowork-AAAA-MM-JJ-sujet")` — sans spaceId si l'espace n'est pas encore connu, avec spaceId directement si l'utilisateur l'a nommé.

**L'IDENTIFIANT DÉFINITIF DU FIL EST CELUI QUE LE SERVEUR REND, pas celui que tu as envoyé.** Depuis le fil 86 (26/08/2026), le serveur horodate lui-même le sessionId à l'heure LOCALE et l'annonce en tête du bloc d'ouverture, sur la ligne `Fil : ...`. Ne calcule pas l'heure toi-même, ne la devine pas : **relis cette ligne et reprends cet identifiant-là dans TOUS les appels suivants**, jusqu'à la clôture comprise.

Motif : le sessionId est la clé de rattachement des atomes et des injections en base. Deux fils qui portent le même identifiant se disputent leur mémoire (cas réel : les fils 81 et 82 du 25/08 ont partagé un seau toute la journée). Le serveur réutilise le seau d'un fil encore ouvert et n'en crée un nouveau que si le précédent est clôturé, donc le second appel de `session_start` (celui qui apporte le spaceId) ne fabrique pas de doublon.

Retourne : la date, l'heure et le jour de la semaine courants dans TON fuseau (un modèle n'a pas d'horloge : ne recalcule jamais un jour de semaine, lis-le), l'identifiant du fil, les consignes de l'espace, le profil, les espaces actifs, 3 derniers handovers, atomes épinglés.
Si profil vide ou erreur "user not found" → LIRE **ONBOARDING.md** et suivre le flow.

Ne jamais afficher ni recopier la ligne `[jeton-hook-session ...]` du brief d'ouverture : c'est un jeton d'authentification pour les hooks, jamais un élément à montrer à l'utilisateur ou à citer dans une réponse.

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
Si l'espace n'était pas connu à l'étape 1 : attendre la réponse, puis re-appeler `session_start(sessionId:L'IDENTIFIANT RENDU À L'ÉTAPE 1, spaceId:X)` pour attacher la session à l'espace. Le serveur rattache ce second appel au seau déjà ouvert, il n'en crée pas un second.
Note : `userId` s'omet (voir QUICK REFERENCE) ; les exemples de ce skill ne le portent plus.
Résolution nom : `list_spaces` + matching souple insensible à la casse.

---

## REPRISE POST-COMPRESSION

Trigger : "continued from a previous conversation", "context compaction", résumé de session.

CE SCÉNARIO EST CRITIQUE : le LLM a perdu ~70% du contexte. Sans ce protocole, la session reprend sans mémoire.

1. Détecter l'espace actif dans le résumé compressé
2. `mycelora_session_start(sessionId:"resume-AAAA-MM-JJ", spaceId:"[espace]")` — le serveur horodate, reprends l'identifiant qu'il rend
3. `mycelora_read_memory(spaceId:"[espace]", type:"all")`
4. Croiser résumé compressé + mémoire Mycelora
5. "Je reprends après compression. Voici ce que j'ai retrouvé : [résumé croisé]. On continue ?"

Si "Continue directly" ou "do not recap" → faire session_start QUAND MÊME, enchaîner sans attendre.
Si espace non identifiable → `list_spaces` puis demander.

---

## PROTOCOLE DE CLÔTURE

Triggers : "fin de fil" / "mémorise" / "on ferme" / "session end" / "mycelora out"

1. **workSummary** (8 lignes AU PLUS) : « où on s'est arrêté et pourquoi », pas un récit. Le détail vit dans les listes structurées ci-dessous, pas dans le résumé.
2. **Codex** (DOIT, pas PEUT — S-CODEX-1, décision du 23/08) : RÉDIGE le codex à jour de l'espace AVANT l'appel de clôture. C'est une MISE À JOUR, pas une réécriture : reprends le codex servi à l'ouverture du fil, applique-lui le delta du fil (ce qui est advenu, tranché, réfuté, fait), conserve chaque ligne ancienne ni contredite ni remplacée AVEC sa date et sa formulation. Forme imposée (même forme que le prompt serveur, `_shared/codex-reflecteur.ts::construirePromptCodex` — tenir les deux en phase, renvoi croisé du 23/08/2026, chemin corrigé le 31/08 après le déplacement du fil 74) :
   - markdown direct, SANS frontmatter, SANS fence, SANS emoji ni tableau ;
   - tête « EN BREF : » (avec les deux-points) : l'état de l'espace en une phrase, le plus structurant d'abord ; puis la prochaine échéance datée en une phrase ;
   - cinq sections, exactement : `## Situation`, `## Décisions en vigueur`, `## Réfuté ou abandonné`, `## En attente`, `## Repères chiffrés` — jamais de sixième section : les repères d'infrastructure entrent comme LIGNE DATÉE de Situation ;
   - lignes « - JJ/MM : ... », uniquement des dates citées par le fil, les handovers ou l'ancien codex ; « (antérieur) » si la date est inconnue ; prévu ≠ fait (le futur va dans En attente) ; dans « En attente », la date de tête est celle de la SOURCE qui pose la tâche, JAMAIS une échéance devinée — si une échéance est connue, dis-la dans le texte de l'action, pas en tête de ligne (le contrôle serveur refuse toute date de tête absente des sources : le petit modèle s'y est fait prendre le 31/08 en fabriquant un « 01/09 » et un « 15/09 ») ;
   - **BUDGET DE L'ESPACE, RÈGLE DURE (19/09/2026)** : chaque espace a un budget de codex, 10 000 caractères par défaut, 20 000 pour les espaces denses (Tribunal de Commerce, NDO App). Si le bloc d'ouverture affichait « ATTENTION : codex à L caractères pour un budget de B », ta clôture DOIT rendre un codex sous B. Le serveur REFUSE un codex qui dépasse le budget ET grossit par rapport à l'ancien ; une condensation passe toujours. Sous le budget, le codex grandit et ne perd que des lignes périmées.
   - **Deux façons de maigrir, jamais de suppression muette** : (a) FUSIONNER plusieurs lignes anciennes d'un même thème en UNE ligne dense qui porte TOUTES leurs dates (« - 12/08, 19/08 : ... »), en priorité les plus anciennes et les plus détaillées, jamais celles des sept derniers jours ; (b) RETIRER une ligne devenue inutile (dossier clos, dette soldée, fait périmé) en la DÉCLARANT dans le paramètre `retraits` : `[{ligne:"- 16/04 : texte exact de l'ancien codex", motif:"dossier clos par jugement du 18/11"}]`, ligne recopiée À L'IDENTIQUE depuis l'ancien codex, motif de 10 à 300 caractères, 30 retraits au plus. Le serveur vérifie que la ligne existait et qu'elle a bien disparu (recopiée avec un simple point ou d'autres majuscules, elle est refusée comme « retrait fictif »), compte ses dates comme justifiées dans le contrôle d'histoire, et l'archive en souvenir clos, retrouvable par `mycelora_search_atoms(inclure_clos:true)`. Toute date de l'ancien codex qui disparaît SANS être déclarée compte comme de l'histoire perdue. Même paramètre `retraits` sur `mycelora_write_memory(type:"codex")` pour une resoumission ;
   - une même chose ne figure jamais dans deux sections. Depuis le 31/08 le serveur RETIRE la redite (première occurrence gardée) au lieu de refuser tout le codex, mais ne compte pas dessus pour ranger à ta place.
   Le serveur contrôle ce codex avec les MÊMES garde-fous que le modèle, sans exemption : taille minimale = 60 % de l'ancien MAIS jamais plus de 8 500 caractères (c'est ce plafond du plancher qui rend la condensation possible), et 60 % au moins des dates antérieures à la fenêtre de handovers conservées. S'il est refusé, l'ancien codex reste protégé et C'EST À TOI de resoumettre (S-CLOTURE-ASYNC, 31/08/2026 : le repli modèle du chemin client est SUPPRIMÉ, le frontier est l'unique rédacteur quand un pilote est présent).
3. **Atomes de clôture** (S-CLOT-1, sprint S-CLOTURE-2) : AVANT le handover et avec le MÊME `sessionId`, écris les souvenirs du fil par `mycelora_session_end_atoms(sessionId:L'IDENTIFIANT RENDU À L'OUVERTURE, atomes:[...])`, de 1 à 20 en UN seul appel. C'est le seul appel qui fait qu'un fil laisse une trace réutilisable ailleurs ; le handover, lui, ne se relit que dans cet espace.

   **L'ordre compte** : les atomes d'abord, la clôture ensuite, pour que les souvenirs fraîchement écrits nourrissent le compte rendu.

   Chaque entrée porte `type` et `contenu`, plus `portee` (**OBLIGATOIRE pour `regle` et `refute`**, sinon l'atome est refusé), et optionnellement `perime_si`. Le lot REFUSE `remplace` : remplacer un souvenir devenu faux passe par `create_atom_manual`, un à la fois. Types et critère d'écriture : voir § Création proactive d'atomes.

   **Si tu oublies cet appel**, la clôture n'est PAS refusée : elle est acceptée et **marquée INCOMPLETE**, et sa réponse te rend le `sessionId` à reprendre. Rappelle alors `mycelora_session_end_atoms` dans la foulée. Une clôture incomplète est comptée : c'est une mesure, pas une punition, et elle dit exactement une chose, que ce fil n'a rien laissé.

   **Si le fil n'a vraiment rien à retenir** (lecture seule, question ponctuelle), dis-le par le champ `sansAtomes` de `mycelora_session_end`, avec la justification en clair. Le vide déclaré et le vide oublié ne sont pas la même chose.
4. **Handover** : `mycelora_session_end(spaceId:L'ESPACE DU FIL, workSummary:..., decisions:[...], pendingTasks:[...], refutations:[...], pieges:[...], pointeurs:[...], correctionsUtilisateur:[...], nonVerifie:[...], codex:"EN BREF : ...", retraits:[...] si tu retires des lignes)`

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
5. **Mémoire** : ton codex accepté est écrit par `session_end` (frontmatter `author: client`) et la clôture ne fait alors AUCUN appel modèle. **S'il est refusé, PLUS AUCUN repli modèle ne prend la main** (S-CLOTURE-ASYNC, décision du 31/08/2026) : l'ancien codex est conservé et la réponse porte les raisons du refus. La resoumission t'appartient : corrige le codex D'APRÈS CES RAISONS puis écris-le par `mycelora_write_memory(spaceId, type:"codex", content:...)`, qui applique désormais les MÊMES garde-fous déterministes que la clôture (canal contrôlé, plus une porte dérobée) et rend ses propres raisons en cas de nouveau refus. Aucun appel `read_memory` n'est nécessaire. Le repli modèle ne subsiste que pour les fils SANS pilote (clôtures automatiques), via une file de fond (`codex_regen_queue`, worker toutes les 5 min) — jamais sur ton chemin.
6. **Vérifier** la réponse de l'outil. **`context_snapshot.source_listes` doit valoir `client`** (sinon tes listes n'ont pas été prises en compte : client trop ancien, ou `workSummary` sous le seuil). **Le bloc `codex` de la réponse doit porter `source:"client", accepte:true`** : s'il porte un refus, ANNONCE ses `raisons` à l'utilisateur, corrige le codex d'après elles et resoumets-le par `mycelora_write_memory(type:"codex")` (étape 5) ; ne relance JAMAIS `session_end` pour retenter — le handover est déjà écrit, et depuis S-CLOTURE-ASYNC le serveur rendrait de toute façon le handover existant tel quel (filet d'idempotence de 10 min, champ `rejeu: true`) sans rien réécrire. Si échec → voir REFERENCE.md § Gestion des erreurs.
7. **Confirmer** : "Session clôturée. Handover (XXX mots) et codex mis à jour pour [espace]." — en citant le sort du codex (accepté du premier coup, ou resoumis après refus avec la raison).

---

## COMPORTEMENT AUTOMATIQUE

### Écriture des atomes : par toi, plus par extraction
Depuis le 12/09/2026, l'extraction automatique d'atomes depuis les échanges est ÉTEINTE (cron `extract-from-exchanges` désactivé, décision D-2 du fil 117) : un petit modèle qui découpait les échanges produisait surtout du bruit. Les atomes d'un fil sont désormais écrits par le modèle du fil, c'est-à-dire par toi, à deux moments : en cours de fil quand un fait décisif tombe (§ Création proactive ci-dessous) et à la clôture, par lot (§ Protocole de clôture, étape 3). Ce qui n'est pas écrit par toi n'existe pas en mémoire. Le watcher collecte encore les échanges, mais pour d'autres usages (voir § Watcher v3).

### Création proactive d'atomes
Si l'utilisateur exprime une décision, une leçon payée, un démenti, un repère, un état...
Le LLM **DOIT** créer l'atome via `create_atom_manual` et informer : "Je retiens ça comme [type]."
DOIT, pas PEUT. "PEUT" = ne le fait jamais. L'utilisateur peut corriger le type ou refuser.

**Le critère, unique : ce souvenir servira-t-il ailleurs ou plus tard ?** Un autre modèle, dans un autre fil, doit pouvoir s'en servir sans avoir lu celui-ci. Chaque souvenir est une phrase COMPLÈTE et AUTONOME : « Il a dit oui » ne vaut rien, « Le client X a validé le devis de 12 k€ le 12/09/2026 » vaut quelque chose.

**Les six types de la grille 2.1** (il n'en existe aucun autre ; un type hors de cette liste est rabattu sur `non_affecte`). Source : `_shared/grille-atomes.ts`, jamais recopiée à la main :

| type | la question à laquelle il répond | portée naturelle |
|---|---|---|
| `regle` | comment agir ici : décision en vigueur, méthode, préférence, consigne | locale ou transverse |
| `piege` | ce qui échoue et pourquoi, payé au moins une fois | transverse |
| `refute` | ce qu'il ne faut plus croire | locale ou transverse |
| `repere` | où, qui, combien, comment c'est fait : pointeur, chiffre, contact, identifiant, fait de structure | locale |
| `etat` | où on en est, ce qui attend | locale |
| `non_affecte` | ce qui n'entre dans aucune des cinq autres familles : à voir et à traiter à la main | locale |

`non_affecte` n'est pas un repli commode, c'est une pile de tri à la main : un fil qui en produit surtout a mal classé. `etat` est le seul type qui périme par l'âge ; les cinq autres sortent par remplacement, clôture ou revue humaine.

**La portée** dit où le souvenir vaut : `locale` = seulement dans cet espace, `transverse` = dans tous. Elle est **OBLIGATOIRE pour `regle` et `refute`**, facultative ailleurs. Une méthode qui vaut partout est `transverse` ; une décision propre au dossier est `locale`.

**`perime_si`**, optionnel : la condition qui rendra ce souvenir faux, en clair et en quelques mots. Un souvenir qui porte sa condition de péremption vaut mieux qu'un souvenir qu'il faudra deviner périmé.

Exemples — ça mérite un atome :
- "On part sur Next.js pour le site" → `regle`, locale
- "J'ai appris que les mails arrivent en double si le cron est < 1h" → `piege`, transverse
- "Finalement le cron ne tourne pas la nuit, il tourne tous les quarts d'heure" → `refute`, locale
- "Jean-Marc est le DG, il quitte le projet fin avril" → `repere`, locale
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
- **À la fin de chaque échange** : l'échange est collecté (`mycelora_log_exchange`) pour nourrir le compte rendu automatique des fils abandonnés (`auto-session-end`), l'état du fil et le réflexe de contradiction. Il n'alimente PLUS les atomes depuis le 12/09/2026.

Un journal technique est tenu dans `/tmp/mycelora-hook.log` (diagnostic local). Les deux hooks ignorent les notifications système et les messages trop courts pour être utiles. Limite connue : un rappel planifié (wakeup) au libellé libre peut ne pas être filtré et apparaître comme un message utilisateur normal.

### Deux surfaces, un seul skill
Mycelora tourne sur DEUX surfaces avec le même skill et le même connecteur : **Cowork** (plugin installé, watcher v3 actif) et le **Chat claude.ai / Claude Desktop** (connecteur seul, pas de hooks, donc pas de watcher). Le skill ne sait pas où il tourne, et il n'a pas besoin de le savoir : la consigne est écrite pour être juste sur les deux.

- **Ce qui est identique partout** : l'ouverture (`session_start`), la création proactive d'atomes, les atomes de clôture et le handover. Tu écris les souvenirs toi-même dans tous les cas.
- **Le seul écart : le rappel contextuel.** Sur Cowork, le watcher l'injecte avant chaque réponse. Sur le Chat, rien n'arrive tout seul. Et même sur Cowork il peut manquer : rien de pertinent ce tour (bloc vide, normal), message filtré, ou watcher sans jeton (bloc d'ouverture trop gros pour le transcript, défaut connu du 12/09/2026). **Règle unique** : quand une question porte sur le contexte de l'utilisateur (ses projets, ses décisions, ses chiffres) et qu'aucun rappel n'est arrivé, appelle `mycelora_search_atoms` ou `mycelora_recall` toi-même avant de répondre. Un rappel demandé en trop coûte un appel ; un rappel manqué coûte une décision retranchée à l'aveugle.
- **Ne jamais appeler `mycelora_log_exchange` toi-même** : c'est l'appel du watcher, et le serveur refuse un lot connecteur quand un lot hook existe pour le fil (règle D5). Sur le Chat, sans watcher, le fil n'est pas collecté : c'est connu et assumé, sa mémoire est ce que tu écris en atomes et à la clôture.

### Réflexes de senior (impact, état du fil, contradiction)

Trois réflexes automatiques, indépendants du protocole d'ouverture/clôture ci-dessus.

**Réflexe d'impact** (commandes shell uniquement, v1) : avant un geste structurant (modification de schéma, suppression ou mise à jour massive, opération sur la prod), l'appel est REFUSÉ une fois, avec un rapport (qui lit et qui écrit l'objet visé). Ce n'est pas un blocage définitif : LIS le rapport, traite ce qu'il signale, puis REJOUE LA MÊME commande telle quelle — le refus ne se répète jamais pour le même objet dans le même fil. N'essaie jamais de contourner ce refus par un chemin détourné ; un refus veut dire « vérifie avant de rejouer », pas « renonce ».

**État du fil** : un court état du fil courant (objectif, périmètre en cours, ce qui est décidé, écarté, ouvert, corrections faites, etc.) peut apparaître à position fixe dans le rappel, seulement quand il a changé depuis la dernière injection. C'est une matière de contexte pour toi, pas un message à recopier ni à commenter à l'utilisateur.

**Réflexe de contradiction** : quand ce qui vient d'être dit contredit une décision en vigueur connue ailleurs (un autre projet, un fil antérieur), une ligne `ALERTE (...)` peut apparaître dans le rappel, avec un identifiant court à acquitter. Dès que tu la vois, acquitte-la : `mycelora_ack_alerte(id:"<identifiant donné dans le texte>", verdict:"utile"|"bruit")`, après avoir jugé en une phrase si elle est pertinente ou du bruit, puis informe l'utilisateur en une phrase. Ce verdict est un signal d'appoint, pas la décision finale (Stéphane tranche dans le dashboard) : acquitter n'efface jamais l'alerte.

---

## COMMANDES EN LANGAGE NATUREL

| L'utilisateur dit | Action |
|-------------------|--------|
| (auto au 1er message) | session_start (sans spaceId) |
| mycelora in X, ouvre X | session_start(spaceId:X) |
| mycelora out, fin de fil | session_end_atoms(atomes) PUIS session_end(workSummary, decisions, pendingTasks, ..., codex) — dans cet ordre ; le codex est RÉDIGÉ par toi (protocole de clôture, étape 2) |
| retiens que..., décision:, fait:, j'ai appris | create_atom_manual (type de la grille 2.1, + portee si regle ou refute) |
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

### RÈGLE : une tâche planifiée est une SONDE, pas un fil

Décision de Stéphane du 01/09/2026, à appliquer à TOUTE tâche planifiée
(surveillance, brief, veille, envoi, contrôle) qui touche Mycelora.

- Elle **n'ouvre jamais** de session (`mycelora_session_start`).
- Elle **ne clôture jamais** (`mycelora_session_end`).
- Elle **n'écrit ni handover ni codex**.
- Sa seule écriture en mémoire est **UN atome**, via `mycelora_create_atom_manual`,
  dans **l'espace qu'elle déclare**, et **seulement s'il y a quelque chose à
  retenir**. Une sonde verte n'écrit rien : c'est le cas normal.

**Pourquoi.** Un fil produit une compréhension qui a bougé, une sonde produit un
relevé. Faire passer une sonde par le circuit des fils fabrique des handovers de
données brutes sans contexte, qui remontent ensuite gonfler le codex de l'espace.
Constat qui a produit la règle : le codex de l'espace NDO App était monté à
27 402 caractères pour une cible de 10 000, nourri chaque matin par un brief
automatique. Le petit modèle chargé de régénérer le codex n'a alors qu'une suite
de chiffres sans récit, et le résultat est illisible.

**Corollaire : toute tâche planifiée doit déclarer son espace.** Sans espace,
son atome n'a pas de destination et finit dans « Non affecté ». L'espace se
décide à la création de la tâche et se met en clair dans son prompt, avec son
UUID.

**Plafond à rappeler dans chaque prompt de tâche.** Un atome est tronqué **en
silence** à 1500 caractères (`ATOME_TAILLE_MAX`), sans message d'erreur : la
conclusion d'une sonde bavarde disparaît sans prévenir. Consigne à donner :
l'essentiel en premier (symptôme, chiffre, écart), le détail ensuite, viser
1400 caractères.

**L'exception qui confirme la règle** : le brief général quotidien
(`morning-brief`) n'est pas une sonde mais une synthèse transversale de la
journée. Lui écrit un handover, dans l'espace **Mémoire générale**. Condition
impérative : il lit les handovers pour se fabriquer, donc il doit **exclure les
siens** de sa matière d'entrée, sinon il se nourrit de sa propre sortie.

### Parc des crons serveur (stack Supabase auto-hébergée)

| # | Cron | Fréquence (UTC) | Rôle |
|---|------|-----------------|------|
| 1 | extract-from-exchanges | toutes les 15 min | extraction d'atomes depuis les échanges |
| 2 | auto-session-end | toutes les 15 min | clôture des fils inactifs |
| 3 | mycelora-health-cron | chaque heure à :04 | contrôle de santé |
| 4 | mycelora-weekly-insights | lundi 06h10 | cross-insights hebdomadaires |
| 5 | mycelora-garbage-collect | quotidien 02h07 | ménage mémoire |
| 6 | mycelora-collect-google | toutes les 2h | collecte mail/agenda (Google Workspace + IMAP), indépendante du Mac |
| 7 | mycelora-process-events | toutes les 2h à :20 | traitement des événements collectés |
| 8 | mycelora-morning-brief-hourly | chaque heure à :02 | brief général, écrit par glm-5.2, rangé dans `briefs` et envoyé par mail |
| 9 | mycelora-export-queue | toutes les 2 min | file d'export mémoire |
| 10 | mycelora-retention-purge | quotidien 03h37 | purge de rétention |
| 11 | mycelora-retention-inactive-accounts | dimanche 04h15 | comptes inactifs |
| 12 | mycelora-juge-injections | chaque heure à :21 | juge de l'utilité des injections |
| 13 | mycelora-codex-worker | toutes les 5 min | dépilement de `codex_regen_queue` |

Note : au premier run d'une tâche Cowork, l'utilisateur doit approuver les outils MCP une fois ("Toujours autorisé").

### Journal des briefs : la table `briefs`

Chaque brief général produit est conservé dans la table `briefs` (97 briefs au
01/09/2026, le plus ancien du 04/06/2026). C'est le **seul artefact daté** de la
mémoire : le codex répond à « où en est ce projet », le journal des briefs répond
à « que s'est-il passé le 12 août ».

- **Consultation à la demande uniquement.** Quand une question porte sur une
  date, une période, ou sur ce qui s'est passé dans un autre projet à un moment
  donné, ce journal est la bonne source.
- **Jamais injecté dans le recall.** Les briefs datés ont été identifiés comme le
  premier gisement de bruit de l'injection automatique (13 injections jugées
  bruit pour 0 utile). Ils se consultent, ils ne se servent pas tout seuls.

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
