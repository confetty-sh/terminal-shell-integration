# Shell integration for bash: OSC 133 prompt marks and OSC 7 working directory.
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
