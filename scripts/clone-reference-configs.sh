#!/usr/bin/env bash
# clone-reference-configs.sh
#
# Clone a curated set of public Emacs configurations as reference material.
# Useful for "how do other people do X" — grep across the whole pile.
#
# Usage:
#   ./clone-reference-configs.sh              # default settings
#   DEST=/some/path  ./clone-reference-configs.sh
#   FULL=1           ./clone-reference-configs.sh    # full git history (slow)
#   JOBS=8           ./clone-reference-configs.sh    # parallel clones
#
# Defaults:
#   DEST=~/.config/emacs/references
#   FULL=0  (shallow clone with --depth 1)
#   JOBS=4
#
# The script is idempotent — repos that already exist on disk are skipped.
# Failed clones don't abort the run; a summary at the end reports successes
# and failures.

set -uo pipefail

DEST="${DEST:-$HOME/.config/emacs/references}"
FULL="${FULL:-0}"
JOBS="${JOBS:-4}"

if [ "$FULL" = "1" ]; then
  CLONE_FLAGS=""
else
  CLONE_FLAGS="--depth 1 --single-branch"
fi

# Color helpers — only emit ANSI if stdout is a TTY
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_DIM=""; C_GREEN=""; C_RED=""; C_BLUE=""
fi

# Repo list — one per line: name|git-url|branch
# Sorted alphabetically by name. The `dmacs` entry pulls a separate branch
# of the same repo as `daniel-kraus` (Daniel's macOS-flavoured branch).
# `andrew_emacs` is the entire andreyorst/dotfiles monorepo; the emacs config
# lives at .config/emacs/ inside it.
REPOS=$(cat <<'EOF'
aaron-culich|https://github.com/aculich/.emacs.d|master
alain-lafon|https://github.com/munen/emacs.d|master
alex-kost|https://github.com/alezost/emacs-config|master
andrew_emacs|https://gitlab.com/andreyorst/dotfiles|master
bailey-ling|https://github.com/bling/dotemacs|master
chen-bin|https://github.com/redguardtoo/emacs.d|master
chris-barrett|https://github.com/chrisbarrett/.emacs.d|master
christopher-wellons|https://github.com/skeeto/.emacs.d|master
chunyang-xu|https://github.com/xuchunyang/emacs.d|master
damien-cassou|https://github.com/DamienCassou/emacs.d|master
daniel-kraus|https://github.com/dakra/dmacs|master
dmacs|https://github.com/dakra/dmacs|mac
dmytro-lispyvnyi|https://github.com/a13/emacs.d|master
enzuru|https://github.com/enzuru/.emacs.d|master
howard-abrams|https://github.com/howardabrams/dot-files|master
ista-zahn|https://github.com/izahn/dotemacs|master
ivan-malison|https://github.com/IvanMalison/dotfiles|master
jason-milkins|https://github.com/ocodo/.emacs.d|master
jay-dixit|https://github.com/incandescentman/Emacs-Settings|master
jim-myhrberg|https://github.com/jimeh/.emacs.d|master
joe-di-castro|https://github.com/joedicastro/dotfiles|master
john-wiegley|https://github.com/jwiegley/dot-emacs|master
joost-diepenmaat|https://github.com/joodie/emacs-literal-config|master
jordon-biondo|https://github.com/jordonbiondo/.emacs.d|master
jorgen-schaefer|https://github.com/jorgenschaefer/Config|master
julien-fantin|https://github.com/julienfantin/.emacs.d|master
junpeng-qiu|https://github.com/cute-jumper/.emacs.d|master
justin-talbott|https://github.com/waymondo/hemacs|main
karl-voit|https://github.com/novoid/dot-emacs|master
karthink-chikmagalur|https://github.com/karthink/.emacs.d|master
kaushal-modi|https://github.com/kaushalmodi/.emacs.d|master
lars-andersen|https://github.com/expez/.emacs.d|master
lars-tveito|https://github.com/larstvei/dot-emacs|main
magnar-sveen|https://github.com/magnars/.emacs.d|master
matthew-bauer|https://github.com/matthewbauer/bauer|master
matthew-zeng|https://github.com/MatthewZMD/.emacs.d|master
matus-goljer|https://github.com/Fuco1/.emacs.d|master
musa-alhassy|https://github.com/alhassy/emacs.d|master
nathan-typanski|https://github.com/nathantypanski/emacs.d|master
nicholas-vollmer|https://github.com/progfolio/.emacs.d|master
nicolas-petton|https://github.com/NicolasPetton/emacs.d|master
oleh-krehel|https://github.com/abo-abo/oremacs|github
ono-hiroko|https://github.com/kuanyui/.emacs.d|master
phil-hagelberg|https://git.sr.ht/~technomancy/dotfiles|main
protesilaos-stavrou|https://gitlab.com/protesilaos/dotfiles|master
pythonnut|https://github.com/PythonNut/emacs-config|dev
radon-rosborough|https://github.com/raxod502/radian|develop
rahul-juliato|https://github.com/LionyxML/emacs-solo|main
ryan-thompson|https://github.com/DarwinAwardWinner/dotemacs|talos
sacha-chua|https://github.com/sachac/.emacs.d|gh-pages
samuel-tonini|https://github.com/tonini/emacs.d|master
steckerhalter|https://github.com/marcwebbie/steckemacs.el|master
steve-purcell|https://github.com/purcell/emacs.d|main
syohei-yoshida|https://github.com/syohex/dot_files|main
taichi-kawabata|https://github.com/kawabata/dotfiles|master
tecosaur|https://github.com/tecosaur/emacs-config|master
terencio-agozzino|https://github.com/rememberYou/.emacs.d|master
thierry-volpiatto|https://github.com/thierryvolpiatto/emacs-config|main
tianxiang-xiong|https://github.com/xiongtx/.emacs.d|master
vasilij-schneidermann|https://depp.brause.cc/dotemacs.git|master
wilfred-hughes|https://github.com/Wilfred/.emacs.d|gh-pages
xenodium|https://github.com/xenodium/dotsies|main
yuta-yamada|https://github.com/yuutayamada/emacs.d|master
EOF
)

