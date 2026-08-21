#!/usr/bin/env bash
# Fabrique le zip d'un plugin (mnemos ou mycelora) avec injection du jeton
# hook. Le jeton ne doit JAMAIS apparaitre dans un message, un log ou en
# argument de commande visible (ps aux). Usage :
#   scripts/build-plugin-zip.sh <version> [chemin_jeton] [plugin]
# Le troisieme argument vaut "mnemos" par defaut (compatibilite avec les
# appels historiques). Le placeholder du jeton et le nom du zip sont derives
# du nom du plugin : __MNEMOS_HOOK_KEY__ / plugin-mnemos<version>.zip pour
# mnemos, __MYCELORA_HOOK_KEY__ / plugin-mycelora-<version>.zip sinon.

set -uo pipefail

VERSION="${1:?usage: build-plugin-zip.sh <version> [chemin_jeton] [plugin]}"
TOKEN_PATH="${2:-/Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/HOOK-KEY.txt}"
PLUGIN="${3:-mnemos}"
PLUGIN_UPPER="$(printf '%s' "$PLUGIN" | tr '[:lower:]-' '[:upper:]_')"
PLACEHOLDER="__${PLUGIN_UPPER}_HOOK_KEY__"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_SRC="$REPO_ROOT/plugins/$PLUGIN"

if [ ! -d "$PLUGIN_SRC" ]; then
  echo "abort: plugins/$PLUGIN introuvable" >&2
  exit 1
fi

if [ ! -f "$TOKEN_PATH" ]; then
  echo "abort: jeton introuvable ou vide" >&2
  exit 1
fi

# Le fichier jeton porte des lignes de commentaire (#...) avant la ligne du
# jeton, qui est elle-meme au format NOM_VARIABLE=valeur : on ignore les
# lignes vides et celles commencant par #, et sur la premiere ligne valide
# restante on ne garde que la partie apres le premier '=' (ou la ligne
# entiere si elle ne contient pas de '=').
TOKEN_CONTENT="$(python3 -c "
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    for line in f:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        value = stripped.split('=', 1)[1] if '=' in stripped else stripped
        print(value)
        break
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

DEST="$TMPDIR/plugin-src/$PLUGIN"
mkdir -p "$DEST/hooks"

if [ ! -f "$PLUGIN_SRC/hooks/hooks.json" ]; then
  echo "abort: plugins/$PLUGIN/hooks/hooks.json introuvable" >&2
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

python3 - "$DEST/hooks" "$TOKEN_FILE_TMP" "$PLACEHOLDER" <<'PYEOF'
import sys, os, glob

hooks_dir, token_file, placeholder = sys.argv[1], sys.argv[2], sys.argv[3]
with open(token_file, "r", encoding="utf-8") as f:
    token = f.read()

for path in glob.glob(os.path.join(hooks_dir, "*.sh")):
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    content = content.replace(placeholder, token)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
PYEOF

rm -f "$TOKEN_FILE_TMP"

# Garde-fous bloquants AVANT de zipper.
if grep -rl "$PLACEHOLDER" "$TMPDIR/plugin-src" >/dev/null 2>&1; then
  echo "abort: placeholder residuel detecte dans la copie, jeton non injecte quelque part" >&2
  exit 1
fi

if find "$TMPDIR/plugin-src" -iname "HOOK-KEY.txt" | grep -q .; then
  echo "abort: fichier jeton detecte dans la copie du plugin" >&2
  exit 1
fi

OUT_DIR="/Users/stephanecommenge/Claude-Dev/MNEMOS 07 26/plugin"
mkdir -p "$OUT_DIR"
if [ "$PLUGIN" = "mnemos" ]; then
  OUT_ZIP="$OUT_DIR/plugin-mnemos${VERSION}.zip"
else
  OUT_ZIP="$OUT_DIR/plugin-${PLUGIN}-${VERSION}.zip"
fi
rm -f "$OUT_ZIP"

FILE_LIST="$(cd "$TMPDIR/plugin-src" && find "$PLUGIN" -type f ! -name ".DS_Store" | sort)"
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
