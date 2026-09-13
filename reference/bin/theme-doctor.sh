#!/usr/bin/env bash
# omarchy-desktop :: theme-doctor
#
# Collects in ONE run everything needed to explain why themes are missing on
# this machine. It installs nothing and removes nothing - apart from a trial
# clone into a temporary directory (it checks the network and the disk space).
#
# Run it and paste the whole output:  ~/.config/omarchy-desktop/bin/theme-doctor.sh

set -uo pipefail

# English messages regardless of your locale (git ships its own translations)
export LC_MESSAGES=C
BASE="$HOME/.config/omarchy-desktop"
if [ -f "$BASE/settings" ]; then . "$BASE/settings"; fi
DOTFILES_REPO="${DOTFILES_REPO:-}"
OM="$HOME/.config/omarchy"
THEMES="$OM/themes"
STATE="$HOME/.local/state/omarchy/current"

hdr() { printf '\n=== %s ===\n' "$*"; }
row() { printf '  %-34s %s\n' "$1" "$2"; }

hdr "machine and versions"
row "hostname" "$(hostname -s)"
row "git" "$(git --version 2>/dev/null || echo MISSING)"
row "omarchy" "$(omarchy version 2>/dev/null | head -1 || echo MISSING)"
row "yadm HEAD" "$(cd "$HOME" && yadm log -1 --format='%h %s' 2>/dev/null || echo 'MISSING/not a repo')"
row "yadm status" "$(cd "$HOME" && yadm status --porcelain 2>/dev/null | wc -l) changed/unknown"
row "files tracked" "$(cd "$HOME" && yadm ls-files 2>/dev/null | wc -l)"

hdr "disk space"
df -h "$HOME" | tail -1 | sed 's/^/  /'
row "required for 17 themes" "~739 MB"

hdr "theme list in the repo"
if [ -f "$BASE/themes.txt" ]; then
  row "file" "$BASE/themes.txt"
  row "entries with URL" "$(awk '!/^#/ && NF>1' "$BASE/themes.txt" | wc -l)"
  row "entries # LOCAL" "$(grep -c '^# LOCAL' "$BASE/themes.txt" || true)"
else
  row "themes.txt" "MISSING (!) - the repo is not cloned or the file never arrived"
fi
if [ -f "$BASE/active-theme" ]; then row "active-theme" "$(cat "$BASE/active-theme")"; else row "active-theme" "MISSING file"; fi

hdr "state on this machine"
row "directories in $THEMES" "$(ls -d "$THEMES"/*/ 2>/dev/null | wc -l)"
row "omarchy theme list" "$(omarchy theme list 2>/dev/null | wc -l) entries"
row "active (theme.name)" "$(cat "$STATE/theme.name" 2>/dev/null || echo 'no file')"
if [ -d "$STATE/theme" ]; then row "copy in state/current/theme" "present ($(ls "$STATE/theme" | wc -l) files)"; else row "copy in state/current/theme" "MISSING"; fi

hdr "per theme from themes.txt"
while read -r name url; do
  case "$name" in ''|'#'*) continue ;; esac
  if [ -d "$THEMES/$name" ]; then
    if [ -f "$THEMES/$name/colors.toml" ]; then
      row "$name" "OK ($(find "$THEMES/$name" -type f -not -path '*/.git/*' | wc -l) files, backgrounds: $(ls "$THEMES/$name/backgrounds" 2>/dev/null | wc -l))"
    else
      row "$name" "INCOMPLETE - the directory exists, colors.toml is missing"
    fi
  else
    row "$name" "MISSING directory"
  fi
done < "$BASE/themes.txt" 2>/dev/null

hdr "per local theme (# LOCAL)"
while read -r name; do
  [ -n "$name" ] || continue
  if [ -d "$THEMES/$name" ]; then
    if [ -f "$THEMES/$name/colors.toml" ]; then row "$name" "OK (from the yadm repo)"
    else row "$name" "INCOMPLETE - colors.toml missing"; fi
  else
    row "$name" "MISSING - it never arrived via yadm (tracked.paths?)"
  fi
done < <(awk '/^# LOCAL/{print $3}' "$BASE/themes.txt" 2>/dev/null)

hdr "theme repo reachability test (without downloading content)"
if [ -f "$BASE/themes.txt" ]; then
  while read -r name url; do
    case "$name" in ''|'#'*) continue ;; esac
    if timeout 30 git ls-remote --exit-code -q "$url" HEAD >/dev/null 2>/tmp/theme-probe.err; then
      row "$name" "repo responds"
    else
      row "$name" "ERROR: $(head -2 /tmp/theme-probe.err | tr '\n' ' ' | cut -c1-90)"
    fi
  done < "$BASE/themes.txt"
fi

hdr "Omarchy/Quickshell log about themes"
if command -v journalctl >/dev/null 2>&1; then
  journalctl --user -n 0 2>/dev/null >/dev/null || true
  { journalctl --user --since '-30 min' 2>/dev/null | grep -iE 'theme' | tail -12; } | sed 's/^/  /' || true
fi

hdr "what to do next"
echo "  * MISSING directory + clone OK      -> omarchy theme install <url>  (then: omarchy theme set <name>)"
echo "  * CLONE FAILED                     -> the cause is in the message above (network/space/access)"
echo "  * directory present, no colors.toml -> reinstall: omarchy theme install <url>"
echo "  * everything OK, absent from picker -> rescan: omarchy-shell -q shell rescanPlugins ; omarchy theme list"
echo "  * sync only: $BASE/bin/import.sh --themes-only"
