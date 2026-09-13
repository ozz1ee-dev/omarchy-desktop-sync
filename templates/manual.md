# What the sync deliberately does NOT do

`import.sh` prints this file at the end of every run so the list stays in front of you.
Add your own machine-specific steps here.

## Secrets (never in the repo)

- App and terminal configs that carry an API key or token (for example a transcription or
  mail client config). Copy them by hand, or keep them out of the synced set.
- Password files referenced by plugins (`passwordFile`-style settings) - the repo only
  carries the path, never the secret.
- OAuth logins and keyring entries (Home Assistant tokens, mail accounts, GitHub: `gh auth login`).
  Log in again on each machine.
- SSH keys (`~/.ssh`) and GPG keys (`~/.gnupg`) are out of scope entirely.

## Per machine, on purpose

- `~/.config/hypr/monitors.lua` - monitor layout, scale, refresh rate.
- Generated files such as `~/.config/hypr/omarchy-workspace-layout.lua` (written by a plugin).
- The wallpaper you picked and any runtime state under `~/.local/state/omarchy/`.
- `~/.zshrc` / `~/.bashrc` - they hold machine-local paths and tokens. Only the marked
  `source` block for the aliases is added automatically.

## After a fresh import, check

- Audio (WirePlumber), keyboard layout, Bluetooth - these follow the hardware, not the config.
- Keyring unlocked (`gnome-keyring`): widgets holding tokens will not start without it.
- Plugins shipping prebuilt binaries may need a rebuild on a different architecture
  (x86_64 vs aarch64).
