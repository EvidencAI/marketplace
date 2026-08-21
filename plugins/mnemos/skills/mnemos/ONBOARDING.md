# Mnemos — Onboarding nouvel utilisateur

Ce flow se déclenche quand `mnemos_session_start` retourne un profil vide ou une erreur "user not found".
Le LLM DOIT lire ce fichier et suivre les étapes dans l'ordre.

---

## Bienvenue

Présenter Mnemos en 3 phrases max :
"Mnemos est ta mémoire persistante entre tes conversations avec Claude. Il retient tes décisions, projets, contacts, et te restitue le contexte pertinent à chaque nouveau fil. Tout est stocké dans ton espace sécurisé."

---

## Étape 1 : Créer le profil

Demander : "Comment tu veux que je t'appelle ? Et quels sont tes principes de travail que je dois toujours garder en tête ?"

Avec la réponse, appeler :
```
mnemos_update_profile(userId:[alias choisi], displayName:[prénom ou nom choisi], principles:[tableau de strings], portrait:"À compléter au fil des échanges")
```
Puis appeler `mnemos_whoami()` pour récupérer le UUID de l'utilisateur (nécessaire à l'étape 4).

---

## Étape 2 : Créer le premier espace

Demander : "Sur quel projet tu travailles en ce moment ? Je vais créer ton premier dossier."

Appeler : `mnemos_create_space(userId:[alias], name:[nom du projet])`

---

## Étape 3 : Les 5 commandes essentielles

Présenter :
- "ouvre [espace]" → charger un projet
- "retiens que..." → mémoriser une info
- "cherche [sujet]" → fouiller la mémoire
- "brief matinal" → résumé du jour (mails, RDV, insights)
- "fin de fil" → sauvegarder et fermer

---

## Étape 4 : Collecte mail/agenda

### Sur macOS
Expliquer : "Mnemos peut collecter automatiquement tes mails et RDV toutes les 2h via Mail.app et Calendar.app. On la configure ?"

Si l'utilisateur accepte, demander :
- Son compte Mail.app (ex: "Google") et la mailbox (ex: "[Gmail]/Tous les messages")
- Son adresse email principale et secondaire éventuelle (pour détecter envoyé/reçu)
- Ses calendriers Calendar.app (ex: "Travail", "Personnel")

### Sur Windows/Linux
La collecte automatique par scheduled task n'est pas disponible (pas de Mail.app/Calendar.app).
Alternative : les connecteurs Anthropic natifs (gmail_*, gcal_*) permettent la collecte en conversation directe.
Expliquer : "Sur ton système, la collecte se fait à la demande. Dis 'brief matinal' ou 'collecte mes mails' et j'utiliserai tes connecteurs Gmail et Google Calendar pour alimenter ta mémoire."
Vérifier que l'utilisateur a bien activé les connecteurs Gmail et Google Calendar dans ses paramètres Claude.
Passer directement à l'étape 5 (pas de tâche à créer).

### Création de la tâche (macOS uniquement, suite de la section macOS ci-dessus)

Puis créer la tâche via `create_scheduled_task` avec ces paramètres :
```
taskId: "mnemos-sync-mail-agenda"
description: "Collecte auto mails + agenda + contacts → Mnemos (toutes les 2h via Mail.app et Calendar.app)"
cronExpression: "0 */2 * * *"
prompt: <copier intégralement le contenu du fichier SYNC-MAIL-AGENDA-PROMPT.md en adaptant les valeurs utilisateur>
```

Le fichier SYNC-MAIL-AGENDA-PROMPT.md (dans ce même dossier skills/mnemos/) contient le prompt complet de la tâche avec les 8 étapes du pipeline. Le LLM DOIT le lire et remplacer les 6 placeholders avant de créer la tâche :
- {{MAIL_ACCOUNT}} : nom du compte Mail.app (ex: "Google")
- {{MAILBOX}} : chemin de la boîte (ex: "[Gmail]/Tous les messages")
- {{USER_EMAIL}} : adresse email principale
- {{USER_EMAIL_ALT}} : adresse secondaire (ou identique à la principale)
- {{CALENDARS}} : liste des calendriers entre guillemets (ex: "Travail", "Personnel")
- {{USER_UUID}} : UUID Mnemos de l'utilisateur (retourné par `mnemos_whoami()` à l'étape 1)

Après la création, expliquer : "Au premier lancement automatique, tu devras approuver les outils Mnemos une fois. Clique sur la tâche active dans la barre latérale, puis 'Toujours autorisé' pour chaque outil. Après ça, tout est automatique."

---

## Étape 5 : Dashboard

"Ton dashboard Mycelora est ici : https://mycelora.ai
Il te permet de visualiser tes espaces, atomes, connexions et l'activité de ta mémoire."

---

## Fin d'onboarding

Présenter le bloc d'accueil standard (voir SKILL.md § Protocole d'ouverture, Étape 2) avec le lien Dashboard.

"Tu es prêt. Dis 'ouvre [ton espace]' pour commencer, ou 'mnemos help' pour voir toutes les commandes."
