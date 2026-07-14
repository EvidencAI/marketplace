---
description: Start Mnemos — persistent memory for Claude
allowed-tools: ["plugin:mnemos:mnemos - mnemos_whoami", "plugin:mnemos:mnemos - mnemos_login", "plugin:mnemos:mnemos - mnemos_signup", "plugin:mnemos:mnemos - mnemos_session_start", "plugin:mnemos:mnemos - mnemos_get_profile", "plugin:mnemos:mnemos - mnemos_get_stats", "plugin:mnemos:mnemos - mnemos_list_spaces", "plugin:mnemos:mnemos - mnemos_read_memory", "plugin:mnemos:mnemos - mnemos_search_atoms", "Read"]
argument-hint: [espace] ou "help"
---

# Commande /mnemos:start

Initialise Mnemos, la memoire persistante de Claude.

## Flux de decision

### 1. Verifier la connexion (TOUJOURS en premier)

Appeler `mnemos_whoami()` (sans arguments).

**Si le resultat contient "connected: true" et un userId :**
- L'utilisateur est connecte. Passer a l'etape 2 avec ce userId.

**Si le resultat contient "connected: false" ou une erreur :**
- L'utilisateur n'est PAS connecte. Afficher :

```
Mnemos — Memoire intelligente pour Claude

Mnemos donne a Claude une memoire persistante entre vos conversations :
decisions, apprentissages, contacts, faits, reflexions...

Vous n'etes pas encore connecte.
Dites-moi "je veux me connecter" (avec votre email/mot de passe)
ou "je veux creer un compte" pour commencer.

Dashboard : https://mnemos.evidencai.com
```

- STOP. Ne pas aller plus loin.

### 2. Utilisateur connecte — traiter les arguments

Si `$ARGUMENTS` est vide ou absent :
- Executer `mnemos_session_start(userId: <userId du whoami>)`
- Afficher le bloc d'accueil avec espaces, commandes, lien Dashboard.
- Demander "Sur quel espace on travaille ?"

Si `$ARGUMENTS` = "help" :
- Lire le fichier `${CLAUDE_PLUGIN_ROOT}/skills/mnemos/SKILL.md`
- Afficher la table "Commandes en langage naturel" reformatee en blocs thematiques.

Si `$ARGUMENTS` = "login" :
- Demander email et mot de passe a l'utilisateur
- Appeler `mnemos_login(email, password)`
- Si succes : afficher "Connecte ! Tapez /mnemos:start pour demarrer."
- Si echec : afficher l'erreur et proposer de creer un compte

Si `$ARGUMENTS` = "signup" :
- Demander email et mot de passe souhaite a l'utilisateur
- Appeler `mnemos_signup(email, password)`
- Si succes : afficher "Compte cree ! Tapez /mnemos:start pour demarrer."
- Si echec : afficher l'erreur

Si `$ARGUMENTS` = un nom d'espace (ex: "Developpement Mnemos", "CodirIA") :
- Executer session_start(userId, spaceId: $ARGUMENTS)
- Charger read_memory(spaceId, type:"all")
- Afficher le contexte et demander confirmation

Si `$ARGUMENTS` = "out" ou "fin" :
- Executer le protocole de cloture (workSummary, session_end, write_memory).

Si `$ARGUMENTS` = "stats" :
- Appeler mnemos_get_stats et afficher les compteurs.

### 3. Toujours afficher le lien Dashboard

Chaque reponse de /mnemos:start DOIT inclure en fin de message :
```
Dashboard : https://mnemos.evidencai.com
```
