# STORY RP-1 — plugins/mycelora v0.9.0
Sprint RENOMMAGE-PLUGIN. Invariants : 00-transverses.md.

## Périmètre
- Copier plugins/mnemos → plugins/mycelora puis rebrander : manifest
  .claude-plugin/plugin.json (name « mycelora », version 0.9.0, description
  Mycelora avec la baseline « Sous chacun de vos projets, un réseau qui
  relie, retient et apprend »), SKILL.md et textes des skills, hooks
  (textes/commentaires/noms de fichiers, ex. mycelora-stop.sh) + hooks.json
  cohérent, watcher (textes), URL connecteur →
  https://api.mycelora.ai/functions/v1/mycelora-mcp.
- Les appels d'outils mnemos_* et le userId « stephane » NE CHANGENT PAS.
- plugins/mnemos INTACT (zéro diff dessus).

## DoD
- Diff vide sur plugins/mnemos ; plugin mycelora complet et auto-cohérent
  (grep des anciens noms de fichiers de hooks : zéro référence pendante).
- grep -ri mnemos plugins/mycelora/ joint au rapport, chaque occurrence
  restante justifiée (outils mnemos_*, userId).
- Ergonome sur les SKILL.md (textes lus par un humain). Reviewer + testeur
  (le testeur vérifie au minimum la validité JSON des manifests/hooks et la
  cohérence des chemins).
- PR ouverte non mergée. .cc-story-terminee-RP-1.md.
