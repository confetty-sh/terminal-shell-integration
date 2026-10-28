# Shell integration for zsh: OSC 133 prompt marks and OSC 7 working directory.
#
# Sourced by the .zshenv beside it, which has already put the user's ZDOTDIR back -- and so before
# the user's .zshrc runs, which matters below: hooks it adds land behind these.
#
# The approach follows Ghostty's, but not its code: Ghostty's shell scripts derive from Kitty's and
# are GPLv3.

__terminal_report_cwd() {
  # Only the percent needs escaping. The consumer unescapes what arrives, so a directory whose
  # name contains a valid-looking sequence -- a%2Fb -- would come back as a/b, silently wrong.
  # Everything else survives unescaping untouched, so encoding it would be work for nothing.
  builtin printf '\033]7;file://%s%s\007' "${HOST:-}" "${PWD//\%/%25}"
}

# Before each prompt: the status of the command that just finished, then the new prompt.
#
# Runs LAST among the precmd hooks, from the second prompt on. A theme that rebuilds PS1 on every
# prompt (powerlevel10k, starship) does it in a precmd hook, and a B appended before that is thrown
# away with the old PS1. zsh hands every precmd hook the same $?, so running last costs nothing in
# the status.
__terminal_precmd() {
  # NOT named "status": in zsh that is a special parameter aliased to $?, and declaring it local
  # makes this function fail silently — the prompt still appeared and only the A and D marks went
  # missing, which is a hard symptom to read backwards.
  local __terminal_status=$?

  if [[ -n "$__terminal_command_running" ]]; then
    builtin printf '\033]133;D;%s\007' "$__terminal_status"
    unset __terminal_command_running
  fi

  __terminal_report_cwd
  builtin printf '\033]133;A\007'

  # B marks where the prompt ends and typing begins. %{ %} tells zsh the sequence occupies no
  # columns; without it the prompt's measured width is wrong and line wrapping goes with it.
  # Checked every prompt, because whatever rebuilt PS1 dropped the last one.
  if [[ "$PS1" != *'133;B'* ]]; then
    PS1="$PS1"$'%{\033]133;B\007%}'
  fi

  # The line editor's module is not loaded yet while .zshenv runs, so its hook is added here,
  # once -- still in time for the first prompt, which is the one that needs it.
  if [[ -z "$__terminal_zle_hooked" ]]; then
    __terminal_zle_hooked=1
    builtin autoload -Uz add-zle-hook-widget \
      && add-zle-hook-widget zle-line-init __terminal_line_init 2>/dev/null
  fi

  # The user's .zshrc added its hooks behind this one, and so may anything later. Back to the end,
  # for the NEXT prompt: zsh runs this round from a copy of the list, so moving now changes nothing
  # until then. The first prompt's B is the line editor's job, below.
  if [[ "${precmd_functions[-1]}" != __terminal_precmd ]]; then
    precmd_functions=(${precmd_functions:#__terminal_precmd} __terminal_precmd)
  fi
}

# Before a command runs: the prompt is over and output begins.
__terminal_preexec() {
  __terminal_command_running=1
  builtin printf '\033]133;C\007'
}

# When the line editor starts, the prompt has been drawn and the cursor sits where typing begins,
# which is exactly where B belongs. So if a hook that ran after the precmd rebuilt PS1 without it --
# on the first prompt, before the precmd has made its way to the end -- B is written from here
# instead. Not when PS1 still carries it, or the prompt would be marked twice.
__terminal_line_init() {
  if [[ "$PS1" != *'133;B'* ]]; then
    builtin printf '\033]133;B\007'
  fi
}

builtin typeset -ag precmd_functions preexec_functions
precmd_functions+=(__terminal_precmd)
preexec_functions+=(__terminal_preexec)
