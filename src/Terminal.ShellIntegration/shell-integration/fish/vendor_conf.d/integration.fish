# Shell integration for fish: OSC 133 prompt marks and OSC 7 working directory.
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
