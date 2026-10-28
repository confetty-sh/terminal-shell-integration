# Startup shim for zsh, written clean-room from this library's behaviour spec.
#
# The host points ZDOTDIR at this directory, so zsh reads this file before any of the user's. It
# hands startup back to the user and then loads the prompt marks:
#
#   1. ZDOTDIR goes back to what the user had: the value the host saved in TERMINAL_SHELL_ZDOTDIR,
#      or unset when the host saved nothing. Unset rather than $HOME, because zsh treats the two
#      the same but a .zshenv that only supplies a default -- ${ZDOTDIR:-~/.config/zsh} -- does not.
#   2. The user's own .zshenv runs, from wherever that leaves zsh looking.
#   3. zsh looks up ZDOTDIR afresh for each file after this one, so if their .zshenv moved it (the
#      XDG layout), .zprofile, .zshrc and .zlogin come from the new place with nothing more to do.
#      Nothing here can depend on a .zshrc in this directory ever being read.
#   4. integration.zsh is loaded for interactive shells, before the user's .zshrc. Its hooks then
#      start out ahead of the user's and move themselves to the end at each prompt, which is what
#      keeps the prompt-end mark alive under a theme that rebuilds PS1.
#
# Everything runs at the top level, not inside a function: a function would turn any typeset in
# the user's .zshenv into a local that vanishes when it returns.

if [[ -n ${TERMINAL_SHELL_ZDOTDIR-} ]]; then
  builtin export ZDOTDIR="$TERMINAL_SHELL_ZDOTDIR"
else
  builtin unset ZDOTDIR
fi
builtin unset TERMINAL_SHELL_ZDOTDIR

# Missing or unreadable is not an error: zsh would have skipped it too.
if [[ -r ${ZDOTDIR:-$HOME}/.zshenv ]]; then
  builtin source "${ZDOTDIR:-$HOME}/.zshenv"
fi

# Found through the resources directory, since ZDOTDIR is the user's again by now. Under zsh's own
# emulation, so options set in /etc/zshenv or the user's .zshenv (ksh_arrays, say) cannot change
# what it does; functions defined there keep that emulation whenever they run. Only once, should
# anything source this file a second time.
if [[ -o interactive && -r ${TERMINAL_SHELL_RESOURCES-}/zsh/integration.zsh ]] \
    && (( ! ${+functions[__terminal_precmd]} )); then
  builtin emulate zsh -c 'builtin source "$TERMINAL_SHELL_RESOURCES/zsh/integration.zsh"'
fi
