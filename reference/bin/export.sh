#!/usr/bin/env bash
# omarchy-desktop :: export
#
# Saves the Omarchy "desktop definition" - bar, menu, keybindings, plugin list,
# themes, local plugin patches, configs - into the yadm repo and pushes it to GitHub.
# The second machine reproduces all of it with one command:  yadm clone --bootstrap ${DOTFILES_REPO:-<your-dotfiles-repo-url>}
#
# Usage:
#   export.sh              collect changes + commit + push
#   export.sh -n|--dry-run show the plan, writes nothing
#   export.sh --no-push    commit locally, without push

set -euo pipefail

DRY_RUN=0; DO_PUSH=1
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    --no-push)    DO_PUSH=0 ;;
    -h|--help)    sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
cd "$HOME"

BASE="$HOME/.config/omarchy-desktop"
if [ -f "$BASE/settings" ]; then . "$BASE/settings"; fi
DOTFILES_REPO="${DOTFILES_REPO:-}"
OM="$HOME/.config/omarchy"
PLUGINS="$OM/plugins"
THEMES="$OM/themes"
PATCHES="$BASE/patches"

step() { printf '\n== %s ==\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   !! %s\n' "$*"; }
run()  { if (( DRY_RUN )); then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }

if (( ! DRY_RUN )) && ! command -v yadm >/dev/null 2>&1; then
  echo "yadm not found in PATH - install it: sudo pacman -S yadm" >&2
  exit 1
fi

step "1/6  plugin manifest -> $BASE/plugins.txt"
tmp="$(mktemp)"
{
  echo "# id <git-url>            '# LOCAL <id>' = local clone without .git, files live in the repo"
  for dir in "$PLUGINS"/*/; do
    [ -d "$dir" ] || continue
    id="${dir%/}"; id="${id##*/}"
    url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    if [ -n "$url" ]; then printf '%s %s\n' "$id" "$url"
    else printf '# LOCAL %s\n' "$id"; fi
  done
} > "$tmp"
info "from git: $(awk '!/^#/ && NF>1' "$tmp" | wc -l) | local clones: $(grep -c '^# LOCAL' "$tmp" || true)"
if (( DRY_RUN )); then sed 's/^/   | /' "$tmp"; rm -f "$tmp"; else mv "$tmp" "$BASE/plugins.txt"; fi

step "2/6  theme manifest -> $BASE/themes.txt"
tmp="$(mktemp)"
{
  echo "# name <git-url>         '# LOCAL <name>' = theme without a git repo, its files travel in yadm (tracked.paths)"
  for dir in "$THEMES"/*/; do
    [ -d "$dir" ] || continue
    name="${dir%/}"; name="${name##*/}"
    url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    if [ -n "$url" ]; then printf '%s %s\n' "$name" "$url"
    else printf '# LOCAL %s\n' "$name"; fi
  done
} > "$tmp"
info "from git: $(awk '!/^#/ && NF>1' "$tmp" | wc -l) | local: $(grep -c '^# LOCAL' "$tmp" || true)"
if (( DRY_RUN )); then sed 's/^/   | /' "$tmp"; rm -f "$tmp"; else mv "$tmp" "$BASE/themes.txt"; fi

step "3/6  active theme -> $BASE/active-theme"
slug="$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)"
info "selected on this machine: ${slug:-not determined}"
(( DRY_RUN )) || printf '%s\n' "$slug" > "$BASE/active-theme"

