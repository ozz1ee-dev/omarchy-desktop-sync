#!/usr/bin/env bash
# omarchy-desktop :: pull
#
# One command on the machine that RECEIVES the configuration: fetches changes from the
# repo, then applies plugins/themes/patches and reloads the shell.
#
# Why plain `yadm pull` is not enough: the yadm worktree is $HOME, and Omarchy itself
# rewrites part of those files (shell.json, plugin configs, bar layout). With
# pull.rebase=true git then aborts with:
#   cannot pull with rebase: You have unstaged changes.
#
# Usage:
#   pull.sh                     autostash: local changes are stashed and restored after pull
#   pull.sh --repo              repo wins: local changes land in the stash (recoverable)
#   pull.sh --no-import         fetch only, without installing plugins/themes/patches
#   pull.sh --restart-shell     let import.sh kill quickshell if it cannot save enable-state
#   pull.sh --keep-untracked    do not touch local untracked files (pull may fail)
#   pull.sh -n|--dry-run        show the plan, change nothing
#
# Untracked file collisions: if a file arrives from the repo as NEW while it already
# exists locally (untracked), git refuses to overwrite it and the pull fails with
#   error: The following untracked working tree files would be overwritten by merge
# (autostash does NOT cover this - the stash does not include untracked files).
# That is why local versions go to $BASE/backups/untracked-<date>/ (outside the repo)
# before the pull, and the version from the repo wins. Nothing is ever deleted.

set -euo pipefail

BASE="$HOME/.config/omarchy-desktop"
if [ -f "$BASE/settings" ]; then . "$BASE/settings"; fi
DOTFILES_REPO="${DOTFILES_REPO:-}"
MODE=autostash; DO_IMPORT=1; DRY_RUN=0; PASS_RESTART=0; KEEP_UNTRACKED=0
IMPORT_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --repo)            MODE=repo ;;
    --no-import)       DO_IMPORT=0 ;;
    --restart-shell)   PASS_RESTART=1; IMPORT_ARGS+=(--restart-shell) ;;
    --keep-untracked)  KEEP_UNTRACKED=1 ;;
    -n|--dry-run)      DRY_RUN=1 ;;
    -h|--help)         sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
cd "$HOME"

step() { printf '\n== %s ==\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   !! %s\n' "$*"; }
run()  { if (( DRY_RUN )); then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }

command -v yadm >/dev/null 2>&1 || { echo "yadm not found in PATH" >&2; exit 1; }
[ -f "$BASE/tracked.paths" ] || { echo "missing $BASE/tracked.paths" >&2; exit 1; }

mapfile -t paths < <(grep -vE '^[[:space:]]*(#|$)' "$BASE/tracked.paths")
dirty="$(yadm status --porcelain -- "${paths[@]}" 2>/dev/null | grep -v '^!!' || true)"

step "1/3  state of this worktree"
if [ -n "$dirty" ]; then
  info "local changes in synchronized files:"
  printf '%s\n' "$dirty" | head -25 | sed 's/^/     /'
  (( $(printf '%s\n' "$dirty" | wc -l) > 25 )) && info "... (list truncated)"
  info "these are exactly what blocks 'yadm pull' with pull.rebase=true"
else
  info "no local changes in synchronized files"
fi

step "2/3  fetching from the repo"
pull_ok=1
if ! run yadm fetch -q origin; then
  pull_ok=0
  warn "fetch failed (network? bad remote? no access?)"
else
  branch="$(yadm rev-parse --abbrev-ref HEAD)"
  incoming="$(yadm rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo '?')"
  info "branch: $branch | commits to fetch: $incoming"
  # Collisions: a file arrives from the repo as NEW while the local path already exists
  # (untracked or ignored). Untracked -> git refuses to overwrite it and the pull fails;
  # ignored -> git overwrites it silently. In both cases the local version is kept in
  # backups/ before the pull. We only check incoming files (this is fast, it does not
  # scan the whole $HOME).
  BAK_DIR=""
  if [ "$incoming" != "0" ] && [ "$incoming" != "?" ]; then
    collisions=()
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -e "$HOME/$f" ] || continue
      yadm ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && continue
      collisions+=("$f")
    done < <(yadm diff --name-only --diff-filter=A "HEAD..origin/$branch" 2>/dev/null || true)
    if (( ${#collisions[@]} > 0 )); then
      warn "${#collisions[@]} local paths collide with files incoming from the repo:"
      printf '     %s\n' "${collisions[@]:0:15}"
      (( ${#collisions[@]} > 15 )) && info "     ... (list truncated)"
      if (( KEEP_UNTRACKED )); then
        warn "--keep-untracked: leaving them in place, the pull will probably fail with:"
        warn "  error: The following untracked working tree files would be overwritten by merge"
      elif (( DRY_RUN )); then
        info "[dry-run] would move local versions to $BASE/backups/untracked-<date>/"
      else
        BAK_DIR="$BASE/backups/untracked-$(date +%Y%m%d-%H%M%S)"
        for f in "${collisions[@]}"; do
          mkdir -p "$BAK_DIR/$(dirname "$f")"
          mv -- "$f" "$BAK_DIR/$f"
        done
        info "local versions preserved in: $BAK_DIR"
        info "after the pull compare:  diff -u \"$BAK_DIR/<file>\" \"$HOME/<file>\""
      fi
    fi
  fi
  case "$MODE" in
    autostash)
      info "autostash mode: git stashes local changes, fetches, then tries to restore them"
      run yadm pull --rebase --autostash || pull_ok=0
      ;;
    repo)
      if [ -n "$dirty" ]; then
        info "--repo mode: local changes land in the stash, the repo wins"
        info "recovery: yadm stash list  ->  yadm stash pop / show"
        run yadm stash push -q -m "omarchy-desktop: local changes $(hostname -s) $(date -Iseconds)" -- "${paths[@]}"
      fi
      run yadm pull --rebase || pull_ok=0
      ;;
  esac
fi

# The pull did not succeed (conflict, dirty tree, network) - we do NOT run the import on
# a half-updated tree, but we say exactly what to do next.
if (( ! pull_ok && ! DRY_RUN )); then
  echo
  warn "pull failed - import was NOT run"
  info "what next:"
  info "  0) local file collisions:      $0 (no flags: it copies them to $BASE/backups/)"
  info "  1) see what is in the way:     yadm status --short"
  info "  2) fetch anyway:               $0 --repo --no-import"
  info "  3) missing themes only:        $BASE/bin/import.sh --themes-only"
  info "  4) plugins (without touching shell.json): $BASE/bin/import.sh --themes-only --skip-themes"
  exit 1
fi

if (( ! DRY_RUN )); then
  info "at HEAD: $(yadm log -1 --format='%h %s')"
  if [ -n "$(yadm status --porcelain -- "${paths[@]}" 2>/dev/null | grep -v '^!!' || true)" ]; then
    info "WARNING: local changes are still present after the pull (autostash restored them, or Omarchy wrote them)"
    info "if you want the version from the repo:  yadm checkout -f -- <file>"
  fi
fi

step "3/3  loading the configuration"
if (( DO_IMPORT )); then
  if (( DRY_RUN )); then
    if (( PASS_RESTART )); then info "[dry-run] $BASE/bin/import.sh --restart-shell"; else info "[dry-run] $BASE/bin/import.sh"; fi
  else
    if (( PASS_RESTART )); then exec "$BASE/bin/import.sh" "${IMPORT_ARGS[@]}"; else exec "$BASE/bin/import.sh"; fi
  fi
else
  info "--no-import: stopping after the fetch"
fi
