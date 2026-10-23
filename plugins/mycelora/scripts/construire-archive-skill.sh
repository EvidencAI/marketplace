#!/bin/bash
# Construit l'archive du skill Mycelora pour ChatGPT navigateur (onglet Skills,
# Importer depuis votre ordinateur) et Perplexity (Skills, Téléverser le Skill).
#   scripts/construire-archive-skill.sh <sortie.zip>
# Racine de l'archive : mycelora/ = contenu de skills/mycelora/ + LICENSE.
# Jamais .claude-plugin, .codex-plugin, .mcp.json ni hooks : ChatGPT web refuse
# une archive qui porte un serveur MCP, et une forme plugin s'y affiche sans icône.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage : $0 <sortie.zip>" >&2; exit 2; }
RACINE=$(cd "$(dirname "$0")/.." && pwd)
SORTIE=$1
case "$SORTIE" in /*) ;; *) SORTIE="$PWD/$SORTIE" ;; esac
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/mycelora"
cp -R "$RACINE/skills/mycelora/." "$TMP/mycelora/"
cp "$RACINE/LICENSE" "$TMP/mycelora/LICENSE"
find "$TMP" -name .DS_Store -delete
find "$TMP" -exec touch -t 202601010000 {} +
rm -f "$SORTIE"
(cd "$TMP" && find mycelora -type f | LC_ALL=C sort | zip -X -D -q "$SORTIE" -@)
echo "$SORTIE"
