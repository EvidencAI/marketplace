# Mycelora — Onboarding nouvel utilisateur

Ce flow se déclenche quand `mycelora_session_start` retourne un profil vide ou une erreur "user not found".
Le LLM DOIT lire ce fichier et suivre les étapes dans l'ordre.

---

## Bienvenue

Présenter Mycelora en 3 phrases max :
"Mycelora est ta mémoire persistante entre tes conversations avec Claude. Il retient tes décisions, projets, contacts, et te restitue le contexte pertinent à chaque nouveau fil. Tout est stocké dans ton espace sécurisé."

---

## Étape 1 : Créer le profil

Demander : "Comment tu veux que je t'appelle ? Et quels sont tes principes de travail que je dois toujours garder en tête ?"

Avec la réponse, appeler :
```
mycelora_update_profile(displayName:[prénom ou nom choisi], principles:[tableau de strings], portrait:"À compléter au fil des échanges")
```
Puis appeler `mycelora_list_spaces()` : le champ `user_id` des espaces rendus est l'UUID de l'utilisateur (nécessaire à l'étape 4). Il n'existe pas d'outil `mycelora_whoami`.

---

## Étape 2 : Créer le premier espace

Demander : "Sur quel projet tu travailles en ce moment ? Je vais créer ton premier dossier."

Appeler : `mycelora_create_space(name:[nom du projet])`

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

La collecte tourne côté serveur Mycelora, toutes les 2 h, sur n'importe quel système, ordinateur éteint ou non. Aucune tâche planifiée à créer, rien à laisser tourner en local.

Expliquer : "Mycelora peut lire tes mails et ton agenda toutes les deux heures pour garder le fil de tes échanges et de tes engagements. Le texte des mails est effacé 7 jours après le tri. On branche une boîte ?"

Si l'utilisateur accepte, deux chemins :
- **Dashboard, page Connexions** (https://mycelora.ai) : le plus simple. Mail par IMAP (Gmail, Outlook, iCloud, OVH, Free, Orange et autres), agenda Google par consentement, agendas CalDAV.
- **En conversation** : `mycelora_create_source` pour une boîte IMAP ou un agenda CalDAV (la connexion est testée avant toute création, le secret n'est posé que si le test réussit) ; `mycelora_google_consent_url` pour l'agenda Google (lien de consentement à ouvrir par l'utilisateur).

Mot de passe : chez les fournisseurs qui en proposent un (Gmail, Outlook, iCloud), toujours un mot de passe d'application, jamais le mot de passe principal du compte ; chez les autres (OVH, Free, Orange), le mot de passe de la boîte mail. Ne jamais créer de tâche planifiée de collecte (l'ancienne tâche Mail.app / Calendar.app est abandonnée).

---

## Étape 5 : Dashboard

"Ton dashboard Mycelora est ici : https://mycelora.ai
Il te permet de visualiser tes espaces, atomes, connexions et l'activité de ta mémoire."

---

## Fin d'onboarding

Présenter le bloc d'accueil standard (voir SKILL.md § Protocole d'ouverture, Étape 2) avec le lien Dashboard.

"Tu es prêt. Dis 'ouvre [ton espace]' pour commencer, ou 'mycelora help' pour voir toutes les commandes."
