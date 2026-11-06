# Shell integration for zsh: OSC 133 prompt marks and OSC 7 working directory, plus the features
# the host turned on in TERMINAL_SHELL_FEATURES.
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

# Whether the host turned a feature on. The list is Ghostty's shape -- cursor:blink,sudo,title --
# so a name is matched whole, up to its comma or the colon that carries a setting.
__terminal_feature() { [[ ",${TERMINAL_SHELL_FEATURES-}," == *",$1"[,:]* ]]; }

# The bar for the prompt: DECSCUSR 5 blinks, 6 is steady. Empty when the feature is off.
typeset -g __terminal_bar=
if __terminal_feature cursor; then
  if [[ ",$TERMINAL_SHELL_FEATURES," == *",cursor:steady,"* ]]; then __terminal_bar=6; else __terminal_bar=5; fi
fi

typeset -g __terminal_title=0
__terminal_feature title && __terminal_title=1

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

  # %~ is the directory as zsh's own prompts show it: ~ for home, and named directories by name.
  (( __terminal_title )) && builtin printf '\033]2;%s\007' "${${(%):-%~}//[[:cntrl:]]/}"

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
    if [[ -n "$__terminal_bar" ]]; then
      add-zle-hook-widget zle-keymap-select __terminal_cursor_for_keymap 2>/dev/null
    fi

    # And the wrappers, for the same reason as the hook: only now has the user's .zshrc run, so
    # only now is it known whether sudo or ssh is already theirs.
    __terminal_wrap_commands
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
  [[ -n "$__terminal_bar" ]] && builtin printf '\033[0 q'

  # The line as typed; zsh passes an empty one when history is off, and then the one it shows in
  # history listings, which is the same command cut short.
  if (( __terminal_title )); then
    local line="${1:-$2}"
    builtin printf '\033]2;%s\007' "${line//[[:cntrl:]]/}"
  fi
}

# The bar at the prompt, and the block for vi command mode: a bar there would say "inserting"
# while every key is a command. 0 goes back before each command, which is the user's own cursor.
__terminal_cursor_for_keymap() {
  case "$KEYMAP" in
    vicmd|visual) builtin printf '\033[%d q' $(( __terminal_bar - 4 )) ;;
    *)            builtin printf '\033[%d q' $__terminal_bar ;;
  esac
}

# When the line editor starts, the prompt has been drawn and the cursor sits where typing begins,
# which is exactly where B belongs. So if a hook that ran after the precmd rebuilt PS1 without it --
# on the first prompt, before the precmd has made its way to the end -- B is written from here
# instead. Not when PS1 still carries it, or the prompt would be marked twice.
__terminal_line_init() {
  if [[ "$PS1" != *'133;B'* ]]; then
    builtin printf '\033]133;B\007'
  fi
  [[ -n "$__terminal_bar" ]] && __terminal_cursor_for_keymap
  return 0
}

# Wrappers for sudo and ssh, each only over a plain command: an alias or function of the user's is
# theirs, and wrapping it would either lose what it does or loop.
__terminal_wrap_commands() {
  # sudo: keep TERMINFO, which sudo's env_reset drops. Only when there is one -- a host that ships
  # its own terminfo sets it, and a TERM from the system database needs nothing kept. sudoedit
  # (-e, --edit) is left alone, since it never runs a program on this terminal.
  if __terminal_feature sudo && [[ -n "${TERMINFO-}" ]] \
      && (( ${+commands[sudo]} && ! ${+aliases[sudo]} && ! ${+functions[sudo]} )); then
    sudo() {
      local arg letters letter skip=0
      for arg in "$@"; do
        if (( skip )); then skip=0; continue; fi
        case "$arg" in
          -e|--edit) builtin command sudo "$@"; return ;;
          --close-from|--chdir|--group|--prompt|--chroot|--role|--command-timeout|--type|--other-user|--user)
            skip=1 ;;  # its value is the next argument
          --) break ;;
          --*) ;;
          -?*)
            # Short options, alone or run together: -E, -iu root, -uroot. A letter that takes a value
            # takes the rest of the run, or the next argument when it is the last.
            letters="${arg#-}"
            while [[ -n "$letters" ]]; do
              letter="${letters:0:1}"
              letters="${letters:1}"
              case "$letter" in
                e) builtin command sudo "$@"; return ;;
                [CDgpRrTtUu]) [[ -z "$letters" ]] && skip=1; break ;;
              esac
            done ;;
          *=*) ;;
          *) break ;;  # the command sudo is to run; what follows is its own
        esac
      done
      builtin command sudo --preserve-env=TERMINFO "$@"
    }
  fi

  # ssh-env: offer the remote what this terminal is. SendEnv adds to whatever the user's ssh_config
  # sends, and the remote takes only what its sshd_config AcceptEnv allows. When TERM comes from a
  # private terminfo (TERMINFO is set) the remote will not have it, so the connection gets
  # xterm-256color instead.
  if __terminal_feature ssh-env \
      && (( ${+commands[ssh]} && ! ${+aliases[ssh]} && ! ${+functions[ssh]} )); then
    ssh() {
      local -a send=(-o SendEnv=COLORTERM -o SendEnv=TERM_PROGRAM -o SendEnv=TERM_PROGRAM_VERSION)
      if [[ -n "${TERMINFO-}" ]]; then
        TERM=xterm-256color builtin command ssh $send "$@"
      else
        builtin command ssh $send "$@"
      fi
    }
  fi

  # ssh-terminfo and path are accepted and do nothing. Ghostty installs its own terminfo on the
  # remote and puts its own CLI on PATH; a host whose TERM every remote already has
  # (xterm-256color) has no terminfo to install, and this library has no CLI.
}

builtin typeset -ag precmd_functions preexec_functions
precmd_functions+=(__terminal_precmd)
preexec_functions+=(__terminal_preexec)
