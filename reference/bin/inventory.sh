#!/usr/bin/env bash
# GENERATES INVENTORY.md - a readable description of this desktop (what is installed,
# what is enabled, what lives where). Run by export.sh on every `omx`, so the file in
# the repo is always current and visible on GitHub without cloning.
#
# This script changes NOTHING except INVENTORY.md. Do not edit INVENTORY.md by hand -
# it will be overwritten on the next `omx`.
set -uo pipefail

BASE="$HOME/.config/omarchy-desktop"
if [ -f "$BASE/settings" ]; then . "$BASE/settings"; fi
DOTFILES_REPO="${DOTFILES_REPO:-}"
OUT="$BASE/INVENTORY.md"

info() { printf '   %s\n' "$*"; }

python3 - "$DOTFILES_REPO" <<'PY' > "$OUT" || { echo "   !! inventory: failed to generate" >&2; exit 1; }
import json, os, subprocess, glob, datetime, socket, sys

HOME = os.path.expanduser("~")
BASE = os.path.join(HOME, ".config/omarchy-desktop")
SHELL_JSON = os.path.join(HOME, ".config/omarchy/shell.json")
THEMES = os.path.join(HOME, ".config/omarchy/themes")

# URL of the dotfiles repo, handed over from bash (fallback when the setting is empty)
DOTFILES_REPO = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else "<your-dotfiles-repo-url>"

BAR_SECTIONS = ("left", "center", "right")


def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception:
        return ""


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return default


def readlines(path):
    try:
        with open(path) as f:
            return [l.strip() for l in f if l.strip()]
    except Exception:
        return []


# --- inputs --------------------------------------------------------------------
shell = {}
try:
    shell = json.load(open(SHELL_JSON))
except Exception:
    pass

plugins = []
raw = sh(["omarchy", "plugin", "list", "--json"])
if raw:
    try:
        data = json.loads(raw)
        plugins = data if isinstance(data, list) else data.get("plugins", [])
    except Exception:
        plugins = []

by_id = {p.get("id"): p for p in plugins}


def kinds(pid):
    return ",".join((by_id.get(pid) or {}).get("kinds") or []) or "?"


def is_third(pid):
    p = by_id.get(pid)
    return bool(p) and not p.get("firstParty")


# bar.layout is an OBJECT: {left: [...], center: [...], right: [...]}
bar = shell.get("bar") or {}
bar_id = bar.get("id") or "omarchy.bar"
sections = {}
for sec in BAR_SECTIONS:
    entries = ((bar.get("layout") or {}).get(sec)) or []
    ids = []
    for e in entries:
        if isinstance(e, dict):
            ids.append(e.get("id") or e.get("widget") or "?")
        else:
            ids.append(str(e))
    sections[sec] = ids
layout_all = [w for sec in BAR_SECTIONS for w in sections[sec]]

services = []
for entry in (shell.get("plugins") or []):
    services.append(entry.get("id") if isinstance(entry, dict) else str(entry))

disabled = [str(x) for x in (shell.get("disabledPlugins") or [])]

third_all = [p.get("id") for p in plugins if not p.get("firstParty")]
third_in_bar = [w for w in layout_all if is_third(w)]
third_off = [t for t in third_all if t not in layout_all and t not in services and t not in disabled]

themes_url, themes_local = [], []
for line in readlines(os.path.join(BASE, "themes.txt")):
    if line.startswith("# LOCAL"):
        themes_local.append(line.split()[-1])
    elif not line.startswith("#"):
        themes_url.append(line.split()[0])

active_theme = read(os.path.join(BASE, "active-theme")) or "?"
patches = sorted(os.path.basename(p) for p in glob.glob(os.path.join(BASE, "patches", "*.patch")))

bindings = os.path.join(HOME, ".config/hypr/bindings.lua")
n_bind = 0
for l in readlines(bindings):
    if l.startswith("--"):
        continue
    if ".bind(" in l or ".unbind(" in l:
        n_bind += 1

# Omarchy package version (pacman is the source of truth, not just `omarchy version`)
n_ver = ""
q = sh(["pacman", "-Q", "omarchy"])
if q.startswith("omarchy "):
    n_ver = q.split()[1]
else:
    n_ver = sh(["omarchy", "version"]) or "(not detected)"

shell_ping = sh(["omarchy", "shell", "shell", "ping"]) or "no response"

