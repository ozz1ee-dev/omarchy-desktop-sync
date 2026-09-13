#!/usr/bin/env bash
# omarchy-desktop :: plugin-update
#
# Updates plugins with the BUILT-IN Omarchy updater, because the panel manager
# (io.github.juancasanueva.plugin-manager, helpers/pinned_update.py, check_clean)
# refuses with "Dirty, untracked or ignored files present": its guard
# requires the plugin directory to be byte for byte identical to the files in HEAD
# (permissions + content), so it blocks:
#   * runtime junk (__pycache__/, runtime/, cache)  -> the built-in updater passes
#   * a permission difference (file/dir mode)       -> the built-in usually passes,
#                                                      but the panel ALWAYS refuses
#   * our patch from patches/                       -> --with-patches
#   * foreign content changes                       -> decision: commit or revert
#
# Usage:
#   plugin-update.sh                 update every plugin that has .git
#   plugin-update.sh <id> [...]      only the ones named
#   plugin-update.sh --list-dirty    diagnostic report (what blocks which updater)
#   plugin-update.sh --fix-perms     fix permissions against git (without changing content)
#   plugin-update.sh --with-patches  handle plugins that carry our patch
#   plugin-update.sh --clean-junk    delete files generated at runtime (for the panel)
#   plugin-update.sh --dry-run       show the plan, change nothing

set -euo pipefail

# English messages regardless of your locale (git ships its own translations)
export LC_MESSAGES=C
PLUGINS="$HOME/.config/omarchy/plugins"
BASE="$HOME/.config/omarchy-desktop"
if [ -f "$BASE/settings" ]; then . "$BASE/settings"; fi
DOTFILES_REPO="${DOTFILES_REPO:-}"
PATCHDIR="$BASE/patches"
BACKUPDIR="$BASE/backups"

DRY_RUN=0; WITH_PATCHES=0; LIST=0; CLEAN_JUNK=0; FIX_PERMS=0; ids=()
for arg in "$@"; do
  case "$arg" in
    --list-dirty)    LIST=1 ;;
    --with-patches)  WITH_PATCHES=1 ;;
    --clean-junk)    CLEAN_JUNK=1 ;;
    --fix-perms)     FIX_PERMS=1 ;;
    -n|--dry-run)    DRY_RUN=1 ;;
    -h|--help)       sed -n '2,22p' "$0"; exit 0 ;;
    -*)              echo "unknown option: $arg" >&2; exit 2 ;;
    *)               ids+=("$arg") ;;
  esac
done

info() { printf '   %s\n' "$*"; }

# --- directory classification (result in CVS_*) ---------------------------------
classify() {
  local dir="$1" patch
  CVS_ID="$(basename "$dir")"
  CVS_NOACCESS=0
  if [ ! -x "$dir" ] || ! git -C "$dir" status >/dev/null 2>&1; then
    CVS_NOACCESS=1
    CVS_TRACKED=0; CVS_MODEONLY=0; CVS_CONTENT=0; CVS_UNTRACKED=0; CVS_IGNORED=0
    CVS_PATCH="-"; CVS_BADMODES=0
    return 0
  fi
  CVS_TRACKED="$(git -C "$dir" status --porcelain 2>/dev/null | grep -cE '^ ?[MADRCU]' || true)"
  CVS_MODEONLY="$(git -C "$dir" diff --raw HEAD 2>/dev/null | awk '$3 == $4 && $5 ~ /^M/ {c++} END {print c+0}')"
  CVS_CONTENT=$((CVS_TRACKED - CVS_MODEONLY))
  ((CVS_CONTENT < 0)) && CVS_CONTENT=0
  CVS_UNTRACKED="$(git -C "$dir" status --porcelain 2>/dev/null | grep -c '^??' || true)"
  CVS_IGNORED="$(git -C "$dir" status --porcelain --ignored 2>/dev/null | grep -c '^!!' || true)"
  # how many tracked files have a mode different from the one recorded in the index
  CVS_BADMODES="$(bad_modes "$dir" | wc -l)"
  CVS_PATCH="none"
  patch="$PATCHDIR/$CVS_ID.patch"
  if [ -f "$patch" ]; then
    if git -C "$dir" apply --reverse --check "$patch" >/dev/null 2>&1; then CVS_PATCH="ours"
    elif git -C "$dir" apply --check "$patch" >/dev/null 2>&1; then CVS_PATCH="not applied"
    else CVS_PATCH="conflict"; fi
  fi
}