step "4/6  local plugin patches -> $BASE/patches/"
# Plugins are often patched locally (e.g. a yt-dlp format fix or an OSD position fix).
# Save every such change as a patch, so the second machine gets the same.
mkdir -p "$PATCHES"
n_patch=0; n_clean=0
for dir in "$PLUGINS"/*/; do
  [ -e "$dir/.git" ] || continue
  id="$(basename "$dir")"
  diff="$(git -C "$dir" diff HEAD --no-color 2>/dev/null || true)"
  if [ -n "$diff" ]; then
    n_patch=$((n_patch + 1))
    info "patch: $id ($(printf '%s\n' "$diff" | grep -c '^diff --git') files)"
    if (( ! DRY_RUN )); then printf '%s\n' "$diff" > "$PATCHES/$id.patch"; fi
  else
    n_clean=$((n_clean + 1))
    (( DRY_RUN )) || rm -f "$PATCHES/$id.patch"
  fi
done
info "with local changes: $n_patch | clean: $n_clean"

step "5/6  configuration files (yadm add)"
run "$BASE/bin/inventory.sh" || warn "inventory.sh failed (INVENTORY.md will stay stale)"
mapfile -t paths < <(grep -vE '^[[:space:]]*(#|$)' "$BASE/tracked.paths")
existing=(); gone=()
for p in "${paths[@]}"; do
  if [ -e "$HOME/$p" ]; then existing+=("$p")
  else
    info "skipped (missing on this machine): $p"
    gone+=("$p")
  fi
done
# Junk exclusions: core.excludesFile MUST live in the config of the yadm REPO, because
# that is the only config git reads. An entry in ~/.config/yadm/config does NOT work -
# that is yadm's own file, which git does not read (verified: a fresh probe-test.lock was
# not ignored, and after `yadm gitconfig` it was). The repo config is local, so we set it
# every time - import.sh does exactly the same on every machine.
n_pat="$(grep -vcE '^[[:space:]]*(#|$)' "$BASE/.gitignore")"
if (( DRY_RUN )); then
  printf '   [dry-run] core.excludesFile <- %s (%s patterns)\n' "$BASE/.gitignore" "$n_pat"
else
  run yadm gitconfig core.excludesFile "$BASE/.gitignore"
  info "excludes: $n_pat patterns from $BASE/.gitignore (core.excludesFile in the yadm repo)"
fi
run yadm add -A -- "${existing[@]}"
for p in "${gone[@]}"; do
  if [ -n "$(yadm ls-files -- "$p")" ]; then
    info "deleted locally, removing from repo: $p"
    run yadm rm -q --ignore-unmatch -- "$p"
  fi
done

# Guard: never let junk into the commit, even if the git excludes were to fail.
# The patterns are read from $BASE/.gitignore (that is their only source).
if (( ! DRY_RUN )); then
  mapfile -t staged < <(yadm diff --cached --name-status 2>/dev/null || true)
  removed=0
  for entry in "${staged[@]}"; do
    st="${entry%%[[:space:]]*}"; path="${entry#*[[:space:]]}"
    [ -n "$path" ] || continue
    while read -r pat; do
      case "$pat" in ''|\#*) continue ;; esac
      hit=0
      case "$pat" in
        */) case "/$path" in *"/$pat"*) hit=1 ;; esac ;;
        *)  case "${path##*/}" in $pat) hit=1 ;; esac
            case "$path" in $pat) hit=1 ;; esac ;;
      esac
      if (( hit )); then
        if [ "$st" = "D" ]; then
          # junk being deleted from the repo - exactly what we want, leave it in the index
          info "removing junk from repo: $path"
        else
          warn "junk in index: $path (pattern '$pat') - removing from repo, file stays on disk"
          yadm rm -q --cached --ignore-unmatch -- "$path"
        fi
        removed=$((removed + 1))
        break
      fi
    done < "$BASE/.gitignore"
  done
  (( removed )) && info "junk entries handled: $removed"
fi

step "6/6  commit + push"
if (( DRY_RUN )); then
  info "[dry-run] yadm add -> ${#existing[@]} paths, then commit and push"
  exit 0
fi
if yadm diff --cached --quiet; then
  info "no changes since the last publish - nothing to push"
  exit 0
fi
# A public-repo nicety: a fresh machine often has no git identity yet and the raw git error
# ("Author identity unknown") does not say what to do about it. Checked only when there is
# actually something to commit, so a dry run or an empty publish still works.
if ! yadm gitconfig --get user.email >/dev/null 2>&1 || ! yadm gitconfig --get user.name >/dev/null 2>&1; then
  warn "no git identity configured - the commit would fail"
  info "set one (repo-local is enough, or use --global):"
  info "  yadm gitconfig user.name  \"Your Name\""
  info "  yadm gitconfig user.email \"you@example.com\""
  err "stopping before the commit; nothing was published"
  exit 1
fi
yadm diff --cached --stat | tail -25
yadm commit -q -m "desktop: $(hostname -s) $(date -Iseconds)"
info "commit: $(yadm log -1 --format='%h %s')"
if (( DO_PUSH )); then
  branch="$(yadm rev-parse --abbrev-ref HEAD)"
  if yadm push -q 2>/dev/null; then info "pushed: origin/$branch"
  else yadm push -q -u origin "$branch" && info "pushed (new branch): origin/$branch"; fi
else
  info "--no-push: commit kept locally"
fi
