#!/usr/bin/env bash
# Fabrique le zip du plugin mnemos avec injection du jeton hook. Le jeton ne
# doit JAMAIS apparaitre dans un message, un log ou en argument de commande
# visible (ps aux). Usage :
#   scripts/build-plugin-zip.sh <version> [chemin_jeton]

set -uo pipefail

VERSION="${1:?usage: build-plugin-zip.sh <version> [chemin_jeton]}"
TOKEN_PATH="${2:-/Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/HOOK-KEY.txt}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_SRC="$REPO_ROOT/plugins/mnemos"

if [ ! -f "$TOKEN_PATH" ]; then
  echo "abort: jeton introuvable ou vide" >&2
  exit 1
fi

TOKEN_CONTENT="$(python3 -c "
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    print(f.read().strip())
" "$TOKEN_PATH" 2>/dev/null)"

if [ -z "$TOKEN_CONTENT" ]; then
  echo "abort: jeton introuvable ou vide" >&2
  exit 1
fi

TMPDIR="$(mktemp -d /tmp/mnemos-plugin-build.XXXXXX)"
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

DEST="$TMPDIR/plugin-src/mnemos"
mkdir -p "$DEST/hooks"

if [ ! -f "$PLUGIN_SRC/hooks/hooks.json" ]; then
  echo "abort: plugins/mnemos/hooks/hooks.json introuvable" >&2
  exit 1
fi
cp "$PLUGIN_SRC/hooks/hooks.json" "$DEST/hooks/hooks.json"

shopt -s nullglob
for f in "$PLUGIN_SRC"/hooks/*.sh; do
  cp "$f" "$DEST/hooks/"
done
shopt -u nullglob

if [ -d "$PLUGIN_SRC/.claude-plugin" ]; then
  cp -R "$PLUGIN_SRC/.claude-plugin" "$DEST/.claude-plugin"
fi
if [ -d "$PLUGIN_SRC/commands" ]; then
  cp -R "$PLUGIN_SRC/commands" "$DEST/commands"
fi
if [ -d "$PLUGIN_SRC/skills" ]; then
  cp -R "$PLUGIN_SRC/skills" "$DEST/skills"
fi

# tests/, .git, .DS_Store ne sont jamais copies (non references ci-dessus).

# Injection du jeton : jamais en argument de commande visible. On ecrit le
# jeton dans un fichier temporaire chmod 600, et seul le CHEMIN de ce
# fichier est passe en argument a python3 (jamais le contenu).
TOKEN_FILE_TMP="$(mktemp /tmp/mnemos-build-token.XXXXXX)"
chmod 600 "$TOKEN_FILE_TMP"
printf '%s' "$TOKEN_CONTENT" > "$TOKEN_FILE_TMP"

python3 - "$DEST/hooks" "$TOKEN_FILE_TMP" <<'PYEOF'
import sys, os, glob

hooks_dir, token_file = sys.argv[1], sys.argv[2]
with open(token_file, "r", encoding="utf-8") as f:
    token = f.read()

for path in glob.glob(os.path.join(hooks_dir, "*.sh")):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    content = content.replace("__MNEMOS_HOOK_KEY__", token)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
PYEOF

rm -f "$TOKEN_FILE_TMP"

# Garde-fous bloquants AVANT de zipper.
if grep -rl "__MNEMOS_HOOK_KEY__" "$TMPDIR/plugin-src" >/dev/null 2>&1; then
  echo "abort: placeholder residuel detecte dans la copie, jeton non injecte quelque part" >&2
  exit 1
fi

if find "$TMPDIR/plugin-src" -iname "HOOK-KEY.txt" | grep -q .; then
  echo "abort: fichier jeton detecte dans la copie du plugin" >&2
  exit 1
fi

OUT_DIR="/Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/plugin"
mkdir -p "$OUT_DIR"
OUT_ZIP="$OUT_DIR/plugin-mnemos${VERSION}.zip"
rm -f "$OUT_ZIP"

FILE_LIST="$(cd "$TMPDIR/plugin-src" && find mnemos -type f ! -name ".DS_Store" | sort)"
if [ -z "$FILE_LIST" ]; then
  echo "abort: aucun fichier a zipper" >&2
  exit 1
fi

(
  cd "$TMPDIR/plugin-src" && \
  printf '%s\n' "$FILE_LIST" | zip -X -q "$OUT_ZIP" -@
)

if [ ! -f "$OUT_ZIP" ]; then
  echo "abort: echec de creation du zip" >&2
  exit 1
fi

echo "OK: zip cree -> $OUT_ZIP"
exit 0
