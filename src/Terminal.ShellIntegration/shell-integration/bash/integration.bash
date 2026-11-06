# Shell integration for bash: OSC 133 prompt marks and OSC 7 working directory, plus the features
# the host turned on in TERMINAL_SHELL_FEATURES (see the end of this file).
#
# Sourced through $ENV with bash started in POSIX mode, because --init-file is silently ignored for
# a login shell and POSIX mode sources $ENV whatever kind of shell it is. The price is here: this
# has to leave POSIX mode and then replay bash's own startup sequence, since bash skipped it.
#
# The mechanism follows Ghostty's. Ghostty is MIT licensed, but its shell scripts are not: they
# derive from Kitty's and are GPLv3, so the approach is borrowed and the code must not be.

# Only when we put it there. Anything else sourcing this is not what it was written for.
if [ -z "${TERMINAL_SHELL_BASH_INJECT+x}" ]; then
  return 0 2>/dev/null || exit 0
fi

__terminal_flags="$TERMINAL_SHELL_BASH_INJECT"
unset TERMINAL_SHELL_BASH_INJECT ENV

# Back to being ordinary bash. inherit_errexit comes with POSIX mode and is not what the user asked
# for either.
builtin set +o posix
builtin shopt -u inherit_errexit 2>/dev/null

# Give back the user's own ENV, which POSIX mode displaced.
if [ -n "${TERMINAL_SHELL_BASH_ENV+x}" ]; then
  ENV="$TERMINAL_SHELL_BASH_ENV"
  builtin export ENV
  unset TERMINAL_SHELL_BASH_ENV
fi

# ---- replay what bash would have read -------------------------------------------------------
#
# bash starts differently depending on whether it is a login shell, and POSIX mode meant it read
# none of it. Getting this wrong loses the user's configuration silently, which is worse than
# having no integration at all.

case " $__terminal_flags " in
  *" login "*) __terminal_login=1 ;;
  *) __terminal_login=0 ;;
esac

case " $__terminal_flags " in
  *" noprofile "*) __terminal_noprofile=1 ;;
  *) __terminal_noprofile=0 ;;
esac

case " $__terminal_flags " in
  *" norc "*) __terminal_norc=1 ;;
  *) __terminal_norc=0 ;;
esac

# A leading dash on the shell's own name is the other way a login shell is spelled.
case "$0" in
  -*) __terminal_login=1 ;;
esac

if [ "$__terminal_login" = 1 ]; then
  if [ "$__terminal_noprofile" != 1 ]; then
    [ -r /etc/profile ] && builtin source /etc/profile

    # The first of these that exists, and only the first — which is bash's own rule.
    for __terminal_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      if [ -r "$__terminal_rc" ]; then
        builtin source "$__terminal_rc"
        break
      fi
    done
  fi
else
  if [ "$__terminal_norc" != 1 ]; then
    # Distributions disagree about where the system one lives.
    for __terminal_rc in /etc/bash.bashrc /etc/bash/bashrc /etc/bashrc; do
      if [ -r "$__terminal_rc" ]; then
        builtin source "$__terminal_rc"
        break
      fi
    done

    [ -r "$HOME/.bashrc" ] && builtin source "$HOME/.bashrc"
  fi
fi

unset __terminal_flags __terminal_login __terminal_noprofile __terminal_norc __terminal_rc

# ---- the integration itself ------------------------------------------------------------------

__terminal_osc() { builtin printf '\033]%s\007' "$1"; }

# Whether the host turned a feature on. The list is Ghostty's shape -- cursor:blink,sudo,title --
# so a name is matched whole, up to its comma or the colon that carries a setting.
__terminal_feature() { [[ ",${TERMINAL_SHELL_FEATURES:-}," == *",$1"[,:]* ]]; }

# The cursor for the prompt (DECSCUSR 5 a blinking bar, 6 a steady one), or empty when the feature
# is off. Each command gets 0, the terminal's own default and so the user's, back.
__terminal_prompt_cursor=
if __terminal_feature cursor; then
  if [[ ",${TERMINAL_SHELL_FEATURES}," == *",cursor:steady,"* ]]; then
    __terminal_prompt_cursor=$'\033[6 q'
  else
    __terminal_prompt_cursor=$'\033[5 q'
  fi
