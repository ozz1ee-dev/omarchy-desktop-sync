# How it works

## 1. What ends up in your config repo

```
~/.config/omarchy-desktop/          the tooling itself (it travels, so machines stay consistent)
  bin/export.sh                     publish: manifests, patches, INVENTORY.md, commit, push
  bin/pull.sh                       receive: fetch, collision handling, pull, then import
  bin/import.sh                     apply: plugins, patches, themes, shell.json, reload, verify
  bin/verify.sh                     audit: registry vs manifests vs shell.json, exit code
  bin/inventory.sh                  generates INVENTORY.md
  bin/plugin-update.sh              update plugins without the panel manager's guard
  bin/setup-shell.sh                adds/removes one marked source line in your rc
  bin/theme-doctor.sh               per-theme report
  tracked.paths                     the exact $HOME paths export.sh will add
  plugins.txt                       manifest: where plugins come from
  themes.txt                        manifest: where themes come from
  active-theme                      which theme should be active
  patches/<plugin-id>.patch         your local edits to plugins
  INVENTORY.md                      generated description of the source machine
  settings                          DOTFILES_REPO
  aliases.zsh                       omx / omr / omv
  manual.md                         what the sync deliberately does not do
  .gitignore                        patterns that must never enter the repo

  (plus the tracked config itself: shell.json, hypr/*.lua, omarchy/{extensions,hooks,branding,...})
  ~/.config/yadm/bootstrap          runs import.sh at the end of `yadm clone --bootstrap`
```

The tracked set is whatever is listed in `tracked.paths`. It is explicit on purpose: a bare
`yadm add -A` in a worktree that is your whole `$HOME` would swallow plugin gitlinks and
hundreds of megabytes of wallpapers.

## 2. The two manifests

`plugins.txt` and `themes.txt` are generated on every publish, one line per item:

```
<id-or-slug> <git-url>
# LOCAL <id-or-slug>
```

`# LOCAL` means "there is no remote for this one" - a plugin you cloned locally or a theme
built from a wallpaper. Their **files** are tracked in the repo instead, so a fresh machine
still gets them; anything marked `# LOCAL` must also appear in `tracked.paths`.

The receiving machine reads these manifests and installs whatever is missing with
`omarchy plugin add <url> --yes` / `omarchy theme install <url>`.

## 3. `shell.json` is the state file

Quickshell owns `~/.config/omarchy/shell.json`. The rules below come from
`/usr/share/omarchy/shell/services/PluginRegistry.qml` (`isEnabled()`), not from guessing:

| Plugin kind | Enabled when |
|---|---|
| kinds include `bar` | it is the selected `bar.id` (there is one bar plugin at a time) |
| non-bar, **third-party** | its id is listed in the top-level `plugins[]` array |
| non-bar, **first-party** | by default; switched off by listing it in `disabledPlugins[]` |
| bar widget | it appears in `bar.layout.{left,center,right}` - absence *is* the off state |

Two consequences worth internalising:

- For third-party plugins, **absent from `shell.json` means disabled**. You do not need to
  add ids to `disabledPlugins[]` to switch a third-party plugin off; that array exists for
  first-party infrastructure that would otherwise be implicitly on.
- Nothing in the install path writes this file. `omarchy plugin add` is called *without*
  `--enable` precisely because `--enable` can rewrite `shell.json` and destroy your curated
  bar. The receiving machine gets the file from the repo and applies it with
  `omarchy-shell -q shell reloadConfig`. The only exception is `--restart-shell`, which
  relaunches Quickshell when it keeps stale state in memory.

## 4. Publishing: `omx` -> `bin/export.sh`

1. Regenerate `plugins.txt` (reads `omarchy plugin list --json` + each plugin's git remote).
2. Regenerate `themes.txt`, 3. write `active-theme`, 4. regenerate `patches/*.patch` from the
   plugins you modified locally.
5. Generate `INVENTORY.md`, set `core.excludesFile` in the yadm **repo** config, then
   `yadm add -A -- <tracked.paths>`, then run the junk guard (it refuses to commit anything
   matching `.gitignore`, so `*.lock` / `*.bak*` / `backups/` cannot leak).
6. Commit + push.

`--dry-run` prints the same plan without touching anything.

## 5. Receiving: `omr` -> `bin/pull.sh` + `bin/import.sh`

`pull.sh`:

1. Shows local changes in synced files (they are what breaks a rebase pull).
2. `yadm fetch`, then counts incoming commits.
3. **Collision handling**: any path that is new in the incoming commits but already exists
   locally as an untracked (or ignored) file is moved to `backups/untracked-<timestamp>/`.
   Without this, git aborts with `untracked working tree files would be overwritten by merge`.
   `--keep-untracked` disables the move if you want to look first.
4. `yadm pull --rebase --autostash`, or with `--repo`: local changes go to a stash and the
   repo wins.
5. If the pull succeeded, it hands over to `import.sh`.

`import.sh` (steps as printed):

| Step | What it does |
|---|---|
| 1/6 | install plugins from `plugins.txt` (URL entries) |
| 1b/6 | verify `# LOCAL` plugins (files come from the repo) |
| 1c/6 | report plugin enable-state vs `shell.json` (read-only) |
| 1d/6 | optional `--restart-shell` |
| 2/6 | apply `patches/*.patch` idempotently |
| 3/6 | install missing themes; **auto-repair hollow ones** (a theme with no `backgrounds/` is broken: no wallpaper, and it does not show up in the picker) |
| 4/6 | apply `active-theme`, `reloadConfig`, `rescanPlugins`, `hyprctl reload` |
| 5/6 | set `core.excludesFile` in the repo config, wire the shell aliases |
| 6/6 | print `manual.md` (secrets and per-machine steps) |
| 6b/6 | run `verify.sh`; a divergence makes the whole import exit non-zero |

The script deliberately runs without `set -e` for the converge part: one failing step must not
stop the remaining steps (that bug hid the theme step for a whole evening once).

## 6. Patches

If you edit a plugin locally, that edit cannot come back from the plugin's own git remote.
`export.sh` writes your diff to `patches/<plugin-id>.patch` and `import.sh` re-applies it after
cloning (`git apply --reverse --check` tells whether it is already applied). If upstream moves
and the patch no longer applies, the import reports a conflict instead of guessing.

## 7. `INVENTORY.md`

Generated on every publish: hostname, Omarchy version, shell ping, bar order per section,
third-party plugins split into in-bar / services / installed-but-off, themes, patches, what
travels vs what stays local, and the restore commands. It is the "read the repo on GitHub and
understand this desktop" file.

## 8. Verification

`verify.sh` (also `omv`, also step 6b of every import) checks, read-only:

- plugins declared in `plugins.txt` but missing from the Omarchy registry,
- ids used by `shell.json` (bar layout, `plugins[]`, `disabledPlugins[]`) that do not exist,
- shell health (`omarchy shell shell ping`),
- active theme completeness (`colors.toml` + non-empty `backgrounds/`),
- each patch applied,
- third-party plugins installed but absent from `plugins.txt` (warning: other machines will
  not reproduce them).

Exit code 0 = clean, 1 = divergence.

## 9. Where knowledge is kept

Docs, `manual.md` and the generated `INVENTORY.md` travel with the repo. Local scratch notes
do not - they go stale, they cannot be reviewed, and they quietly contradict the tooling.
