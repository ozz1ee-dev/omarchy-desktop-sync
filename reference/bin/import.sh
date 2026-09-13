#!/usr/bin/env bash
# omarchy-desktop :: import
#
# Recreates the desktop on THIS machine from the yadm repo: installs missing
# plugins (from plugins.txt), applies local plugin patches (patches/), installs
# missing themes (themes.txt), sets the active theme and reloads the shell/Hyprland.
# Config files are already in place after `yadm clone`.
#
# SOURCES OF TRUTH:
#   plugins.txt             what should be installed and enabled (URL + # LOCAL)
#   shell.json::disabledPlugins   the only forced disables (they override plugins.txt)
#   shell.json::bar.layout  where widgets are visible in the bar (does not affect enable)
#
# Normally started automatically by: yadm clone --bootstrap <repo-url>
# Manually: yadm bootstrap   (or: ~/.config/omarchy-desktop/bin/import.sh)
#
# Usage:
#   import.sh [--dry-run] [--skip-themes] [--skip-patches] [--skip-shell] [--only-enabled] [--restart-shell] [--themes-only] [--repair-themes]
#
# --themes-only     themes only (step 3/6 + active theme + reload): quick repair
#                   when themes are missing and you do not want to run the whole import
# --repair-themes   an incomplete theme (no colors.toml or no backgrounds) is reinstalled
#                   right away: `omarchy theme install` (rm -rf + fresh clone)

# --restart-shell   forces a quickshell restart (kill, auto-restart via
#                   omarchy-launch-shell) if after a sync there are plugins from
#                   plugins.txt that omarchy keeps as disabled. quickshell reads
#                   plugins.txt only at startup, and the IPC 'enablePlugin' can
#                   return 'ok' without actually changing state - then only a
#                   restart helps. The bar flickers for ~1s.
# --skip-shell      skips step 5/6 (wiring the omx/omr aliases into the shell rc)

set -uo pipefail
# Deliberately NO `set -e`: this is a convergence script ("deliver as much as you
# can"), not a transaction. With `set -e` a single error in the plugin step aborted
# the whole import and the themes (step 3/6) never got installed. Now every step
# runs to the end, errors are reported as they happen, and the summary plus the
# non-zero exit happen at the very end.

DRY_RUN=0; SKIP_THEMES=0; SKIP_PATCHES=0; SKIP_SHELL=0; ONLY_ENABLED=0; RESTART_SHELL=0
ONLY_THEMES=0; REPAIR_THEMES=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run)        DRY_RUN=1 ;;
    --skip-themes)       SKIP_THEMES=1 ;;
    --skip-patches)      SKIP_PATCHES=1 ;;
    --skip-shell)        SKIP_SHELL=1 ;;
    --only-enabled)      ONLY_ENABLED=1 ;;
    --restart-shell)     RESTART_SHELL=1 ;;
    --repair-themes)     REPAIR_THEMES=1 ;;
    --themes-only)       ONLY_THEMES=1; SKIP_PATCHES=1; SKIP_SHELL=1 ;;
    -h|--help)           sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
cd "$HOME"

# the counters may not exist when a step is skipped (and we run under `set -u`)
failed=0; local_missing=0; t_failed=0; t_incomplete=0; t_local_missing=0; p_bad=0

BASE="$HOME/.config/omarchy-desktop"
# Machine-local settings (NOT tracked in the repo): lets each machine override
# DOTFILES_REPO and other values without editing this script. Sourced defensively
# so that loading it can never trip `set -u`.
if [ -f "$BASE/settings" ]; then . "$BASE/settings"; fi
DOTFILES_REPO="${DOTFILES_REPO:-}"
OM="$HOME/.config/omarchy"
PLUGINS="$OM/plugins"
THEMES="$OM/themes"

step() { printf '\n== %s ==\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   !! %s\n' "$*"; }
err()  { printf '   XX %s\n' "$*" >&2; }
run()  { if (( DRY_RUN )); then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }

