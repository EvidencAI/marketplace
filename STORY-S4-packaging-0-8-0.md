# STORY S4 — Packaging plugin mnemos v0.8.0

Sprint MNEMOS-V3-INJECTION, story 4/5. Rédigé le 14/07/2026 (fil Cowork S3/S4).
Repo de travail : evidencai-marketplace (CE repo). Point de départ : main = 6ba7e4e
(S3 mergée : hooks watcher v3 + build-plugin-zip.sh + tests, tout est sur main).
Branche : feat/s4-packaging-0-8-0. PR ouverte NON mergée. Contexte amont :
S1/S2 en prod côté edge, S3 mergée côté plugin. Décisions Q1-Q11 tranchées
(MNEMOS 07 26/MNEMOS-V3-AUDIT-REPONSES.md). PAS de re-audit.

## Objectif et DoD

Un zip plugin-mnemos0.8.0.zip prêt à uploader, un SKILL.md aligné sur la
réalité post-watcher-v3, zéro trace de l'ancien jeton mort, et la doc de
packaging à jour. DoD :
- plugin.json à 0.8.0, SKILL.md cohérent avec les 35 outils réels et le
  watcher v3, tests du repo toujours verts.
- Zip 0.8.0 construit par scripts/build-plugin-zip.sh, garde-fous passés.
- .mcp.json mort purgé de la copie de travail (hors repo).
- references/packaging-mnemos.md du skill evidencai-ops mis à jour.
- Checklist de smoke fil neuf rédigée pour Stéphane (il l'exécute lui-même).

## Item 1 — plugin.json (plugins/mnemos/.claude-plugin/plugin.json)

- version : 0.8.0.
- description : mise à jour. Retirer la mention quick_boot (l'outil n'existe
  pas côté edge). Mentionner : watcher v3 embarqué (hooks UserPromptSubmit et
  Stop : injection FACE-A par message + collecte automatique des échanges).
- Champ author.name : contient actuellement "EvidencAI v0.7.1", une version
  fossilisée dans le nom d'auteur. Nettoyer en "EvidencAI".

## Item 2 — SKILL.md (plugins/mnemos/skills/mnemos/SKILL.md) et fichiers frères

Aligner sur la réalité post-S1/S2/S3. Points OBLIGATOIRES :
- Section "COMPORTEMENT AUTOMATIQUE / Extraction d'atomes" : le paragraphe
  "transcript-watcher local HORS SERVICE, pas d'extraction automatique" est
  PÉRIMÉ dès que le plugin 0.8.0 est installé. Remplacer par la réalité
  watcher v3 : injection FACE-A à chaque message utilisateur (hook
  UserPromptSubmit → mnemos_recall) et collecte automatique de chaque
  échange (hook Stop → mnemos_log_exchange → raw_exchanges → cron
  extract-from-exchanges → atomes auto_buffer). La création proactive
  d'atomes reste recommandée pour les décisions importantes, mais n'est
  plus le seul canal.
- get_context : réparé (pipeline hybride réel), le brief matinal fonctionne.
- mnemos_admin : déclaré, 35 outils exposés au total (plus 33).
- Codex : injecté au boot (session_start inclut le codex Mémoire générale)
  et régénéré automatiquement à la clôture (session_end, Haiku, fail-soft).
- Retirer TOUTE mention résiduelle de quick_boot dans SKILL.md, REFERENCE.md,
  FALLBACK-MODE-B.md, ONBOARDING.md, commands/ (vérifier par grep, ne
  corriger que ce qui est réellement périmé, ne pas réécrire le reste).
- Ajouter une courte section "Watcher v3 (hooks du plugin)" : ce que font
  les deux hooks, le log local /tmp/mnemos-hook.log, le fait que les filtres
  ignorent les messages système et les prompts trop courts, et la limite
  connue (wakeup au libellé libre non filtré).

## Item 3 — Purge du jeton mort (HORS repo, fichier disque)

/Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/plugin/mnemos/.mcp.json
contient l'ancien jeton révoqué (78f25137...), mort mais sale. Supprimez CE
fichier .mcp.json uniquement (autorisé par le brief, pas de validation
supplémentaire requise). Ne touchez à RIEN d'autre dans ce dossier : c'est
une copie de travail historique, signalez simplement dans votre résumé ce
que vous y voyez d'obsolète sans y toucher.

## Item 4 — Doc packaging (skill evidencai-ops)

Le fichier references/packaging-mnemos.md du skill evidencai-ops date de
mars et est obsolète. Localisez-le (cherchez sous
/Users/stephanecommenge/Claude-Dev/evidencai-skills/ ou via mdfind ; si
introuvable, signalez-le et passez, ne créez PAS un fichier au hasard).
Mettez-le à jour : .mcp.json supprimé du plugin depuis 0.7.0 ; source edge =
MNEMOS 07 26/edge-function (repo mnemos-edge, deploy --no-verify-jwt) ;
packaging = scripts/build-plugin-zip.sh du repo marketplace (injection du
jeton hook au zip, placeholder __MNEMOS_HOOK_KEY__ dans le git, garde-fous) ;
hooks/ dans l'arborescence du plugin depuis 0.8.0. Si ce fichier vit dans un
repo git, committez sur une branche du repo concerné et signalez-le (pas de
push forcé, pas de merge).

## Item 5 — Zip final

scripts/build-plugin-zip.sh 0.8.0 (jeton par défaut HOOK-KEY.txt). Vérifiez
le contenu du zip (liste des fichiers, présence hooks/, absence tests/,
.mcp.json, .DS_Store). Le zip reste dans MNEMOS 07 26/plugin/, ne le
supprimez PAS cette fois : c'est le livrable que Stéphane uploadera.

## Item 6 — Checklist smoke fil neuf (Phase 4 du brief sprint)

Rédigez SMOKE-0-8-0.md à la racine du repo : les étapes que Stéphane
exécutera à la main. Upload du zip 0.8.0 (remplace le 0.7.3-test), fil
Cowork neuf, vérifier : (1) bloc FACE-A visible dès le premier tour et à
chaque message, latence perçue acceptable ; (2) après 3 échanges et ~10 min,
lignes raw_exchanges du fil en base avec processed=true et atomes
auto_buffer dans le bon espace ; (3) get_stats ~10,3k et health_check propre ;
(4) rollback : zip 0.7.1 conservé, jeton hook révocable seul.

## Hors scope

- S5 (purge des blocs statiques des instructions globales Cowork) : fil Cowork.
- Toute modification du code edge (MNEMOS 07 26/edge-function : lecture seule).
- Toute modification des scripts hooks eux-mêmes (S3 est mergée ; si vous
  voyez un bug, signalez-le, ne le corrigez pas dans cette story).
- L'upload du zip et le test fil neuf : gestes de Stéphane.

## Pièges à éviter

1. VOUVOIEMENT, pas de tiret long, branche feat/s4-packaging-0-8-0,
   PR ouverte non mergée.
2. Jamais le jeton ni l'api_key en clair où que ce soit.
3. SKILL.md est de la doc UTILISATEUR : sobre, factuelle, pas de jargon
   interne (pas de mention de MNEMOS_HOOK_KEY ni des chemins Mac).
4. Ne lancez jamais de commande tmux.
5. Relancez les tests du repo (unitaires au minimum) après vos modifications
   pour vérifier que rien n'est cassé, même si vous ne touchez pas aux
   scripts.
6. Avant tout geste prod non listé ici : "je m'apprête à X via Y, OK ?" et
   attente de validation de Stéphane.
