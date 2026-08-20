# SPRINT RENOMMAGE-PLUGIN — le plugin Mycelora (marketplace)
Fil 57, 20/08/2026. Cadrage Cowork + Stéphane. Inventaire de référence :
"/Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/INVENTAIRE-RENOMMAGE-MYCELORA.md"
(section Plugin & connecteur, 22 items).

## Contexte
Produit renommé Mycelora. Stéphane est le SEUL utilisateur : le slug du
plugin peut changer proprement maintenant. La source de vérité du plugin en
production est plugins/mnemos (v0.8.6) DANS CE REPO (la copie
"MNEMOS 07 26/plugin/mnemos" v0.6.9 est OBSOLÈTE, ne pas s'y fier).

## Objectif
Un plugin plugins/mycelora v0.9.0 complet, rebrandé, prêt à être publié,
SANS toucher à plugins/mnemos (compat pendant la transition ; il sera
retiré en fin de sprint global, après migration de la machine de Stéphane).

## Conventions figées
- Nom produit : « Mycelora ». Slug plugin : mycelora. Version : 0.9.0.
- URL connecteur cible : https://api.mycelora.ai/functions/v1/mycelora-mcp
  (contrat figé avec le sprint edge ; les anciens endpoints restent vivants).
- GELÉ : les noms des outils MCP mnemos_* appelés par les hooks et skills
  (contrat backend inchangé), le userId « stephane » codé en dur dans les
  hooks (dette produit CONNUE et ASSUMÉE, hors périmètre : ne pas corriger,
  ne pas signaler en boucle).
- Textes des skills (start, install, session start/end...) : rebrandés
  Mycelora, le protocole (session_start, spaceId, codex...) reste IDENTIQUE.

## Stories
RP-1 le plugin mycelora ; RP-2 catalogue marketplace.

## Doctrine
cc-autonome-workflow.md v2.2 : signaux .cc-*, reviewer + testeur après
chaque story, ergonome sur les textes lus par un humain (les SKILL.md en
font partie), /clear entre stories, jamais de merge, jamais de menu
interactif. PAS de re-audit.

## Ressources partagées
Quota API Anthropic partagé avec deux autres CC.

## Hors scope
Publication marketplace effective, retrait de plugins/mnemos, la machine
locale de Stéphane (~/.claude, ~/mnemos-mcp), le bucket de distribution,
le dashboard, les edge functions.

## Pièges connus
1. Les hooks shell (mnemos-stop.sh, mnemos-userpromptsubmit.sh) appellent
   des outils mnemos_* : ces NOMS ne changent pas. Seuls les textes, noms
   de fichiers de hooks, commentaires et le manifest changent.
2. Renommer des fichiers de hooks implique de mettre à jour hooks.json (ou
   équivalent) : cohérence totale ou rien.
3. Le watcher v3 (face-a) : rebrand des textes seulement, pas de logique.
4. Pas de commande git destructive en revue.
