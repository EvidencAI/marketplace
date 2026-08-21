---
description: "Installer ou mettre a jour le serveur MCP Mycelora sur cette machine"
---

# Mycelora — Installation du serveur MCP

## Contexte
Le plugin Mycelora fournit les skills (comportement). Le serveur MCP fournit les outils (memoire, recall, extraction).
Cowork ne charge pas encore les serveurs MCP locaux depuis les plugins (bug connu). L'installation configure le serveur MCP dans Claude Desktop.

## Detection
Avant d'afficher les instructions, verifie si les outils mnemos_* sont deja disponibles :
- Si `mnemos_whoami` ou `mnemos_list_spaces` repond → le MCP est deja configure, dis-le a l'utilisateur.
- Sinon → continue avec l'installation.

## Instructions a afficher a l'utilisateur

Affiche ce message :

---

**Mycelora a besoin d'une installation rapide (30 secondes).**

Ouvrez votre Terminal et collez cette commande :

```
curl -sL https://api.mycelora.ai/functions/v1/mycelora-install | bash
```

Ce script va :
1. Telecharger le moteur Mycelora (~3 MB)
2. Le placer dans `~/mycelora-mcp/`
3. Configurer Claude Desktop automatiquement

Apres l'installation, **redemarrez Claude Desktop** puis revenez ici.

---

## Apres le redemarrage

Une fois que l'utilisateur revient :
1. Teste `mnemos_whoami` pour confirmer que le MCP fonctionne
2. Si ca marche, propose `mycelora login` ou `mycelora signup` selon si l'utilisateur a deja un compte
3. Si ca ne marche pas, verifie :
   - Node.js est installe ? (`node -v` dans le terminal)
   - Le fichier `~/mycelora-mcp/index.cjs` existe ?
   - Le fichier `claude_desktop_config.json` contient bien la section mnemos ?

## Mode B (fallback sans Node.js)

Si l'utilisateur ne peut pas installer Node.js ou si le script echoue, les outils Mycelora fonctionnent en mode Edge Function (HTTP).
Ce mode est automatique : le plugin detecte l'absence du MCP local et route les appels vers Supabase.
Limitation du Mode B : pas de Face A (rappel contextuel automatique), pas d'extraction continue.
