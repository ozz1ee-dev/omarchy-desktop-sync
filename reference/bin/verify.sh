#!/usr/bin/env bash
# STATE VERIFICATION (read-only, changes nothing).
#
# Checks whether what you have on this machine matches what is recorded in the repo:
#   plugins.txt (what should be installed)  <->  Omarchy registry (what is)
#   shell.json  (what should be enabled)    <->  Omarchy registry (what exists)
#   active theme                            ->   complete? (colors.toml + backgrounds)
#   patches/*.patch                         ->   applied to the plugins?
#   shell                                   ->   does it answer a ping?
#
# Exit: 0 = no drift, 1 = drift to fix.
# Runs automatically at the end of import.sh (step 6b/6) - it can also be called by hand
# on any machine: ~/.config/omarchy-desktop/bin/verify.sh
set -uo pipefail

# English messages regardless of your locale (git ships its own translations)
export LC_MESSAGES=C

BASE="${1:-$HOME/.config/omarchy-desktop}"
if [ -f "$BASE/settings" ]; then . "$BASE/settings"; fi
DOTFILES_REPO="${DOTFILES_REPO:-}"
PLUGINS="${2:-$HOME/.config/omarchy/plugins}"
THEMES="${3:-$HOME/.config/omarchy/themes}"
SHELL_JSON="${4:-$HOME/.config/omarchy/shell.json}"

python3 - "$BASE" "$PLUGINS" "$THEMES" "$SHELL_JSON" <<'PY'
import json, os, subprocess, sys, glob

BASE, PLUGINS, THEMES, SHELL_JSON = sys.argv[1:5]
errors = []
warns = []


def sh(cmd, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30, **kw).stdout.strip()
    except Exception:
        return ""


def readlines(path):
    try:
        with open(path) as f:
            return [l.strip() for l in f if l.strip()]
    except Exception:
        return []


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return ""


# --- 1. plugin registry -------------------------------------------------------
registry = []
raw = sh(["omarchy", "plugin", "list", "--json"])
if raw:
    try:
        data = json.loads(raw)
        registry = data if isinstance(data, list) else data.get("plugins", [])
    except Exception:
        errors.append("could not parse `omarchy plugin list --json`")
reg_ids = {p.get("id") for p in registry}
third = [p.get("id") for p in registry if not p.get("firstParty")]

# --- 2. plugins.txt -----------------------------------------------------------
decl_url, decl_local = [], []
for line in readlines(os.path.join(BASE, "plugins.txt")):
    if line.startswith("# LOCAL"):
        decl_local.append(line.split()[-1])
    elif not line.startswith("#"):
        parts = line.split()
        if parts:
            decl_url.append(parts[0])
declared = decl_url + decl_local

print(f"   Omarchy registry: {len(registry)} plugins "
      f"(first-party {len(registry) - len(third)}, third-party {len(third)})")
print(f"   plugins.txt: {len(declared)} declared "
      f"({len(decl_url)} URL + {len(decl_local)} LOCAL)")

missing = [p for p in declared if p not in reg_ids]
if missing:
    for p in missing:
        kind = "LOCAL (files)" if p in decl_local else "URL"
        errors.append(f"declared in plugins.txt but missing from the registry: {p} [{kind}]")

undeclared = [p for p in third if p not in declared]
if undeclared:
    warns.append(f"installed, but not listed in plugins.txt (another machine will not reproduce them): "
                 f"{len(undeclared)} -> {', '.join(sorted(undeclared))}")

# --- 3. shell.json vs registry ------------------------------------------------
try:
    sh_cfg = json.load(open(SHELL_JSON))
except Exception:
    sh_cfg = {}
    errors.append(f"cannot read {SHELL_JSON}")

bar_layout = ((sh_cfg.get("bar") or {}).get("layout") or {})
bar_ids = []
for sec in ("left", "center", "right"):
    for e in (bar_layout.get(sec) or []):
        bar_ids.append(e.get("id") if isinstance(e, dict) else str(e))
svc_ids = [(e.get("id") if isinstance(e, dict) else str(e)) for e in (sh_cfg.get("plugins") or [])]
dis_ids = [str(x) for x in (sh_cfg.get("disabledPlugins") or [])]

