#!/usr/bin/env bash
# Bake the OpenType feature set from ~/.config/ghostty/config into the
# installed Maple Mono variable fonts, producing a `Maple Mono Ghostty`
# family that has those features active by default (so editors like Emacs
# whose font backend can't toggle OT features still get them).
#
# Idempotent: re-running just regenerates the output files.
#
# Requires `pyftfeatfreeze` from `opentype-feature-freezer`.
#   macOS:  brew install pipx && pipx install opentype-feature-freezer
#   Linux:  pipx install opentype-feature-freezer  (or apt install pipx)
#
# Source fonts must already be installed. Download the variable Maple Mono
# from https://github.com/subframe7536/maple-font/releases (files named
# `MapleMono[wght].ttf` and `MapleMono-Italic[wght].ttf`).

set -euo pipefail

# Match ghostty's `font-feature = calt, cv03, cv62, cv63, cv64, cv31, cv32,
# ss09, ss10, ss11`. Only cv* features can be frozen (single/alternate
# substitutions); calt and ss* are contextual ligatures handled by Emacs
# `ligature.el` instead.
FEATURES="cv03,cv31,cv32,cv62,cv63,cv64,ss03,ss07,ss08,ss09,ss10,ss11,zero"

# Source (read) and destination (write) font dirs. macOS keeps both in
# ~/Library/Fonts (the variable Maple Mono is installed there by hand). On
# Linux the source comes from the AUR `maplemono-variable` package, which
# unpacks to /usr/share/fonts/MapleMono-Variable/ — read-only system path,
# so baked output goes to the user font dir instead.
if [[ "$(uname)" == "Darwin" ]]; then
  SRC_DIR="$HOME/Library/Fonts"
  DST_DIR="$HOME/Library/Fonts"
else
  SRC_DIR="/usr/share/fonts/MapleMono-Variable"
  DST_DIR="$HOME/.local/share/fonts"
  mkdir -p "$DST_DIR"
fi

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing '$1' — install opentype-feature-freezer first" >&2
    exit 1
  }
}

bake() {
  local src="$1" dst="$2" name="$3"
  if [[ ! -f "$src" ]]; then
    echo "skip: $name not installed ($src missing)"
    return
  fi
  pyftfeatfreeze -f "$FEATURES" -S -U Ghostty "$src" "$dst"
  echo "ok:   $name → $(basename "$dst")"
}

require pyftfeatfreeze

bake "$SRC_DIR/MapleMono[wght].ttf"        "$DST_DIR/MapleMono-Ghostty[wght].ttf"        "Regular"
bake "$SRC_DIR/MapleMono-Italic[wght].ttf" "$DST_DIR/MapleMono-Ghostty-Italic[wght].ttf" "Italic"

# Refresh the font cache on Linux so apps see the new files immediately.
if command -v fc-cache >/dev/null 2>&1; then
  fc-cache -f "$DST_DIR" 2>/dev/null || true
fi

echo
echo "Done. Restart your editor; Emacs will pick up 'Maple Mono Ghostty' automatically."
