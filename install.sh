#!/usr/bin/env bash
# omarchy-desktop-sync :: installer
#
# Ships with the omarchy-desktop-sync deployment guide (public: see the README) - that repo
# holds instructions, reference tools and empty templates only. It never holds your
# configuration: your desktop goes to YOUR OWN private repo, which you point at with --repo.
#
# Copies the tools into ~/.config/omarchy-desktop/, seeds the example files, writes the
# settings file and wires the omx / omr / omv aliases into your shell rc.
# Idempotent: existing files are never silently overwritten.
#
# Usage:
#   ./install.sh --repo <your-dotfiles-repo-url>     recommended, one command
#   ./install.sh                                     asks for the repo URL interactively
#   ./install.sh --force                             overwrite existing tools in place
#   ./install.sh --no-aliases                        do not touch your shell rc
#   ./install.sh --uninstall                         remove the shell block (keeps your files)
#
# After installing on the machine you want to copy FROM:
#   yadm init
#   yadm remote add origin <your-dotfiles-repo-url>
#   omx
# On every other machine:
#   yadm clone --bootstrap <your-dotfiles-repo-url>

set -euo pipefail

# English messages regardless of your locale (git ships its own translations)
export LC_MESSAGES=C

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$HOME/.config/omarchy-desktop"
REPO=""
NO_ALIASES=0
FORCE=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)         REPO="${2:-}"; shift 2 ;;
    --repo=*)       REPO="${1#*=}"; shift ;;
    --no-aliases)   NO_ALIASES=1; shift ;;
    --force)        FORCE=1; shift ;;
    --uninstall)    UNINSTALL=1; shift ;;
    -h|--help)      sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   !! %s\n' "$*"; }

if (( UNINSTALL )); then
  step "uninstall"
  if [ -x "$BASE/bin/setup-shell.sh" ]; then
    "$BASE/bin/setup-shell.sh" --remove || warn "could not remove the shell block"
  else
    info "no setup-shell.sh found - remove the marked block from your rc by hand"
  fi
  info "your files were NOT deleted. Remove them manually if you want:"
  info "  rm -rf $BASE"
  info "and, if you cloned it, the yadm repo: ~/.local/share/yadm/repo.git"
  exit 0
fi

step "1/5  preflight"
missing=0
if command -v omarchy >/dev/null 2>&1; then
  info "omarchy: $(omarchy version 2>/dev/null || echo present)"
else
  warn "omarchy CLI not found - this tool drives the Omarchy CLI (plugin add, theme install)"
  missing=1
fi
if command -v yadm >/dev/null 2>&1; then
  info "yadm: $(yadm version 2>/dev/null | head -1 || echo present)"
else
  warn "yadm not found. Install it:  sudo pacman -S yadm"
  missing=1
fi
for c in git python3; do
  command -v "$c" >/dev/null 2>&1 && info "$c: present" || { warn "$c not found"; missing=1; }
done
(( missing )) && info "you can continue, but the commands above are required for the sync to work"

step "2/5  tools -> $BASE/bin"
mkdir -p "$BASE/bin"
conflicts=()
for f in "$SRC"/reference/bin/*.sh; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  target="$BASE/bin/$name"
  if [ -e "$target" ] && ! cmp -s "$f" "$target"; then
    if (( FORCE )); then
      install -m 755 "$f" "$target"
      info "replaced: $name"
    else
      install -m 755 "$f" "$target.new"
      conflicts+=("$name")
      warn "kept your $name, new version written as $name.new"
    fi
  else
    install -m 755 "$f" "$target"
    info "installed: $name"
  fi
done
(( ${#conflicts[@]} > 0 )) && info "compare with: diff -u $BASE/bin/<name> $BASE/bin/<name>.new"

step "3/5  example files (only if missing)"
for pair in "tracked.paths:templates/tracked.paths" \
            ".gitignore:templates/dotfiles-gitignore" \
            "aliases.zsh:templates/aliases.zsh" \
            "manual.md:templates/manual.md"; do
  target="$BASE/${pair%%:*}"
  source_file="$SRC/${pair##*:}"
  if [ -e "$target" ]; then
    info "kept existing $(basename "$target")"
  elif [ -e "$source_file" ]; then
    install -m 644 "$source_file" "$target"
    info "created: $(basename "$target")"
  fi
done
mkdir -p "$HOME/.config/yadm"
if [ -e "$HOME/.config/yadm/bootstrap" ] && ! cmp -s "$SRC/templates/yadm-bootstrap" "$HOME/.config/yadm/bootstrap"; then
  install -m 755 "$SRC/templates/yadm-bootstrap" "$HOME/.config/yadm/bootstrap.new"
  warn "kept your ~/.config/yadm/bootstrap, new version written as bootstrap.new"
else
  install -m 755 "$SRC/templates/yadm-bootstrap" "$HOME/.config/yadm/bootstrap"
  info "installed: ~/.config/yadm/bootstrap"
fi

step "4/5  settings"
if [ -z "$REPO" ] && [ -f "$BASE/settings" ]; then
  # shellcheck disable=SC1091
  . "$BASE/settings"
  REPO="${DOTFILES_REPO:-}"
  info "already configured: ${REPO:-<empty>}"
fi
if [ -z "$REPO" ] && [ -t 0 ] && [ ! -f "$BASE/settings" ]; then
  printf '   URL of the PRIVATE repo that will hold your config (empty to skip): '
  read -r REPO || REPO=""
fi
if [ -n "$REPO" ]; then
  printf '# Repo that holds this machine desktop. Travels with the repo.\nDOTFILES_REPO="%s"\n' "$REPO" > "$BASE/settings"
  info "settings written: DOTFILES_REPO=$REPO"
else
  if [ ! -f "$BASE/settings" ]; then
    printf '# Repo that holds this machine desktop. Travels with the repo.\nDOTFILES_REPO=""\n' > "$BASE/settings"
  fi
  warn "no repo URL set - edit $BASE/settings before publishing"
fi

step "5/5  shell aliases"
if (( NO_ALIASES )); then
  info "--no-aliases: skipped (add the source line yourself if you want omx/omr/omv)"
else
  "$BASE/bin/setup-shell.sh" || warn "setup-shell.sh failed - add the source line by hand"
fi

cat <<EOF

Done. Next steps
  1) Create an EMPTY PRIVATE repo for your config (GitHub: New repository -> Private).
     Your desktop goes there, never into the guide repo you just cloned.
  2) On THIS machine (the source):
       yadm init
       yadm remote add origin <your-dotfiles-repo-url>
       omx                 # writes manifests + INVENTORY.md, commits, pushes
  3) On every OTHER machine:
       sudo pacman -S yadm git
       yadm clone --bootstrap <your-dotfiles-repo-url>
  4) Daily use: omx (publish), omr (receive), omv (audit)

Read $BASE/manual.md - it lists what the sync deliberately does NOT do (secrets).
EOF