fi

__terminal_title=0
__terminal_feature title && __terminal_title=1

# The working directory as a title, with the home directory spelled ~ -- and only the home
# directory itself or what is under it, so /home/jo is not taken for ~ when HOME is /home/j.
__terminal_report_title() {
  local dir="$PWD"
  if [[ -n "${HOME:-}" && "$HOME" != / ]]; then
    if [[ "$dir" == "$HOME" ]]; then
      dir='~'
    elif [[ "$dir" == "$HOME"/* ]]; then
      dir="~${dir#"$HOME"}"
    fi
  fi
  builtin printf '\033]2;%s\007' "${dir//[[:cntrl:]]/}"
}

# Working directory, so a new tab can open where this one is.
__terminal_report_cwd() {
  # Only the percent needs escaping. The consumer unescapes what arrives, so a directory whose
  # name contains a valid-looking sequence -- a%2Fb -- would come back as a/b, silently wrong.
  # Everything else survives unescaping untouched, so encoding it would be work for nothing.
  builtin printf '\033]7;file://%s%s\007' "${HOSTNAME:-}" "${PWD//%/%25}"
}

# Runs just before each prompt: report the last command's exit status, then mark the new prompt.
__terminal_precmd() {
  local status=$?

  # D carries the status of the command that just finished, and nothing has run before the FIRST
  # prompt. Whether a command has run is tracked here rather than in the preexec above, because this
  # function runs in the shell itself while PS0 runs in a subshell -- a flag set there vanishes, and
  # the only symptom is a missing D.
  if [ -n "${__terminal_prompt_shown:-}" ]; then
    __terminal_osc "133;D;$status"
  fi

  __terminal_prompt_shown=1

  __terminal_report_cwd
  __terminal_osc "133;A"

  [[ -n "$__terminal_prompt_cursor" ]] && builtin printf '%s' "$__terminal_prompt_cursor"
  [[ "$__terminal_title" == 1 ]] && __terminal_report_title

  # Where history stands as the prompt is drawn, so the preexec can tell whether the command it is
  # about to see went into history -- see the title, there.
  __terminal_histcmd="${HISTCMD:-}"

  # In the string form of PROMPT_COMMAND each hook sees the status of the one before it, and this
  # one runs first. Handing the command's status on is what lets the user's own hooks -- a prompt
  # that shows it, a theme -- see their command rather than this function.
  return "$status"
}

# Runs LAST among the prompt hooks, and adds B to the prompt if it is not there. A theme that
# rebuilds PS1 on every prompt (starship, and anything else that assigns it in PROMPT_COMMAND)
# throws away a B appended once at startup. It has to be wrapped in \[ \] or bash counts it toward
# the prompt's width, and then line wrapping and cursor position go subtly wrong in a way that
# looks like a terminal bug.
__terminal_prompt_end() {
  local status=$?
  if [[ "${PS1:-}" != *'133;B'* ]]; then
    PS1="${PS1:-}"'\[\033]133;B\007\]'
  fi
  return "$status"
}

# Runs just before a command executes: the prompt is over and output begins.
#
# Writes to the terminal directly. PS0 reaches this through a command substitution, which runs in a
# SUBSHELL -- so anything printed here would otherwise be captured into PS0's value rather than sent
# to the terminal, and anything assigned here would be lost when the subshell exits. The first is
# survivable by accident, since the captured text is then printed as part of the prompt; the second
# is not, which is why the flag that used to live here now lives in the precmd below.
__terminal_preexec() {
  builtin printf '\033]133;C\007' > /dev/tty
  [[ -n "$__terminal_prompt_cursor" ]] && builtin printf '\033[0 q' > /dev/tty
  [[ "$__terminal_title" == 1 ]] && __terminal_command_title
}

# The command line as the title, while it runs. bash hands PS0 nothing of the command, so it is read
# back from history -- but only when it went there. A command HISTCONTROL left out, or one typed
# with history off, leaves the newest entry the command BEFORE it, which as a title would be
# confidently wrong. History numbers say which: HISTCMD has moved on since the prompt only when this
# command was saved. Unsaved, the directory title stays.
__terminal_command_title() {
  [[ -n "${__terminal_histcmd:-}" && -n "${HISTCMD:-}" ]] || return 0
  (( HISTCMD > __terminal_histcmd )) || return 0

  local last
  last="$(HISTTIMEFORMAT= builtin history 1)"
  # "  42  the command", with a * after the number when the entry was edited.
  [[ "$last" =~ ^[[:space:]]*[0-9]+\*?[[:space:]]+(.*)$ ]] || return 0
  builtin printf '\033]2;%s\007' "${BASH_REMATCH[1]//[[:cntrl:]]/}" > /dev/tty
}

# Added around whatever the user already had, so it all keeps running: the precmd first, so it sees
# the command's status, and the prompt end last, so it sees the user's final PS1. The array form
# (bash 5.1+) gives every element the command's status, so there both simply go on the end.
# Newlines rather than semicolons join the string form: a user's PROMPT_COMMAND ending in ';' would
# make ';;', which is a syntax error on every prompt.
if [[ "${PROMPT_COMMAND[*]:-}" != *__terminal_precmd* ]]; then
  if [[ "$(builtin declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    PROMPT_COMMAND+=(__terminal_precmd __terminal_prompt_end)
  elif [[ -n "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND=__terminal_precmd$'\n'"$PROMPT_COMMAND"$'\n'__terminal_prompt_end
  else
    PROMPT_COMMAND=__terminal_precmd$'\n'__terminal_prompt_end
  fi
fi

# PS0 is expanded after a command is read and before it runs, which is exactly preexec — and unlike
# a DEBUG trap it does not fire for the prompt's own commands, so there is nothing to guard against.
if [[ "${PS0:-}" != *__terminal_preexec* ]]; then
  PS0='$(__terminal_preexec)'"${PS0:-}"
fi

# ---- features that wrap a command ------------------------------------------------------------
#
# Only over a plain command: an alias or function of the user's is theirs, and wrapping it would
# either lose what it does or loop. By now the user's startup files have run, so theirs are known.

__terminal_plain_command() { [[ "$(builtin type -t "$1" 2>/dev/null)" == file ]]; }

# sudo: keep TERMINFO, which sudo's env_reset drops. Only when there is one -- a host that ships its
# own terminfo sets it, and a TERM from the system database needs nothing kept. sudoedit (-e,
# --edit) is left alone, since it never runs a program on this terminal.
if __terminal_feature sudo && [[ -n "${TERMINFO:-}" ]] && __terminal_plain_command sudo; then
  sudo() {
    local arg
    for arg in "$@"; do
      case "$arg" in
        -e|--edit) builtin command sudo "$@"; return ;;
        -*|*=*) ;;
        *) break ;;  # the command sudo is to run; what follows is its own
      esac
    done
    builtin command sudo --preserve-env=TERMINFO "$@"
  }
fi

# ssh-env: offer the remote what this terminal is. SendEnv adds to whatever the user's ssh_config
# sends, and the remote takes only what its sshd_config AcceptEnv allows. When TERM comes from a
# private terminfo (TERMINFO is set), the remote will not have it, so the connection gets
# xterm-256color instead.
if __terminal_feature ssh-env && __terminal_plain_command ssh; then
  ssh() {
    if [[ -n "${TERMINFO:-}" ]]; then
      TERM=xterm-256color builtin command ssh -o SendEnv=COLORTERM -o SendEnv=TERM_PROGRAM \
        -o SendEnv=TERM_PROGRAM_VERSION "$@"
    else
      builtin command ssh -o SendEnv=COLORTERM -o SendEnv=TERM_PROGRAM \
        -o SendEnv=TERM_PROGRAM_VERSION "$@"
    fi
  }
fi

# ssh-terminfo and path are accepted and do nothing. Ghostty installs its own terminfo on the remote
# and puts its own CLI on PATH; a host whose TERM every remote already has (xterm-256color) has no
# terminfo to install, and this library has no CLI.

unset -f __terminal_plain_command