total=$(printf "%s\n" "$REPOS" | grep -cv '^$')
mkdir -p "$DEST"

printf "%bClone reference configs%b\n" "$C_BLUE" "$C_RESET"
printf "%b  dest: %s%b\n" "$C_DIM" "$DEST" "$C_RESET"
printf "%b  mode: %s%b\n" "$C_DIM" "$([ "$FULL" = "1" ] && echo "full history" || echo "shallow")" "$C_RESET"
printf "%b  jobs: %s%b\n" "$C_DIM" "$JOBS" "$C_RESET"
printf "%b  repos: %s%b\n\n" "$C_DIM" "$total" "$C_RESET"

# Per-repo clone (used both serially and in parallel)
clone_one() {
  local name="$1" url="$2" branch="$3"
  local target="$DEST/$name"
  if [ -d "$target/.git" ]; then
    printf "%b  ↷ skip %-26s (exists)%b\n" "$C_DIM" "$name" "$C_RESET"
    return 0
  fi
  if git clone $CLONE_FLAGS --branch "$branch" "$url" "$target" \
       >/dev/null 2>"$target.err"; then
    rm -f "$target.err"
    printf "%b  ✓ %-28s %s%b\n" "$C_GREEN" "$name" "$branch" "$C_RESET"
    return 0
  else
    local why
    why=$(tail -1 "$target.err" 2>/dev/null)
    rm -f "$target.err"
    rm -rf "$target"
    printf "%b  ✗ %-28s %s — %s%b\n" "$C_RED" "$name" "$branch" "$why" "$C_RESET" >&2
    return 1
  fi
}
export -f clone_one
export DEST CLONE_FLAGS C_RESET C_DIM C_GREEN C_RED

# Parallel via xargs: each line gets fed as one argument; bash -c re-parses
# the pipe-separated fields. `xargs -P 0` would mean "as many as possible";
# we cap with JOBS.
printf "%s\n" "$REPOS" | grep -v '^$' \
  | xargs -P "$JOBS" -I{} bash -c '
      IFS="|" read -r name url branch <<< "{}"
      clone_one "$name" "$url" "$branch"
    '

# Final summary
echo ""
ok=0; fail=0
for line in $REPOS; do
  [ -z "$line" ] && continue
  name="${line%%|*}"
  if [ -d "$DEST/$name/.git" ]; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done

printf "%bDone.%b  %b%d ok%b  %b%d failed%b  (of %d total)\n" \
  "$C_BLUE" "$C_RESET" \
  "$C_GREEN" "$ok" "$C_RESET" \
  "$C_RED" "$fail" "$C_RESET" \
  "$total"

[ "$fail" -eq 0 ] || exit 1
