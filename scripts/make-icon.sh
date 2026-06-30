#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/source-image"
  exit 1
fi

SOURCE_IMAGE="$1"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/Assets"
ICONSET_DIR="$ASSETS_DIR/AppIcon.iconset"
MASTER_PNG="$ASSETS_DIR/AppIcon-master.png"
ICON_FILE="$ASSETS_DIR/AppIcon.icns"

mkdir -p "$ASSETS_DIR"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Normalize the source to a square canvas so the full mark fits in the icon.
sips -s format png "$SOURCE_IMAGE" --out "$MASTER_PNG" >/dev/null
sips --resampleHeightWidthMax 1024 "$MASTER_PNG" >/dev/null
sips --padToHeightWidth 1024 1024 "$MASTER_PNG" --padColor FFFFFF >/dev/null

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
done

for size in 16 32 128 256 512; do
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$MASTER_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

echo "Generated icon: $ICON_FILE"
