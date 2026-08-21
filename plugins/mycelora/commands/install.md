---
description: "Installer ou mettre a jour le serveur MCP Mycelora sur cette machine"
---

# Mycelora — Installation du serveur MCP

## Contexte
Le plugin Mycelora fournit les skills (comportement). Les outils MCP (mémoire, recall, extraction) sont fournis par deux canaux distincts et indépendants — il n'y a plus de bundle local a installer.

## Détection
Avant d'afficher les instructions, vérifie si les outils mnemos_* sont déjà disponibles :
- Si `mnemos_whoami` ou `mnemos_list_spaces` répond → un canal est déjà configuré, dis-le a l'utilisateur.
- Sinon → continue avec l'installation.

## Instructions a afficher a l'utilisateur

Affiche ce message :

---

**Mycelora fonctionne via deux canaux, au choix (ou les deux ensemble) :**

**1. Ce plugin Cowork**
Installé depuis le marketplace EvidencAI, il fournit les skills et les hooks automatiques (rappel contextuel, extraction). Rien a configurer une fois le plugin activé.

**2. Le connecteur Mycelora (claude.ai / Claude Desktop)**
Pour accéder aux outils mémoire (espaces, atomes, recall...) depuis claude.ai ou Claude Desktop, ajoutez le connecteur distant :
- Serveur MCP : `https://api.mycelora.ai/functions/v1/mycelora-mcp`
- Authentification : OAuth via le connecteur, ou clé API `mk_live_...` créée depuis le dashboard [https://mycelora.ai](https://mycelora.ai)

Aucune installation locale n'est nécessaire — pas de script, pas de bundle a télécharger.

---

## Après configuration

Une fois que l'utilisateur revient :
1. Teste `mnemos_whoami` pour confirmer que le canal fonctionne.
2. Si ça marche, propose `mycelora login` ou `mycelora signup` selon si l'utilisateur a déjà un compte.
3. Si ça ne marche pas, vérifie :
   - Le connecteur Mycelora est bien ajouté et activé dans claude.ai / Claude Desktop ?
   - L'authentification (OAuth ou clé API `mk_live_...`) a bien abouti ?
   - Le dashboard https://mycelora.ai confirme un compte actif ?
