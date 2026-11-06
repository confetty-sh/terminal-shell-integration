# Shell integration for fish: OSC 133 prompt marks and OSC 7 working directory, plus the features
# the host turned on in TERMINAL_SHELL_FEATURES (at the end).
#
# Reached by adding this tree to XDG_DATA_DIRS. fish sources vendor_conf.d from every data directory
# on its own, so nothing of the user's is displaced and nothing has to be replayed — which makes
# this the pleasant one of the three.
#
# The mechanism follows Ghostty's, which is MIT licensed.

status is-interactive; or exit 0

# fish 4.0 and later mark the prompt themselves -- A, C carrying the command line, and D -- and
# from 4.3 the prompt's end, B, as well. Marking on top of that gives the terminal every mark
# twice, so whatever fish sends is left to fish. Asked of fish itself rather than read off its
# version: the feature can be switched off (no-mark-prompt), fish 4.8 switches it off for Konsole,
# and fish 3.x does not know it at all -- all three mean this script marks everything, as before.
# Under Konsole that leaves no marks, which is what fish chose there.
set -g __terminal_fish_marks 0
if status test-feature mark-prompt 2>/dev/null
    set __terminal_fish_marks 1
end

# B has no feature of its own to ask about, so it alone goes by version: 4.0 to 4.2 mark the
# prompt but not its end.
set -g __terminal_fish_marks_end 0
if test $__terminal_fish_marks = 1
    # Not $version: fish keeps that name for itself, read-only, and assigning it fails.
    set -l fish_major_minor (string match -r --groups-only '^(\d+)\.(\d+)' -- $FISH_VERSION)
    if test "$fish_major_minor[1]" -gt 4
        or begin; test "$fish_major_minor[1]" -eq 4; and test "$fish_major_minor[2]" -ge 3; end
        set __terminal_fish_marks_end 1
    end
end

# fish gives these as real events, so there is no prompt string to splice and no width to get wrong.

function __terminal_report_cwd --on-variable PWD --description 'report the working directory'
    # $hostname, not (hostname): the variable is built in, while the command forks a process —
    # and this runs on every directory change, in a shell whose whole appeal is being quick.
    # Only the percent needs escaping — see the note in the bash script. string replace is a
    # builtin, so this still forks nothing.
    printf '\033]7;file://%s%s\007' "$hostname" (string replace --all '%' '%25' -- "$PWD")
end

# Runs whoever marks the prompt: the working directory is reported here either way, so a new tab can
# open where this one is from the very first prompt.
function __terminal_prompt_start --on-event fish_prompt --description 'mark the prompt'
    if test $__terminal_fish_marks = 0
        # D carries the status of the command that just finished. Nothing has run before the
        # first prompt, so there is nothing to report then.
        if set -q __terminal_command_running
            printf '\033]133;D;%s\007' $__terminal_last_status
            set -e __terminal_command_running
        end
    end

    __terminal_report_cwd

    if test $__terminal_fish_marks = 0
        printf '\033]133;A\007'
    end
end

if test $__terminal_fish_marks = 0
    function __terminal_preexec --on-event fish_preexec --description 'mark where output begins'
        set -g __terminal_command_running 1
        printf '\033]133;C\007'
    end

    function __terminal_postexec --on-event fish_postexec --description 'remember the exit status'
        set -g __terminal_last_status $status
    end

    # The first prompt has no preceding command, and the report above needs somewhere to read from.
    set -g __terminal_last_status 0
end

# B marks the end of the prompt and the start of typing. Wrapping the user's fish_prompt rather than
# appending to a string, because fish builds its prompt from a function.
if test $__terminal_fish_marks_end = 0; and not functions -q __terminal_original_fish_prompt
    functions -c fish_prompt __terminal_original_fish_prompt

    function fish_prompt --description 'fish_prompt, with the end of it marked'
        __terminal_original_fish_prompt
        printf '\033]133;B\007'
    end