# tracked files whose on-disk mode does not match the git index
# Note: we do NOT use `[ condition ] && printf` here - the last iteration would return 1
# and, under `set -e` + pipefail, would kill the whole script at the call site.
bad_modes() {
  local dir="$1" entry meta mode path
  git -C "$dir" ls-files -s -z 2>/dev/null | while IFS= read -r -d '' entry; do
    meta="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    mode="${meta%% *}"
    [ -f "$dir/$path" ] || continue
    case "$mode" in
      100755) if [ ! -x "$dir/$path" ]; then printf '%s\n' "$path"; fi ;;
      100644) if [ -x "$dir/$path" ]; then printf '%s\n' "$path"; fi ;;
    esac
  done
  return 0
}

list_dirty() {
  local dir dirty=0 junk=0 content=0 perms=0 ours=0 other=0 clean=0 noacc=0
  printf 'git %s | core.autocrlf=%s core.filemode=%s pull.rebase=%s\n' \
    "$(git --version | awk '{print $3}')" \
    "$(git config --get core.autocrlf || echo '(unset)')" \
    "$(git config --get core.filemode || echo '(unset)')" \
    "$(git config --get pull.rebase || echo '(unset)')"
  echo
  printf '%-38s %6s %5s %8s %10s %11s  %s\n' "PLUGIN" "change" "mode" "bad-mode" "untracked" "ignored" "patch"
  printf '%-38s %6s %5s %8s %10s %11s  %s\n' "--------------------------------------" "------" "-----" "--------" "----------" "-----------" "-----"
  for dir in "$PLUGINS"/*/; do
    [ -e "$dir/.git" ] || continue
    classify "$dir"
    if [ "$CVS_NOACCESS" = 1 ]; then
      noacc=$((noacc + 1))
      printf '%-38s NO ACCESS: directory without the x bit (%s)\n' "$CVS_ID" "$(stat -c %a "$dir" 2>/dev/null)"
      continue
    fi
    if [ "$CVS_TRACKED" = 0 ] && [ "$CVS_UNTRACKED" = 0 ] && [ "$CVS_IGNORED" = 0 ] && [ "$CVS_BADMODES" = 0 ]; then
      clean=$((clean + 1)); continue
    fi
    dirty=$((dirty + 1))
    printf '%-38s %6s %5s %8s %10s %11s  %s\n' \
      "$CVS_ID" "$CVS_CONTENT" "$CVS_MODEONLY" "$CVS_BADMODES" "$CVS_UNTRACKED" "$CVS_IGNORED" "$CVS_PATCH"
    git -C "$dir" status --porcelain --ignored 2>/dev/null | head -2 | sed 's/^/        /'
    if [ "$CVS_CONTENT" = 0 ] && [ "$CVS_UNTRACKED" = 0 ]; then junk=$((junk + 1)); fi
    if [ "$CVS_CONTENT" != 0 ] && [ "$CVS_PATCH" = "ours" ]; then ours=$((ours + 1)); fi
    if [ "$CVS_CONTENT" != 0 ] && [ "$CVS_PATCH" != "ours" ]; then other=$((other + 1)); fi
    if [ "$CVS_CONTENT" = 0 ] && [ "$CVS_BADMODES" != 0 ]; then perms=$((perms + 1)); fi
  done
  echo
  echo "directories: clean $clean | dirty $dirty | no access $noacc"
  echo "  runtime junk only:               $junk   -> the built-in updater passes"
  echo "  wrong file permissions:          $perms  -> --fix-perms (the panel refuses anyway)"
  echo "  change = our patch:              $ours   -> --with-patches"
  echo "  other content changes:           $other  -> commit or revert"
  echo
  echo "The panel refuses every directory where anything > 0 (it requires a byte for byte tree)."
  echo "The built-in updater blocks only 'content' that conflicts with the incoming change."
}

fix_perms() {
  local dir entry meta mode path fixed_dirs=0 fixed_files=0 n
  for dir in "$PLUGINS"/*/; do
    [ -e "$dir/.git" ] || continue
    n=0
    if [ ! -x "$dir" ]; then
      if (( DRY_RUN )); then info "[dry-run] chmod u+x $(basename "$dir") (directory without x)"
      else chmod u+x "$dir"; n=$((n + 1)); fi
    fi
    # directories inside without the x bit
    while IFS= read -r -d '' d2; do
      if (( DRY_RUN )); then info "[dry-run] chmod u+x ${d2#"$PLUGINS"/}"
      else chmod u+x "$d2"; n=$((n + 1)); fi
    done < <(find "$dir" -mindepth 1 -type d ! -perm -u+x -print0 2>/dev/null)
    # file modes against the git index
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      entry="$(git -C "$dir" ls-files -s -z -- "$path" | tr -d '\0')"
      meta="${entry%%$'\t'*}"; mode="${meta%% *}"
      if (( DRY_RUN )); then
        info "[dry-run] $(basename "$dir"): mode $mode <- $path"
      else
        case "$mode" in
          100755) chmod u+x,g+x,o+x "$dir/$path" ;;
          100644) chmod u-x,g-x,o-x "$dir/$path" ;;
        esac
        n=$((n + 1))
      fi
    done < <(bad_modes "$dir")
    if (( n > 0 )); then
      if (( DRY_RUN )); then info "$(basename "$dir"): $n to fix"
      else printf '%-38s fixed %s entries\n' "$(basename "$dir")" "$n"; fi
      fixed_dirs=$((fixed_dirs + 1))
    fi
  done
  if (( DRY_RUN )); then info "[dry-run] nothing changed"
  else info "directories touched: $fixed_dirs"; fi
  return 0
}

