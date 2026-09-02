---
description: Start Mycelora — persistent memory for Claude
allowed-tools: ["plugin:mycelora:mycelora - mnemos_whoami", "plugin:mycelora:mycelora - mnemos_login", "plugin:mycelora:mycelora - mnemos_signup", "plugin:mycelora:mycelora - mnemos_session_start", "plugin:mycelora:mycelora - mnemos_get_profile", "plugin:mycelora:mycelora - mnemos_get_stats", "plugin:mycelora:mycelora - mnemos_list_spaces", "plugin:mycelora:mycelora - mnemos_read_memory", "plugin:mycelora:mycelora - mnemos_search_atoms", "Read"]
argument-hint: [espace] ou "help"
---

# Commande /mycelora:start

Initialise Mycelora, la memoire persistante de Claude.

## Flux de decision

### 1. Verifier la connexion (TOUJOURS en premier)

Appeler `mnemos_whoami()` (sans arguments).

**Si le resultat contient "connected: true" et un userId :**
- L'utilisateur est connecte. Passer a l'etape 2 avec ce userId.

**Si le resultat contient "connected: false" ou une erreur :**
- L'utilisateur n'est PAS connecte. Afficher :

```
Mycelora — Memoire intelligente pour Claude

Mycelora donne a Claude une memoire persistante entre vos conversations :
decisions, apprentissages, contacts, faits, reflexions...

Vous n'etes pas encore connecte.
Dites-moi "je veux me connecter" (avec votre email/mot de passe)
ou "je veux creer un compte" pour commencer.

Dashboard : https://mycelora.ai
```

- STOP. Ne pas aller plus loin.

### 2. Utilisateur connecte — traiter les arguments

Le brief rendu par `mnemos_session_start` peut porter en derniere ligne
`[jeton-hook-session ...]` : ne jamais l'afficher ni la recopier, c'est un
jeton d'authentification pour les hooks, jamais un element a montrer a
l'utilisateur ou a citer dans une reponse.

Si `$ARGUMENTS` est vide ou absent :
- Executer `mnemos_session_start(userId: <userId du whoami>)`
- Afficher le bloc d'accueil avec espaces, commandes, lien Dashboard.
- Demander "Sur quel espace on travaille ?"

Si `$ARGUMENTS` = "help" :
- Lire le fichier `${CLAUDE_PLUGIN_ROOT}/skills/mycelora/SKILL.md`
- Afficher la table "Commandes en langage naturel" reformatee en blocs thematiques.

Si `$ARGUMENTS` = "login" :
- Demander email et mot de passe a l'utilisateur
- Appeler `mnemos_login(email, password)`
- Si succes : afficher "Connecte ! Tapez /mycelora:start pour demarrer."
- Si echec : afficher l'erreur et proposer de creer un compte

Si `$ARGUMENTS` = "signup" :
- Demander email et mot de passe souhaite a l'utilisateur
- Appeler `mnemos_signup(email, password)`
- Si succes : afficher "Compte cree ! Tapez /mycelora:start pour demarrer."
- Si echec : afficher l'erreur

Si `$ARGUMENTS` = un nom d'espace (ex: "Developpement Mycelora", "CodirIA") :
- Executer session_start(userId, spaceId: $ARGUMENTS)
- Charger read_memory(spaceId, type:"all")
- Afficher le contexte et demander confirmation

Si `$ARGUMENTS` = "out" ou "fin" :
- Executer le protocole de cloture : workSummary, puis session_end en fournissant
  TOUJOURS decisions et pendingTasks (sans elles, un modele serveur refait ce
  travail moins bien et la cloture est nettement plus lente). Le codex de
  l'espace se regenere seul, aucun write_memory manuel.

Si `$ARGUMENTS` = "stats" :
- Appeler mnemos_get_stats et afficher les compteurs.

### 3. Toujours afficher le lien Dashboard

Chaque reponse de /mycelora:start DOIT inclure en fin de message :
```
Dashboard : https://mycelora.ai
```