end

# ---- features ---------------------------------------------------------------------------------
#
# The list is Ghostty's shape -- cursor:blink,sudo,title -- so it is split on commas and each entry
# on the colon that carries a setting.
set -g __terminal_features
set -g __terminal_cursor_steady 0
for entry in (string split , -- "$TERMINAL_SHELL_FEATURES")
    set -l name (string split -m 1 : -- $entry)
    set -a __terminal_features $name[1]
    test "$entry" = cursor:steady; and set __terminal_cursor_steady 1
end

# title: fish keeps the window title itself, from fish_title -- the running command, and the
# directory at the prompt, which is the feature already -- so nothing is added here, as Ghostty adds
# nothing. A user who wants another title overrides fish_title, as fish documents.

# cursor: a bar at the prompt (DECSCUSR 5 blinks, 6 is steady), and 0 -- the terminal's default,
# so the user's own -- for each command. Not under fish's vi cursor, which sets the shape for each
# mode itself and would be fought on every prompt.
if contains cursor $__terminal_features
    set -g __terminal_bar 5
    test $__terminal_cursor_steady = 1; and set __terminal_bar 6

    function __terminal_prompt_cursor --on-event fish_prompt --description 'a bar at the prompt'
        functions -q fish_vi_cursor_handle; or printf '\033[%d q' $__terminal_bar
    end

    function __terminal_command_cursor --on-event fish_preexec --description 'the user cursor for commands'
        functions -q fish_vi_cursor_handle; or printf '\033[0 q'
    end
end

# sudo and ssh are wrapped at the first prompt, once config.fish and conf.d have run, so a sudo or
# ssh function of the user's -- an alias is one too -- is known and left alone.
function __terminal_wrap_commands --on-event fish_prompt --description 'wrap sudo and ssh once'
    functions -e __terminal_wrap_commands

    # sudo: keep TERMINFO, which sudo's env_reset drops. Only when there is one -- a host that
    # ships its own terminfo sets it, and a TERM from the system database needs nothing kept.
    # sudoedit (-e, --edit) is left alone, since it never runs a program on this terminal.
    if contains sudo $__terminal_features; and test -n "$TERMINFO"
        and test (type -t sudo 2>/dev/null; or echo none) = file
        function sudo --wraps sudo --description 'sudo, keeping TERMINFO'
            for arg in $argv
                switch $arg
                    case -e --edit
                        command sudo $argv
                        return
                    case '-*' '*=*'
                    case '*'
                        break # the command sudo is to run; what follows is its own
                end
            end
            command sudo --preserve-env=TERMINFO $argv
        end
    end

    # ssh-env: offer the remote what this terminal is. SendEnv adds to whatever the user's
    # ssh_config sends, and the remote takes only what its sshd_config AcceptEnv allows. When TERM
    # comes from a private terminfo (TERMINFO is set) the remote will not have it, so the
    # connection gets xterm-256color instead.
    if contains ssh-env $__terminal_features
        and test (type -t ssh 2>/dev/null; or echo none) = file
        function ssh --wraps ssh --description 'ssh, offering the terminal environment'
            set -l send -o SendEnv=COLORTERM -o SendEnv=TERM_PROGRAM -o SendEnv=TERM_PROGRAM_VERSION
            if test -n "$TERMINFO"
                # Through env, not `TERM=... command ssh`: that sets fish's own TERM and puts it
                # back, and fish answers a change of TERM by drawing the prompt again -- an extra
                # prompt, marks and all, after every ssh.
                command env TERM=xterm-256color ssh $send $argv
            else
                command ssh $send $argv
            end
        end
    end

    # ssh-terminfo and path are accepted and do nothing. Ghostty installs its own terminfo on the
    # remote and puts its own CLI on PATH; a host whose TERM every remote already has
    # (xterm-256color) has no terminfo to install, and this library has no CLI.
end