command -v omarchy >/dev/null 2>&1 || { echo "missing the omarchy command - this does not look like an Omarchy system" >&2; exit 1; }
[ -f "$BASE/plugins.txt" ] || { echo "missing $BASE/plugins.txt - is the repo cloned? (yadm clone --bootstrap ${DOTFILES_REPO:-<your-dotfiles-repo-url>})" >&2; exit 1; }

# ids of the widgets/plugins that are supposed to be active according to shell.json
enabled_ids() {
  python3 - "$OM/shell.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
ids = set()
for section in ("left", "center", "right"):
    for w in (d.get("bar", {}).get("layout", {}).get(section) or []):
        if isinstance(w, dict) and w.get("id"):
            ids.add(w["id"])
for p in (d.get("plugins") or []):
    if isinstance(p, dict) and p.get("id"):
        ids.add(p["id"])
for i in (d.get("disabledPlugins") or []):
    ids.discard(i)
print("\n".join(sorted(ids)))
PY
}

# ids registered in omarchy - the source of truth, not the filesystem
# (a directory can exist while the plugin is not registered, and the other way round)
registered_ids_file="$(mktemp)"
trap 'rm -f "$registered_ids_file" "${ids_file:-}"' EXIT
omarchy plugin list --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for p in d:
        i = p.get('id')
        if i: print(i)
except Exception:
    pass
" > "$registered_ids_file" 2>/dev/null || true
registered_total=$(grep -c . "$registered_ids_file" 2>/dev/null || echo 0)
info "registered in omarchy: $registered_total"

if (( ONLY_THEMES )); then
  step "1/6-1d/6  plugins: skipping (--themes-only)"
else
step "1/6  plugins (URLs from plugins.txt)"
installed=0; present=0; local_ok=0; local_missing=0; failed=0
ids_file=""
if (( ONLY_ENABLED )); then
  ids_file="$(mktemp)"; enabled_ids > "$ids_file"
  info "--only-enabled mode: $(grep -c . "$ids_file" || true) ids from shell.json"
fi
while read -r id url; do
  case "$id" in ''|'#'*) continue ;; esac
  if grep -qxF "$id" "$registered_ids_file"; then
    present=$((present+1)); info "already registered: $id"; continue
  fi
  if (( ONLY_ENABLED )) && ! grep -qxF "$id" "$ids_file"; then continue; fi
  info "installing: $id  <- $url"
  if run omarchy plugin add "$url" --yes; then
    installed=$((installed+1)); info "OK: $id"
    # refresh the registry - the next lines then see the current state
    omarchy plugin list --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for p in d:
        i = p.get('id')
        if i: print(i)
except Exception:
    pass
" > "$registered_ids_file" 2>/dev/null || true
  else
    err "FAILED: $id  <-  $url"
    err "  reason: check the 'omarchy plugin add' output above (bad URL? network? conflict?)"
    failed=$((failed+1))
  fi
done < "$BASE/plugins.txt"

step "1b/6  plugins (# LOCAL in plugins.txt)"
while read -r id; do
  [ -n "$id" ] || continue
  dir="$PLUGINS/$id"
  if [ ! -d "$dir" ]; then
    err "LOCAL plugin '$id' has no directory: $dir"
    err "  the files should be in yadm (check tracked.paths, whether the path .config/omarchy/plugins/$id is listed)"
    err "  on this machine: yadm pull   |   no files for this machine = try copying them by hand"
    local_missing=$((local_missing+1))
    continue
  fi
  if [ ! -f "$dir/manifest.json" ]; then
    err "LOCAL plugin '$id': the directory exists but manifest.json is missing - the files are damaged"
    local_missing=$((local_missing+1))
    continue
  fi
  if grep -qxF "$id" "$registered_ids_file"; then
    local_ok=$((local_ok+1)); info "local, registered: $id"
  else
    # The files are there, the manifest is there, but omarchy cannot see it - it should after rescanPlugins in step 4
    info "local, the files are there - omarchy should discover it after rescanPlugins: $id"
    local_ok=$((local_ok+1))
  fi
