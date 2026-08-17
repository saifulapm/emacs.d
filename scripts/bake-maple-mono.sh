#!/usr/bin/env bash
# Bake the OpenType feature set from ~/.config/ghostty/config into the
# installed Maple Mono variable fonts, producing a `Maple Mono Ghostty`
# family that has those features active by default (so editors like Emacs
# whose font backend can't toggle OT features still get them).
#
# Idempotent: re-running just regenerates the output files.
#
# Requires `pyftfeatfreeze` from `opentype-feature-freezer`:
#   pipx install opentype-feature-freezer   (dnf install pipx)
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

# Source (read) and destination (write) font dirs. The variable Maple Mono is
# unpacked by hand into ~/.local/share/fonts/maple-mono; baked output lands
# beside it in the user font dir so fontconfig picks it up with no root.
# Override either with the environment when the fonts live elsewhere.
SRC_DIR="${SRC_DIR:-$HOME/.local/share/fonts/maple-mono}"
DST_DIR="${DST_DIR:-$HOME/.local/share/fonts}"
mkdir -p "$DST_DIR"

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

# Refresh the font cache so apps see the new files immediately.
if command -v fc-cache >/dev/null 2>&1; then
  fc-cache -f "$DST_DIR" 2>/dev/null || true
fi

echo
echo "Done. Restart your editor; Emacs will pick up 'Maple Mono Ghostty' automatically."