update_one() {
  local id="$1" dir="$PLUGINS/$1" patch backup out what
  if [ ! -d "$dir/.git" ]; then printf '%-38s %s\n' "$id" "skipped: no .git"; return 0; fi
  classify "$dir"
  printf '%-38s ' "$id"
  if [ "$CVS_NOACCESS" = 1 ]; then
    echo "NO ACCESS: directory without the x bit -> fix it: $0 --fix-perms"
    return 0
  fi
  if [ "$CVS_CONTENT" != 0 ] && [ "$CVS_PATCH" != "ours" ]; then
    echo "SKIPPED: $CVS_CONTENT changed content files, and this is not our patch (see --list-dirty)"
    return 0
  fi

  if [ "$CVS_CONTENT" != 0 ] && [ "$CVS_PATCH" = "ours" ]; then
    if (( ! WITH_PATCHES )); then
      echo "SKIPPED: our patch is applied ($CVS_CONTENT files) -> add --with-patches"
      return 0
    fi
    patch="$PATCHDIR/$id.patch"
    mkdir -p "$BACKUPDIR"
    backup="$BACKUPDIR/$id.$(date +%Y%m%d-%H%M%S).patch"
    if (( DRY_RUN )); then
      printf 'back up changes -> %s; checkout; update; git apply %s\n' "$backup" "$patch"
      return 0
    fi
    git -C "$dir" diff HEAD --no-color > "$backup"
    git -C "$dir" checkout -q -- .
    if out="$(omarchy plugin update "$id" --yes 2>&1)"; then
      what="UPDATED"
      case "$out" in *"up to date"*) what="no change (upstream at HEAD)" ;; esac
      if git -C "$dir" apply "$patch" >/dev/null 2>&1; then
        echo "$what + our patch re-applied (backup: $backup)"
      else
        echo "$what, but the patch did NOT apply (upstream changed the file) - backup: $backup"
      fi
    else
      echo "ERROR: $(printf '%s\n' "$out" | tail -1)"
    fi
    return 0
  fi

  if out="$(omarchy plugin update "$id" --yes 2>&1)"; then
    case "$out" in
      *"up to date"*) echo "no change" ;;
      *) echo "UPDATED" ;;
    esac
  else
    echo "ERROR: $(printf '%s\n' "$out" | tail -1)"
  fi
}

if (( LIST )); then
  list_dirty
  exit 0
fi

if (( FIX_PERMS )); then
  fix_perms
  exit 0
fi

# The only way to make the panel manager stop refusing: a tree byte for byte
# equal to HEAD, which means deleting the files generated at runtime (ignored).
# They are reproducible: the plugin generates them again on its next start.
if (( CLEAN_JUNK )); then
  total=0
  for dir in "$PLUGINS"/*/; do
    [ -e "$dir/.git" ] || continue
    classify "$dir"
    if [ "$CVS_IGNORED" = 0 ] && [ "$CVS_UNTRACKED" = 0 ]; then continue; fi
    before="$(du -sk "$dir" | cut -f1)"
    if (( DRY_RUN )); then
      printf '%-38s [dry-run] git clean -Xfd (ignored: %s, untracked: %s)\n' "$CVS_ID" "$CVS_IGNORED" "$CVS_UNTRACKED"
    else
      git -C "$dir" clean -Xfdq
      git -C "$dir" clean -fdq
      after="$(du -sk "$dir" | cut -f1)"
      freed=$((before - after))
      total=$((total + freed))
      printf '%-38s cleaned %s KB\n' "$CVS_ID" "$freed"
    fi
  done
  (( DRY_RUN )) || info "total reclaimed: $total KB"
  info "note: plugins generate these files again on their next use - the panel will refuse again"
  exit 0
fi

targets=("${ids[@]}")
if ((${#targets[@]} == 0)); then
  for dir in "$PLUGINS"/*/; do
    [ -e "$dir/.git" ] && targets+=("$(basename "$dir")")
  done
fi

for id in "${targets[@]}"; do
  update_one "$id"
done