done < <(awk '/^# LOCAL/{print $3}' "$BASE/plugins.txt")

info "URL: already present=$present newly installed=$installed errors=$failed | LOCAL: ok=$local_ok missing=$local_missing"

step "1c/6  verifying enable-state vs shell.json"
# shell.json (from yadm) is the source of truth. We do not modify it - Quickshell
# reads it through FileView. We only report the discrepancies.
wns_file="$(mktemp)"; isn_file="$(mktemp)"
trap 'rm -f "$registered_ids_file" "${ids_file:-}" "$wns_file" "$isn_file"' EXIT
python3 - "$BASE/plugins.txt" "$OM/shell.json" "$wns_file" "$isn_file" <<'PY' 2>/dev/null || true
import json, sys
wanted = set()
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith('# LOCAL'): continue
    if line.startswith('#'): continue
    p = line.split(None, 1)
    if len(p) == 2: wanted.add(p[0])
for line in open(sys.argv[1]):
    if line.startswith('# LOCAL'):
        wanted.add(line.split()[2])
shell = json.load(open(sys.argv[2]))
in_shell = set()
in_bar = set()
for s in ('left','center','right'):
    for w in (shell.get('bar',{}).get('layout',{}).get(s) or []):
        if isinstance(w, dict) and w.get('id'):
            in_shell.add(w['id']); in_bar.add(w['id'])
for p in (shell.get('plugins') or []):
    if isinstance(p, dict) and p.get('id'): in_shell.add(p['id'])
disabled = set(shell.get('disabledPlugins') or [])
with open(sys.argv[3], 'w') as f:
    for i in sorted(wanted - in_shell - disabled): f.write(i + '\n')
with open(sys.argv[4], 'w') as f:
    for i in sorted(in_shell - wanted): f.write(i + '\n')
