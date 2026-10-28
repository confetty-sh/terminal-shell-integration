# Shell integration for zsh, reached by pointing ZDOTDIR here.
#
# zsh reads .zshenv first, and from ZDOTDIR. So this puts the user's ZDOTDIR back BEFORE anything of
# theirs runs, and only then sources their .zshenv -- which is where many people move ZDOTDIR
# themselves (export ZDOTDIR=~/.config/zsh). zsh looks ZDOTDIR up afresh for each file it reads, so
# .zprofile, .zshrc and .zlogin then come from wherever the user's configuration says, with nothing
# here forwarding to them. Restoring it any later meant a .zshenv that moved ZDOTDIR sent zsh looking
# for the rest in the user's directory before the integration's .zshrc was ever read: no
# integration, and no error to say so.
#
# The approach follows Ghostty's. The code is not Ghostty's: Ghostty is MIT licensed, but its shell
# scripts derive from Kitty's and are GPLv3.

# Unset when the user had none, exactly as zsh would have started -- a .zshenv that only sets a
# default, ${ZDOTDIR:-~/.config/zsh}, has to find it empty.
if [[ -n "${TERMINAL_SHELL_ZDOTDIR+x}" ]]; then
  builtin export ZDOTDIR="$TERMINAL_SHELL_ZDOTDIR"
  builtin unset TERMINAL_SHELL_ZDOTDIR
else
  builtin unset ZDOTDIR
fi

# zsh treats an unset ZDOTDIR as HOME, and so does this.
[[ -r "${ZDOTDIR-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR-$HOME}/.zshenv"

# Loaded now, while the path to this file is still known; it installs itself at the first prompt,
# after the user's .zshrc has had its say. A script run with zsh has no prompt to mark.
if [[ -o interactive ]]; then
  builtin source "${${(%):-%x}:A:h}/integration.zsh"
fi