# --- report --------------------------------------------------------------------
now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
host = socket.gethostname()

print("# INVENTORY - what is on this desktop")
print()
print(f"Generated automatically by `omx` (`bin/inventory.sh`) on machine **{host}**, {now}. "
      "The file is overwritten on every export - do not edit it by hand.")
print()
print("| | |")
print("|---|---|")
print(f"| Machine (hostname) | `{host}` |")
print(f"| Omarchy | {n_ver} |")
print(f"| Shell responds (`ping`) | `{shell_ping}` |")
print(f"| Active theme | `{active_theme}` |")
print(f"| Bar | `{bar_id}` |")
print(f"| Widgets in the bar | {len(layout_all)} |")
print(f"| Plugins registered | {len(plugins)} (first-party: {sum(1 for p in plugins if p.get('firstParty'))}) |")
print(f"| Your keybindings in `bindings.lua` | {n_bind} |")
print()

print("## Bar (widget order)")
print()
for sec in BAR_SECTIONS:
    ids = sections[sec]
    print(f"**{sec}** ({len(ids)}): " + (", ".join(f"`{w}`" for w in ids) if ids else "(empty)"))
    print()

print("## Third-party plugins")
print()
print(f"- **In the bar**: {len(third_in_bar)}")
print(f"- **As services / panels / overlays (`plugins[]`)**: {len([s for s in services if is_third(s)])}")
print(f"- **Installed but disabled**: {len(third_off)}")
print()
print("The shell does not enable a third-party plugin that is in neither `bar.layout` nor `plugins[]`")
print("(rule from `shell/services/PluginRegistry.qml`). This is the state saved in the repo, not an error:")
print()
for pid in sorted(third_off):
    print(f"- `{pid}` ({kinds(pid)})")
print()

if services:
    print("### Services / panels / overlays enabled (`plugins[]`)")
    print()
    for sid in services:
        print(f"- `{sid}` ({kinds(sid)})")
    print()

if disabled:
    print("### Explicitly disabled (`disabledPlugins[]`)")
    print()
    print("This mechanism covers plugins the shell would enable on its own (first-party infrastructure):")
    print()
    for did in disabled:
        fp = "first-party" if (by_id.get(did) or {}).get("firstParty") else "third-party"
        print(f"- `{did}` ({fp})")
    print()

print("## Themes")
print()
print(f"- Active: `{active_theme}` (file `active-theme`)")
print(f"- From URL, cloned by `omarchy theme install`: {len(themes_url)}")
print(f"- Local, files in the repo: {len(themes_local)}"
      + (f" -> {', '.join('`' + t + '`' for t in themes_local)}" if themes_local else ""))
print()

print("## Local plugin patches (`patches/`)")
print()
if patches:
    print("These changes cannot be reproduced from the plugin upstream - `import.sh` applies them after the clone:")
    print()
    for p in patches:
        print(f"- `{p}`")
else:
    print("(none)")
print()

print("## What travels in the repo and what stays local")
print()
print("| Travels (`omx` -> `omr`) | Stays on the machine |")
print("|---|---|")
print("| `shell.json` - bar, widgets, what is enabled | `~/.zshrc` (aliases appended by `setup-shell.sh`) |")
print("| `plugins.txt`, `themes.txt`, `active-theme` | `~/.config/hypr/monitors.lua` |")
print("| `~/.config/omarchy/{extensions,hooks,branding,defaults,...}` | API keys, passwords, keyring tokens |")
print("| `~/.config/hypr/*.lua` without `monitors.lua` | runtime state `~/.local/state/...` |")
print("| `patches/*.patch`, `bin/*.sh`, `aliases.zsh` | selected background / wallpaper |")
print()

print("## Recreating on another machine")
print()
print("```bash")
print("sudo pacman -S yadm git")
print("yadm clone --bootstrap " + DOTFILES_REPO)
print("# later, after every change on the donor machine, on the receiving machine:")
print("omr        # pull + fetch missing plugins and themes + set the state")
print("```")
print()
print("Manual steps the sync cannot do by itself: secrets (API keys in app configs, passwords "
      "in the keyring) and plugin binaries built per architecture (x86_64 vs aarch64).")
PY

if [ -s "$OUT" ]; then
  info "INVENTORY.md: $(wc -l < "$OUT") lines, $(du -h "$OUT" | cut -f1)"
else
  echo "   !! inventory: the file came out empty" >&2
  exit 1
fi
