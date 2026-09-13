# Aliases for omarchy-desktop-sync.
#
# This file IS synced by your repo (unlike ~/.zshrc, which stays machine-local). Your shell
# loads it through one marked source line that bin/setup-shell.sh adds:
#   [ -f "$HOME/.config/omarchy-desktop/aliases.zsh" ] && source "$HOME/.config/omarchy-desktop/aliases.zsh"
#
# omx - publish this machine's desktop into the repo
# omr - receive the desktop from the repo and apply it
# omv - audit this machine against the repo (read-only, non-zero exit on divergence)
#
# Rename them if they clash with something you already have (a real example: "omp" was taken
# by another launcher, hence omx/omr/omv here).

alias omx="$HOME/.config/omarchy-desktop/bin/export.sh"
alias omr="$HOME/.config/omarchy-desktop/bin/pull.sh"
alias omv="$HOME/.config/omarchy-desktop/bin/verify.sh"
