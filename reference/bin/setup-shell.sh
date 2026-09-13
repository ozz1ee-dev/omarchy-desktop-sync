#!/usr/bin/env bash
# omarchy-desktop :: setup-shell
#
# Appends to your shell rc a line that loads the aliases from this repo (omx/omr).
# Idempotent: running it again duplicates nothing, and an old hand-written alias
# block is replaced by a single source line.
#
# Run automatically by import.sh (that is, by `omr` / `yadm bootstrap`).
# By hand:
#   setup-shell.sh            append/refresh the entry
#   setup-shell.sh --remove   remove the entry
#   setup-shell.sh --dry-run  show what would happen

set -euo pipefail

# English messages regardless of your locale (git ships its own translations)
export LC_MESSAGES=C
BASE="$HOME/.config/omarchy-desktop"
if [ -f "$BASE/settings" ]; then . "$BASE/settings"; fi
DOTFILES_REPO="${DOTFILES_REPO:-}"
MARK_BEGIN="# >>> omarchy-desktop aliases >>>"
MARK_END="# <<< omarchy-desktop aliases <<<"
LEGACY_BEGIN="# --- omarchy-desktop: desktop sync ---"
LEGACY_END="# --- end omarchy-desktop ---"
SOURCE_LINE='[ -f "$HOME/.config/omarchy-desktop/aliases.zsh" ] && source "$HOME/.config/omarchy-desktop/aliases.zsh"'

DRY_RUN=0; REMOVE=0
for arg in "$@"; do
  case "$arg" in
    --remove)      REMOVE=1 ;;
    -n|--dry-run)  DRY_RUN=1 ;;
    -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

info() { printf '   %s\n' "$*"; }

# --- which rc? ----------------------------------------------------------------
login_shell="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7 || true)"
[ -n "$login_shell" ] || login_shell="${SHELL:-}"
case "$(basename "$login_shell")" in
  zsh)  rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
  bash) rc="$HOME/.bashrc" ;;
  *)    rc=""
      info "shell '${login_shell:-unknown}' is neither zsh nor bash - add this to your rc by hand:"
      info "  $SOURCE_LINE"
      exit 0
      ;;
esac
info "shell: $(basename "$login_shell") | file: $rc"

if [ ! -e "$rc" ]; then
  if (( REMOVE )); then info "no $rc - nothing to remove"; exit 0; fi
  if (( DRY_RUN )); then info "[dry-run] I would create $rc with the entry"; exit 0; fi
  : > "$rc"
  info "created $rc"
fi

if [ ! -e "$BASE/aliases.zsh" ]; then
  info "WARNING: no $BASE/aliases.zsh - the entry has nothing to load"
fi

strip_blocks() {
  local file="$1"
  sed -i \
    -e "/^# >>> omarchy-desktop aliases >>>$/,/^# <<< omarchy-desktop aliases <<<$/d" \
    -e "/^# --- omarchy-desktop: desktop sync ---$/,/^# --- end omarchy-desktop ---$/d" \
    "$file"
  # drop any blank lines at the end, leave exactly one
  awk 'BEGIN{n=0} {lines[NR]=$0} END{last=NR; while(last>0 && lines[last] ~ /^[[:space:]]*$/) last--; for(i=1;i<=last;i++) print lines[i]}' \
    "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

if (( DRY_RUN )); then
  info "[dry-run] I would remove the old block from $rc and append:"
  info "  $MARK_BEGIN"
  info "  $SOURCE_LINE"
  info "  $MARK_END"
  exit 0
fi

strip_blocks "$rc"

if (( REMOVE )); then
  info "entry removed from $rc"
  exit 0
fi

{
  echo
  echo "$MARK_BEGIN"
  echo "$SOURCE_LINE"
  echo "$MARK_END"
} >> "$rc"

info "entry appended to $rc"
info "in open terminals run: source $rc   (new windows already have the aliases)"
