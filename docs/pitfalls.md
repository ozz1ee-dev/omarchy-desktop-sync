# Pitfalls (each one cost real time)

Everything here was observed on a live two-machine setup (aarch64 + x86_64). Symptom first,
then what is actually going on.

## 1. Plugin and theme directories are git repositories

`~/.config/omarchy/plugins/<id>` and `themes/<slug>` are clones. Adding them to another git
repo records **gitlinks** (mode `160000`): the other machine gets empty directories. Check
with `git ls-files -s <path> | awk '$1=="160000"'`.

**Do:** track manifests (`plugins.txt`, `themes.txt`) and let the receiving machine install.
Track files only for items with no remote (`# LOCAL`).

## 2. Never run a bare `yadm add -A`

The yadm worktree is your whole `$HOME`. A bare `yadm add -A` swallows gitlinks, wallpapers,
lock videos and megabytes of binaries. `export.sh` only ever adds the explicit list from
`tracked.paths`.

## 3. `yadm config core.excludesFile` does not work (and the test that hides it)

`yadm config` writes *yadm's own* file, `~/.config/yadm/config`, which git never reads:
`/usr/bin/yadm` has no `excludesFile` handling and does not forward `core.*` to git. The
symptom is junk (`*.lock`, `*.bak*`) quietly entering the repo.

**Do:** `yadm gitconfig core.excludesFile <path>` (writes the repo config that git reads), set
by `import.sh` on every machine and by `export.sh` before every commit.

**Testing method matters:** `git check-ignore` prints nothing for files that are already
tracked - ignore rules do not apply to tracked paths. Test with `--no-index` on an *untracked*
probe file:

```bash
touch probe.lock
yadm check-ignore --no-index -v probe.lock   # must print the pattern
```

Testing on a tracked file, or without `--no-index`, produces a confident wrong answer. That
mistake once shipped a "fix" whose only effect was to remove the *working* mechanism.

## 4. `--autostash` does not cover untracked files

So a file that is new in the incoming commits, while a local untracked copy exists, aborts the
pull:

```
error: The following untracked working tree files would be overwritten by merge
```

This recurs every time a path is newly added to `tracked.paths` on the source machine.
`pull.sh` detects it (compares incoming-added paths against local paths that exist but are not
tracked) and moves the local copies into `backups/untracked-<ts>/` first. Nothing is deleted.
Ignored local files are clobbered silently by the same pull, so they go into the same backup
pass.

## 5. `shell.json` belongs to Quickshell

The shell rewrites it on its own (layout shuffles, normalisation). A script that "fixes up"
the file races the shell and can lose your curated bar.

**Do:** treat it as input on the receiving machine; run `omarchy plugin add` without
`--enable`; if the bar keeps the old layout after a pull, `omr --restart-shell`.

## 6. Plugin state semantics surprise people twice

For **third-party** plugins, absent from `shell.json` already means disabled - no
`disabledPlugins[]` entry needed. That array is for **first-party** plugins, which are
implicitly enabled and therefore recorded the other way round. See
`/usr/share/omarchy/shell/services/PluginRegistry.qml` (`isEnabled`). Making the state
"explicit" for third-party plugins is busywork that also makes `shell.json` machine-specific,
so other machines keep rewriting it back.

## 7. A theme can be installed and hollow

If a theme has `colors.toml` but no `backgrounds/`, it loads as "current", shows no wallpaper
and never appears in the picker. Old file-copying synchronisers cause this by filtering images.
Completeness = non-empty `colors.toml` **and** non-empty `backgrounds/`. `import.sh` repairs
hollow themes automatically unless the directory has your own modifications (then it warns).

Also: `omarchy theme install <url>` does `rm -rf` first **and sets the theme active**. After a
repair run, re-apply the recorded `active-theme` - `import.sh` does.

## 8. The panel plugin manager refuses to update plugins

`Dirty, untracked or ignored files present` comes from the panel plugin manager's helper
(`helpers/pinned_update.py`, `check_clean`): it demands the plugin directory be byte-identical
to HEAD, including file modes, so any runtime file (`__pycache__/`, `runtime/`, caches) blocks
it forever - those files come back every time the plugin runs. `plugin-update.sh` uses the
built-in `omarchy plugin update`, which only refuses on real content changes.

Related: a plugin directory without the owner `x` bit reports `enabled: true` but never
`active: true` - the shell silently cannot read it. Directory modes are not tracked by git, so
`chmod u+x` on each plugin directory is safe.

## 9. `set -e` in a converge script hides whole steps

`import.sh` grew `set -e` early on; the first plugin error then aborted the run *before* the
theme step, so themes silently never arrived. A converge script should collect problems and
exit non-zero at the end, not stop at the first failure.

## 10. `yadm clone` does not overwrite existing files

On a machine that already ran Omarchy, differing files are left untouched. Review
`yadm status`, then take the repo version explicitly: `yadm checkout -f -- <path>`.

## 11. Pick alias names that are actually free

`omp` was already taken by another launcher on the test machine, which is why this project
uses `omx` / `omr` / `omv`. Check with `command -v <name>` before wiring aliases.

## 12. Testing yadm scripts in a sandbox: `HOME` is not enough

yadm resolves its data directory from an absolute `XDG_DATA_HOME` first
(`set_yadm_dirs()`: `$XDG_DATA_HOME/yadm`, else `$HOME/.local/share/yadm`). With an exported
`XDG_DATA_HOME`, a fake-`HOME` test run silently operates on the **real** repo. Use:

```bash
env -u XDG_DATA_HOME -u XDG_CONFIG_HOME HOME=/tmp/sandbox yadm status
```

`YADM_DATA` / `YADM_DIR` are honoured when already set, which is the cleanest override.