PY
bar_count=$(python3 -c "
import json
d = json.load(open('$OM/shell.json'))
total = 0
for s in ('left','center','right'): total += len(d.get('bar',{}).get('layout',{}).get(s,[]))
print(total)
" 2>/dev/null || echo 0)
wanted_count=$(wc -l < "$wns_file" 2>/dev/null || echo 0)
shell_only_count=$(wc -l < "$isn_file" 2>/dev/null || echo 0)
info "shell.json::bar.layout has $bar_count widgets; plugins.txt has $(grep -cE '^[a-z]' $BASE/plugins.txt) URL + $(grep -c '^# LOCAL' $BASE/plugins.txt) LOCAL"
if (( wanted_count > 0 )); then
  warn "plugins from plugins.txt NOT present in shell.json ($wanted_count) - installed but disabled:"
  cat "$wns_file" | head -20 | sed 's/^/     /'
  if (( wanted_count > 20 )); then warn "     ... and $((wanted_count - 20)) more"; fi
  warn "  fix: add the id to shell.json::plugins[] (or bar.layout.<section>) and push"
fi
if (( shell_only_count > 0 )); then
  warn "plugins in shell.json but NOT in plugins.txt ($shell_only_count):"
  cat "$isn_file" | head -10 | sed 's/^/     /'
  echo "$shell_only_count" | grep -q 7 >/dev/null 2>&1 && [ "$(cat $isn_file | wc -l)" = "7" ] && warn "  (those 7 are first-party 'omarchy.*' - omarchy ships them by default, ok)"
fi

step "1d/6  optional quickshell restart (--restart-shell)"
# If yadm pull changed shell.json, Quickshell should pick the change up through
# FileView. But sometimes it keeps the old in-memory state - then a kill+restart
# is the only way. omarchy-launch-shell has auto-restart logic.
shell_changed=0
if (( ! DRY_RUN )); then
  if omarchy-shell shell ping >/dev/null 2>&1; then
    info "omarchy-shell answers - FileView should pick up the changes from yadm pull"
  else
    warn "omarchy-shell does not answer - without a restart the shell.json changes will not be applied"
    shell_changed=1
  fi
fi
if (( RESTART_SHELL )) && (( ! DRY_RUN )) && (( shell_changed || 1 )); then
  qs_pid="$(pgrep -f 'quickshell.*omarchy/shell' | head -1 || true)"
  if [ -z "$qs_pid" ]; then
    warn "--restart-shell: could not find the quickshell PID, skipping"
  else
    info "killing quickshell (pid=$qs_pid) - omarchy-launch-shell will restart it automatically"
    info "the bar will flicker for ~1s, then come up with the proper state from shell.json"
    kill "$qs_pid" 2>/dev/null || true
    for i in 1 2 3 4 5; do
      sleep 1
      if pgrep -f 'quickshell.*omarchy/shell' >/dev/null 2>&1; then
        info "quickshell came up after ${i}s"
        break
      fi
    done
    if (( ! DRY_RUN )); then
      info "after the restart: checking omaice"
      omarchy plugin list --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
[print(p['id'], 'enabled' if p.get('enabled') else 'DISABLED') for p in d if 'omaice' in p.get('id','')]
" 2>/dev/null || true
    fi
  fi
elif (( RESTART_SHELL )); then
  info "[dry-run] skipping the quickshell kill"
fi

fi  # end of the plugins block (see the --themes-only flag)

step "2/6  local plugin patches"
if (( SKIP_PATCHES )); then
  info "--skip-patches: skipping"
elif [ -d "$BASE/patches" ]; then
  p_applied=0; p_ok=0; p_bad=0
  for patch in "$BASE"/patches/*.patch; do
    [ -e "$patch" ] || continue
    id="$(basename "$patch" .patch)"
    dir="$PLUGINS/$id"
    if [ ! -d "$dir" ]; then warn "no plugin directory: $id (patch skipped)"; continue; fi
    if git -C "$dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
      p_ok=$((p_ok+1)); info "already applied: $id"
    elif git -C "$dir" apply --check "$patch" >/dev/null 2>&1; then
      if run git -C "$dir" apply "$patch"; then p_applied=$((p_applied+1)); info "patch applied: $id"
      else warn "could not apply: $id"; p_bad=$((p_bad+1)); fi
    else
      p_bad=$((p_bad+1))
      warn "patch $id does not apply (did upstream change?) - see $patch"
    fi
  done
  info "applied now: $p_applied | were already applied: $p_ok | problems: $p_bad"
else
  info "no $BASE/patches directory"
fi

step "3/6  themes"
t_present=0; t_installed=0; t_failed=0; t_incomplete=0; t_repaired=0
t_local_ok=0; t_local_missing=0
if (( SKIP_THEMES )); then
  info "--skip-themes: skipping"
else
  while read -r name url; do
    case "$name" in ''|'#'*) continue ;; esac
    if [ -d "$THEMES/$name" ]; then
      # A theme must have colors.toml AND some background in backgrounds/ - without
      # a background Omarchy has nothing to set as wallpaper (a theme clone often
      # does not contain the .png/.jpg images). In that case it counts as missing.
      incomplete=""
      [ -f "$THEMES/$name/colors.toml" ] || incomplete="missing colors.toml"
      if [ -z "$(ls -A "$THEMES/$name/backgrounds" 2>/dev/null)" ]; then
        incomplete="${incomplete:+$incomplete + }no backgrounds in backgrounds/"
      fi
      if [ -z "$incomplete" ]; then t_present=$((t_present+1)); continue; fi
      # Repair automatically? An incomplete theme is always broken (no backgrounds =
      # no wallpaper, no colors.toml = Omarchy cannot see it), so:
      #   - directory WITHOUT .git (copied, e.g. by an old config-sync) -> we repair
      #   - directory with .git where only files are missing (just "D" entries in the
      #     status, i.e. exactly the empty shell) -> we repair
      #   - directory with your own changes (modified/added/untracked) -> we only warn
      auto=0
      if (( REPAIR_THEMES )); then auto=1
      elif [ ! -d "$THEMES/$name/.git" ]; then auto=1
      elif ! git -C "$THEMES/$name" status --porcelain 2>/dev/null | grep -qE '^ ?[MA]|^\?\?'; then auto=1
      fi
      if (( auto )); then
        info "repairing incomplete theme '$name' ($incomplete) - reinstalling from the URL"
        if (( DRY_RUN )); then
          info "[dry-run] omarchy theme install $url"
        elif out="$(omarchy theme install "$url" 2>&1)"; then
          t_repaired=$((t_repaired+1))
        else
          warn "reinstalling '$name' failed:"
          printf '%s\n' "$out" | tail -4 | sed 's/^/       /'
          t_failed=$((t_failed+1))
        fi
      else
        warn "theme '$name' is incomplete ($incomplete), but it has local changes - leaving it alone"
        warn "  repair it by hand: omarchy theme install $url   (removes the directory and clones it fresh)"
        t_incomplete=$((t_incomplete+1))
      fi
      continue
    fi
    info "installing theme: $name  <- $url"
    if (( DRY_RUN )); then
      info "[dry-run] omarchy theme install $url"
    elif out="$(omarchy theme install "$url" 2>&1)"; then
      t_installed=$((t_installed+1))
    else
      warn "FAILED: $name ($url)"
      printf '%s\n' "$out" | tail -4 | sed 's/^/       /'
      t_failed=$((t_failed+1))
    fi
  done < "$BASE/themes.txt"
  # Themes with no git repo ("# LOCAL"): their files travel in yadm (tracked.paths),
  # so after `yadm pull`/clone they are in place. Here we only check that they really arrived.
  while read -r name; do
    [ -n "$name" ] || continue
    if [ ! -d "$THEMES/$name" ]; then
      warn "local theme '$name': no directory - the files should come from the repo"
      warn "  add .config/omarchy/themes/$name to tracked.paths and run: yadm add ... && yadm commit && yadm push"
      warn "  or on this machine: yadm checkout -- .config/omarchy/themes/$name"
      t_local_missing=$((t_local_missing+1)); continue
    fi
    if [ ! -f "$THEMES/$name/colors.toml" ]; then
      warn "local theme '$name': the directory is there, colors.toml is missing - the files are incomplete"
      t_local_missing=$((t_local_missing+1)); continue
    fi
    if [ -z "$(ls -A "$THEMES/$name/backgrounds" 2>/dev/null)" ]; then
      warn "local theme '$name': no backgrounds in backgrounds/ - it cannot set a wallpaper"
      warn "  those files travel in yadm: check tracked.paths and run: yadm checkout -- .config/omarchy/themes/$name"
      t_local_missing=$((t_local_missing+1)); continue
    fi
    t_local_ok=$((t_local_ok+1))
    info "local theme, files from the repo: $name"
  done < <(awk '/^# LOCAL/{print $3}' "$BASE/themes.txt")
  info "from URL: already present=$t_present newly installed=$t_installed repaired=$t_repaired incomplete=$t_incomplete errors=$t_failed | local: ok=$t_local_ok missing=$t_local_missing"
fi

step "4/6  active theme + reload"
slug="$(cat "$BASE/active-theme" 2>/dev/null || true)"
current="$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)"
if [ -n "$slug" ] && [ -d "$THEMES/$slug" ]; then
  if [ "$current" = "$slug" ]; then
    info "theme already set: $slug (not switching)"
  else
    info "setting the theme: $slug (currently: ${current:-?})"
    if (( DRY_RUN )); then
      info "[dry-run] omarchy theme set $slug"
    elif ! out="$(omarchy theme set "$slug" 2>&1)"; then
      warn "omarchy theme set $slug failed:"
      printf '%s\n' "$out" | tail -4 | sed 's/^/       /'
    fi
  fi
elif [ -n "$slug" ]; then
  warn "TARGET THEME MISSING '$slug': there is no directory $THEMES/$slug"
  warn "  so the current theme stays and the desktop may be incomplete (e.g. no wallpaper)"
  warn "  install it by hand:  omarchy theme install <url from themes.txt>  &&  omarchy theme set $slug"
fi
info "reloadConfig + rescanPlugins (shell) and hyprctl reload"
run omarchy-shell -q shell reloadConfig || true
run omarchy-shell -q shell rescanPlugins || true
run sh -c 'command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true'

step "5/6  repo excludes + shell aliases"
# core.excludesFile MUST be in the config of the yadm REPO - only that config is
# read by git. An entry in ~/.config/yadm/config does not work (git does not read
# it) - verified.
want="$BASE/.gitignore"
have="$(yadm gitconfig --get core.excludesFile 2>/dev/null || true)"
if [ "$have" = "$want" ]; then
  info "repo excludes: already set ($want)"
else
  info "setting core.excludesFile in the yadm repo -> $want"
  run yadm gitconfig core.excludesFile "$want" || warn "could not set core.excludesFile"
fi
if (( SKIP_SHELL )); then
  info "--skip-shell: skipping the aliases (the excludes are set anyway)"
else
  info "wiring the alias loading into your shell rc"
  run "$BASE/bin/setup-shell.sh" || warn "setup-shell.sh failed (you can add the aliases by hand)"
fi

step "6/6  manual steps on this machine"
python3 - "$OM/shell.json" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
paths = set()
def walk(x):
    if isinstance(x, dict):
        for k, v in x.items():
            if k in ("passwordFile", "tokenFile", "secretFile") and isinstance(v, str):
                paths.add(v)
            walk(v)
    elif isinstance(x, list):
        for v in x: walk(v)
walk(d)
for p in sorted(paths):
    f = os.path.expanduser(p)
    print(f"   secret outside the repo: {p} -> {'present' if os.path.exists(f) else 'MISSING, fill it in by hand'}")
PY
sed 's/^/   /' "$BASE/manual.md" 2>/dev/null || true
info "check: omarchy plugin list | less   and   omarchy theme current"
info "plugin update: $BASE/bin/plugin-update.sh (the panel-based manager refuses because of runtime junk)"

step "6b/6  verification: repo <-> actual state"
v_problems=0
if (( DRY_RUN )); then
  info "--dry-run: skipping verification (the state is not applied yet)"
elif run "$BASE/bin/verify.sh"; then
  info "verification: no drift"
else
  v_problems=1
fi

# Summary: what did not land. The plugin step weighs the most, but missing themes
# are an error too - without them the desktop does not look like the source machine.
problems=0
if (( failed > 0 || local_missing > 0 )); then
  err "plugins: failed=$failed local_missing=$local_missing"
  err "  check the 'omarchy plugin add' output above (bad URL? network? id conflict?)"
  problems=1
fi
if (( t_failed > 0 || t_incomplete > 0 || t_local_missing > 0 )); then
  err "themes: errors=$t_failed incomplete=$t_incomplete local_missing=$t_local_missing"
  err "  install the missing theme with: omarchy theme install <url from $BASE/themes.txt>"
  err "  then set it: omarchy theme set <name>   (or: $0 --themes-only)"
  problems=1
fi
if (( p_bad > 0 )); then
  err "plugin patches: problems=$p_bad (details above)"
  problems=1
fi
if (( v_problems > 0 )); then
  err "verification: state drift - see step 6b/6 above for details"
  problems=1
fi
if (( problems )); then
  err "import finished with problems - fix the above and run it again: $0"
  exit 1
fi
info "import finished: everything is in place"
exit 0
