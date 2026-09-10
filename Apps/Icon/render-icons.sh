#!/bin/sh
# Renders the app icon assets from the SVG masters into the asset catalog.
# The masters in this directory are the one source of the artwork; every
# file this script writes is generated and ignored by git.
set -eu

ICON_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_SET="$ICON_DIR/../Assets.xcassets/AppIcon.appiconset"
GLYPH_SET="$ICON_DIR/../Assets.xcassets/JellyBlairGlyph.imageset"

# Renders one SVG master at one pixel size into the icon set.
render() {
	svg="$1" size="$2" out="$3"
	qlmanage -t -s "$size" -o "$ICON_SET" "$ICON_DIR/$svg" >/dev/null 2>&1
	mv "$ICON_SET/$svg.png" "$ICON_SET/$out"
}

# Removes the alpha channel, which the App Store rejects on the iOS icon.
strip_alpha() {
	python3 -c '
import sys
from PIL import Image
Image.open(sys.argv[1]).convert("RGB").save(sys.argv[1])
' "$1"
}

python3 -c 'import PIL' 2>/dev/null || {
	echo "render-icons.sh needs Pillow: python3 -m pip install Pillow" >&2
	exit 1
}

render jellyblair-icon.svg 1024 ios-1024.png
strip_alpha "$ICON_SET/ios-1024.png"

# The Mac icon carries its margins and shadow in the artwork, and each
# point size ships at one and two pixels per point.
render jellyblair-icon-macos.svg 16 mac-16.png
render jellyblair-icon-macos.svg 32 mac-16@2x.png
render jellyblair-icon-macos.svg 64 mac-32@2x.png
render jellyblair-icon-macos.svg 128 mac-128.png
render jellyblair-icon-macos.svg 256 mac-256.png
render jellyblair-icon-macos.svg 512 mac-512.png
render jellyblair-icon-macos.svg 1024 mac-512@2x.png
cp "$ICON_SET/mac-16@2x.png" "$ICON_SET/mac-32.png"
cp "$ICON_SET/mac-256.png" "$ICON_SET/mac-128@2x.png"
cp "$ICON_SET/mac-512.png" "$ICON_SET/mac-256@2x.png"

# The glyph ships as the SVG itself, which Xcode rasterizes at build time.
cp "$ICON_DIR/jellyblair-glyph.svg" "$GLYPH_SET/jellyblair-glyph.svg"

echo "Rendered app icons into $ICON_SET"
