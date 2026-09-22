---
description: Start Mycelora — persistent memory for Claude
argument-hint: [espace] ou "help"
---

# Commande /mycelora:start

Initialise Mycelora, la memoire persistante de Claude.

## Flux de decision

### 1. Verifier la connexion (TOUJOURS en premier)

Les outils `mycelora_*` viennent du CONNECTEUR Mycelora (OAuth ou cle API),
jamais du plugin : leur prefixe varie selon le nom du connecteur
(`mcp__Mycelora__`, `mcp__Mycelora_OAuth__`...). Les charger si besoin
(recherche d'outils), puis appeler `mycelora_list_spaces()` sans arguments.
Il n'existe PAS d'outil `mycelora_whoami`, `mycelora_login` ni
`mycelora_signup` (retires ; ne jamais les appeler).

**Si la liste des espaces revient :** l'utilisateur est connecte. Passer a
l'etape 2. Ne jamais passer de `userId` : le serveur l'impose d'apres la
connexion et ignore toute valeur recue.

**Si aucun outil `mycelora_*` n'est disponible, ou si l'appel echoue
(401, erreur d'authentification) :** afficher :

```
Mycelora — Memoire intelligente pour Claude

Mycelora donne a Claude une memoire persistante entre vos conversations :
decisions, apprentissages, contacts, faits, reflexions...

Le connecteur Mycelora n'est pas encore branche.
Ajoutez-le dans Parametres, Connecteurs (serveur
https://api.mycelora.ai/functions/v1/mycelora-mcp), connectez-vous,
puis relancez /mycelora:start. Pas encore de compte : creez-le sur
https://mycelora.ai

Dashboard : https://mycelora.ai
```

- STOP. Ne pas aller plus loin.

### 2. Utilisateur connecte — traiter les arguments

Le brief rendu par `mycelora_session_start` peut porter en PREMIERE ligne
(S-JETON-2, 12/09/2026 ; en derniere ligne avant) `[jeton-hook-session ...]` : ne jamais l'afficher ni la recopier, c'est un
jeton d'authentification pour les hooks, jamais un element a montrer a
l'utilisateur ou a citer dans une reponse.

Le `sessionId` est choisi par toi (forme `surface-AAAA-MM-JJ-sujet`) ; le
serveur peut le rendre horodate : reprendre alors CELUI qu'il rend dans tous
les appels suivants, jusqu'a la cloture.

Si `$ARGUMENTS` est vide ou absent :
- Executer `mycelora_session_start(sessionId)`, sans `spaceId`
- Afficher le bloc d'accueil avec espaces, commandes, lien Dashboard.
- Demander "Sur quel espace on travaille ?"

Si `$ARGUMENTS` = "help" :
- Lire le fichier `${CLAUDE_PLUGIN_ROOT}/skills/mycelora/SKILL.md`
- Afficher la table "Commandes en langage naturel" reformatee en blocs thematiques.

Si `$ARGUMENTS` = un nom d'espace (ex: "Developpement Mycelora", "CodirIA") :
- Retrouver l'UUID de l'espace dans la liste de l'etape 1 (nom exact, sinon
  le plus proche ; en cas de doute, demander a l'utilisateur, ne jamais deviner)
- Executer `mycelora_session_start(sessionId, spaceId: <UUID>)`
- Charger read_memory(spaceId, type:"all")
- Afficher le contexte et demander confirmation

Si `$ARGUMENTS` = "out" ou "fin" :
- Executer le protocole de cloture du skill Mycelora (§ PROTOCOLE DE CLOTURE),
  dans cet ordre :
  1. `mycelora_session_end_atoms` avec le sessionId rendu a l'ouverture ;
  2. `mycelora_session_end` avec `spaceId`, workSummary, decisions, pendingTasks,
     les cinq listes structurees, ET le codex de l'espace MIS A JOUR dans le
     champ `codex` (codex servi a l'ouverture + delta du fil).
- Le serveur ne regenere JAMAIS le codex d'un fil pilote : sans codex fourni,
  l'ancien est conserve tel quel. Verifier dans la reponse que le bloc `codex`
  porte `accepte: true` ; sinon corriger d'apres ses raisons et resoumettre par
  `mycelora_write_memory(type:"codex")`, sans relancer session_end.

Si `$ARGUMENTS` = "stats" :
- Appeler mycelora_get_stats et afficher les compteurs.

### 3. Toujours afficher le lien Dashboard

Chaque reponse de /mycelora:start DOIT inclure en fin de message :
```
Dashboard : https://mycelora.ai
```