for src, ids in (("bar.layout", bar_ids), ("plugins[]", svc_ids), ("disabledPlugins[]", dis_ids)):
    for pid in ids:
        if pid and pid not in reg_ids:
            errors.append(f"{src} points to an id that is not in the registry (not installed?): {pid}")

in_bar = [p for p in bar_ids if p in third]
in_svc = [p for p in svc_ids if p in third]
off = [p for p in third if p not in bar_ids and p not in svc_ids and p not in dis_ids]
print(f"   third-party: in bar {len(in_bar)} | services/panels {len(in_svc)} | disabled {len(off)}")
if off:
    lista = sorted(off)
    pokaz = ", ".join(lista[:25]) + (f" (+{len(lista) - 25} more)" if len(lista) > 25 else "")
    print(f"   disabled (this is the state recorded in the repo, not an error): {pokaz}")

# --- 4. is the shell alive? ---------------------------------------------------
ping = sh(["omarchy", "shell", "shell", "ping"])
if ping != "ok":
    errors.append(f"shell does not answer a ping (reply: {ping or 'none'}) - try: "
                  f"{BASE}/bin/import.sh --restart-shell")
else:
    print("   shell: ping ok")

# --- 5. active theme is complete ---------------------------------------------
theme = read(os.path.join(BASE, "active-theme"))
tdir = os.path.join(THEMES, theme)
if not theme:
    warns.append("missing the active-theme file")
elif not os.path.isdir(tdir):
    errors.append(f"active theme '{theme}' does not exist on disk - "
                  f"fix: omarchy theme install <url from themes.txt>")
else:
    colors = os.path.join(tdir, "colors.toml")
    bgs = os.path.join(tdir, "backgrounds")
    n_bg = len([f for f in os.listdir(bgs)]) if os.path.isdir(bgs) else 0
    if not (os.path.exists(colors) and os.path.getsize(colors) > 0 and n_bg > 0):
        errors.append(f"active theme '{theme}' is incomplete "
                      f"(colors.toml: {'present' if os.path.exists(colors) else 'MISSING'}, backgrounds: {n_bg}) - "
                      f"fix: {BASE}/bin/import.sh --themes-only")
    else:
        print(f"   active theme '{theme}': complete (colors.toml + {n_bg} backgrounds)")

# --- 6. are the patches applied? ---------------------------------------------
applied = notapplied = conflicted = absent = 0
for patch in sorted(glob.glob(os.path.join(BASE, "patches", "*.patch"))):
    pid = os.path.basename(patch)[:-len(".patch")]
    d = os.path.join(PLUGINS, pid)
    if not os.path.isdir(d):
        absent += 1
        warns.append(f"patch '{pid}' has no plugin directory (skipped)")
        continue
    if subprocess.run(["git", "-C", d, "apply", "--reverse", "--check", patch],
                      capture_output=True).returncode == 0:
        applied += 1
    elif subprocess.run(["git", "-C", d, "apply", "--check", patch],
                        capture_output=True).returncode == 0:
        notapplied += 1
        errors.append(f"patch '{pid}' is NOT applied - run: {BASE}/bin/import.sh --skip-themes")
    else:
        conflicted += 1
        errors.append(f"patch '{pid}' does not apply to the plugin (did upstream change?)")
print(f"   patches: {applied} applied, {notapplied} to apply, {conflicted} conflict, {absent} without plugin")

# --- 7. INVENTORY.md ----------------------------------------------------------
inv = os.path.join(BASE, "INVENTORY.md")
print(f"   INVENTORY.md: {'present' if os.path.exists(inv) else 'MISSING'} "
      f"(generated by omx on the source machine)")

# --- result -------------------------------------------------------------------
for w in warns:
    print(f"   ~ {w}")
for e in errors:
    print(f"   ! {e}")
if errors:
    print(f"\n   result: DRIFT ({len(errors)}) - fix the above; warnings: {len(warns)}")
    sys.exit(1)
print(f"\n   result: OK - the state on this machine matches the repo"
      + (f" (warnings: {len(warns)})" if warns else ""))
PY
