#!/bin/zsh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Resources/dmg-background.svg"
OUT="$ROOT/build/dmg-background.png"
TMP_DIR="$ROOT/build/dmg-background-render"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR" "$(dirname "$OUT")"

qlmanage -t -s 720 -o "$TMP_DIR" "$SVG" >/dev/null 2>&1

RENDERED="$TMP_DIR/$(basename "$SVG").png"
if [ ! -f "$RENDERED" ]; then
  echo "Failed to render $SVG with qlmanage" >&2
  exit 1
fi

mv "$RENDERED" "$OUT"
rm -rf "$TMP_DIR"

python3 - "$OUT" <<'PY'
from pathlib import Path
import sys

from PIL import Image

path = Path(sys.argv[1])
image = Image.open(path).convert("RGBA")
image = image.crop((0, 0, 720, 440))
image.save(path)
PY

echo "$OUT"
