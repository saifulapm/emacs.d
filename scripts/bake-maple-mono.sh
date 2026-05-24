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
FEATURES="cv03,cv31,cv32,cv62,cv63,cv64"

# Platform-specific font directory.
if [[ "$(uname)" == "Darwin" ]]; then
  FONT_DIR="$HOME/Library/Fonts"
else
  FONT_DIR="$HOME/.local/share/fonts"
  mkdir -p "$FONT_DIR"
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

bake "$FONT_DIR/MapleMono[wght].ttf"        "$FONT_DIR/MapleMono-Ghostty[wght].ttf"        "Regular"
bake "$FONT_DIR/MapleMono-Italic[wght].ttf" "$FONT_DIR/MapleMono-Ghostty-Italic[wght].ttf" "Italic"

# Refresh the font cache on Linux so apps see the new files immediately.
if command -v fc-cache >/dev/null 2>&1; then
  fc-cache -f "$FONT_DIR" 2>/dev/null || true
fi

echo
echo "Done. Restart your editor; Emacs will pick up 'Maple Mono Ghostty' automatically."
