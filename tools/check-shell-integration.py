#!/usr/bin/env python3
"""Run a real shell with integration injected and report the marks it emitted.

    python3 tools/check-shell-integration.py zsh
    python3 tools/check-shell-integration.py bash /opt/homebrew/bin/bash
    python3 tools/check-shell-integration.py bash
    python3 tools/check-shell-integration.py fish
    python3 tools/check-shell-integration.py pwsh
    python3 tools/check-shell-integration.py zsh --scenario zsh-xdg
    python3 tools/check-shell-integration.py --list

A scenario runs the shell with a throwaway HOME holding a particular user configuration -- the
setups that broke integration once, kept so they cannot quietly break it again. Without one, the
shell reads the real HOME, which is what a user gets but not something CI can reproduce.

Build the library first, so the scripts are in its output directory:

    dotnet build src/Terminal.ShellIntegration -c Release

Why this exists rather than another unit test. The C# side is pure and covered by tests that assert
arguments and environment without spawning anything. What those cannot see is whether the SCRIPTS
work, and the two real bugs found while writing them were both invisible to everything else:

  * zsh: `local status=$?` silently breaks a function, because `status` is a special parameter in
    zsh aliased to `$?`. The prompt still drew, and only the A and D marks went missing.
  * bash: macOS ships 3.2 from 2007, which does not source $ENV in POSIX mode at all. No error, no
    marks — the same symptom as a script that was never written.

A shell that emits nothing looks exactly like a shell that was never instrumented, so this prints
what arrived rather than passing or failing.

The feature scenarios (cursor, title, sudo, ssh-env) never run the real sudo or ssh: they put
shims of those names first on PATH, which print what they were given and exit. A scenario that
needs a TERM from a private terminfo -- the case sudo and ssh-env exist for -- compiles one from
xterm-256color into its throwaway HOME, named xterm-harness.
"""
import os
import re
import shutil
import sys
import tempfile
import time

# Each scenario: the shell it is for, the files to write under a throwaway HOME, any extra
# arguments, and text the run's output must contain. An optional fifth element holds "env",
# variables to set for the shell, and "absent", text the output must NOT contain; both may name
# {HOME}. A user hook that prints "hook-saw:$?" is checked for seeing the status of the user's
# COMMAND, which is what integration must not disturb.
#
# Every zsh run also types a probe at the live prompt, so the zsh scenarios check the session's
# final environment -- "probe zdotdir=..." names what ZDOTDIR ended up as.
_ZSH_THEME = """autoload -Uz add-zsh-hook
__user_status() { print -r -- "hook-saw:$?"; return 7; }
__user_prompt() { PS1="rebuilt %# "; }
add-zsh-hook precmd __user_status
add-zsh-hook precmd __user_prompt
"""
SCENARIOS = {
    # Default place, non-login: .zprofile and .zlogin are there and must not run.
    "zsh-plain": ("zsh", {
        ".zshenv": 'print -r -- "user-zshenv-ran"\n',
        ".zprofile": 'print -r -- "user-zprofile-ran"\n',
        ".zshrc": 'print -r -- "user-zshrc-ran"\n',
        ".zlogin": 'print -r -- "user-zlogin-ran"\n',
    }, [], ["user-zshenv-ran", "user-zshrc-ran", "probe zdotdir=unset"],
       {"absent": ["user-zprofile-ran", "user-zlogin-ran"]}),
    # The four files, each reporting that it ran, in their default place.
    "zsh-login": ("zsh", {
        ".zshenv": 'print -r -- "user-zshenv-ran"\n',
        ".zprofile": 'print -r -- "user-zprofile-ran zdotdir=${ZDOTDIR-unset}"\n',
        ".zshrc": 'print -r -- "user-zshrc-ran"\n',
        ".zlogin": 'print -r -- "user-zlogin-ran"\n',
    }, ["-l"], ["user-zshenv-ran", "user-zprofile-ran zdotdir=unset", "user-zshrc-ran",
                "user-zlogin-ran", "probe zdotdir=unset"]),
    # No .zshenv at all, which is not an error.
    "zsh-no-zshenv": ("zsh", {
        ".zshrc": 'print -r -- "user-zshrc-ran"\n',
    }, [], ["user-zshrc-ran", "probe zdotdir=unset"]),
    # ZDOTDIR already set in the environment the terminal was started from, so the host hands it
    # over; the files in HOME are decoys that must not run.
    "zsh-env-zdotdir": ("zsh", {
        "zdot/.zshenv": 'print -r -- "user-zshenv-ran zdotdir=$ZDOTDIR"\n',
        "zdot/.zshrc": 'print -r -- "user-zshrc-ran"\n',
        ".zshenv": 'print -r -- "home-zshenv-ran"\n',
        ".zshrc": 'print -r -- "home-zshrc-ran"\n',
    }, [], ["user-zshenv-ran zdotdir={HOME}/zdot", "user-zshrc-ran", "probe zdotdir={HOME}/zdot"],
       {"env": {"ZDOTDIR": "{HOME}/zdot"}, "absent": ["home-zshenv-ran", "home-zshrc-ran"]}),
    "zsh-env-zdotdir-login": ("zsh", {
        "zdot/.zshenv": 'print -r -- "user-zshenv-ran"\n',
        "zdot/.zprofile": 'print -r -- "user-zprofile-ran zdotdir=$ZDOTDIR"\n',
        "zdot/.zshrc": 'print -r -- "user-zshrc-ran"\n',
        "zdot/.zlogin": 'print -r -- "user-zlogin-ran"\n',
    }, ["-l"], ["user-zshenv-ran", "user-zprofile-ran zdotdir={HOME}/zdot", "user-zshrc-ran",
                "user-zlogin-ran", "probe zdotdir={HOME}/zdot"],
       {"env": {"ZDOTDIR": "{HOME}/zdot"}}),
    # XDG-style: .zshenv moves ZDOTDIR, and zsh reads the rest from there.
    "zsh-xdg": ("zsh", {
        ".zshenv": 'export ZDOTDIR="$HOME/.config/zsh"\n',
        ".config/zsh/.zshrc": 'print -r -- "user-zshrc-ran zdotdir=$ZDOTDIR"\n',
        ".zshrc": 'print -r -- "home-zshrc-ran"\n',
    }, [], ["user-zshrc-ran zdotdir=" + "{HOME}/.config/zsh", "probe zdotdir={HOME}/.config/zsh"],
       {"absent": ["home-zshrc-ran"]}),
    "zsh-xdg-login": ("zsh", {
        ".zshenv": 'export ZDOTDIR="$HOME/.config/zsh"\n',
        ".config/zsh/.zprofile": 'print -r -- "user-zprofile-ran zdotdir=$ZDOTDIR"\n',
        ".config/zsh/.zshrc": 'print -r -- "user-zshrc-ran"\n',
        ".config/zsh/.zlogin": 'print -r -- "user-zlogin-ran"\n',
        ".zprofile": 'print -r -- "home-zprofile-ran"\n',
    }, ["-l"], ["user-zprofile-ran zdotdir={HOME}/.config/zsh", "user-zshrc-ran",
                "user-zlogin-ran", "probe zdotdir={HOME}/.config/zsh"],
       {"absent": ["home-zprofile-ran"]}),
    # The same, spelled as a default -- which only works if ZDOTDIR arrives unset.
    "zsh-xdg-default": ("zsh", {
        ".zshenv": 'export ZDOTDIR="${ZDOTDIR:-$HOME/.config/zsh}"\n',
        ".config/zsh/.zshrc": 'print -r -- "user-zshrc-ran zdotdir=$ZDOTDIR"\n',
    }, [], ["user-zshrc-ran zdotdir=" + "{HOME}/.config/zsh", "probe zdotdir={HOME}/.config/zsh"]),
    # A theme that rebuilds PS1 on every prompt (powerlevel10k, starship), and a user precmd
    # hook that reports $? and then returns something else -- 7, so a status that is right by
    # coincidence of being 0 cannot pass.
    "zsh-rebuild-ps1": ("zsh", {
        ".zshrc": 'print -r -- "user-zshrc-ran"\n' + _ZSH_THEME,
    }, [], ["user-zshrc-ran", "hook-saw:0", "hook-saw:1", "probe zdotdir=unset"]),
    # The same theme under the XDG layout, in a login shell.
    "zsh-rebuild-ps1-xdg-login": ("zsh", {
        ".zshenv": 'export ZDOTDIR="${ZDOTDIR:-$HOME/.config/zsh}"\n',
        ".config/zsh/.zshrc": 'print -r -- "user-zshrc-ran"\n' + _ZSH_THEME,
    }, ["-l"], ["user-zshrc-ran", "hook-saw:0", "hook-saw:1", "probe zdotdir={HOME}/.config/zsh"]),
    # bash 5.1+ array PROMPT_COMMAND, with a user hook that returns 0 whatever happened.
    "bash-array-pc": ("bash", {
        ".bashrc": """__user_hook() { echo "hook-saw:$?"; return 7; }
PROMPT_COMMAND=(__user_hook)
""",
    }, [], ["hook-saw:0", "hook-saw:1"]),
    # The string form of the same, ending in the ';' that a careless join turns into ';;'.
    "bash-string-pc": ("bash", {
        ".bashrc": """__user_hook() { echo "hook-saw:$?"; return 7; }
PROMPT_COMMAND='__user_hook;'
""",
    }, [], ["hook-saw:0", "hook-saw:1"]),
    # A theme that rebuilds PS1 on every prompt, the way starship's bash hook does.
    "bash-rebuild-ps1": ("bash", {
        ".bashrc": """__user_prompt() { PS1='rebuilt\\$ '; }
PROMPT_COMMAND='__user_prompt'
""",
    }, [], []),
    "bash-rebuild-ps1-array": ("bash", {
        ".bashrc": """__user_prompt() { PS1='rebuilt\\$ '; }
PROMPT_COMMAND=(__user_prompt)
""",
    }, [], []),
    # PowerShell scenarios run with -NoProfile, and "profile.ps1" is dot-sourced in the -Command
    # before the integration -- which is what pwsh does with a real profile, and the only way to
    # give it a throwaway one on Windows, where the profile lives under Documents and no
    # environment variable moves it.
    "pwsh-plain": ("pwsh", {}, [], []),
    # Native exit codes, a failing cmdlet after a failing native command -- $LASTEXITCODE is still
    # 3 then, and is not the cmdlet's status -- an exception, and the same native code twice.
    "pwsh-statuses": ("pwsh", {}, [], [], {"commands": [
        ("{native-exit 3}", "3"),
        ("Get-Item /no/such/path-check-shell-integration", "1"),
        ("$null = 1", "0"),
        ("throw 'boom'", "1"),
        ("{native-exit 3}", "3"),
        ("{native-exit 3}", "3"),
        ("Write-Error 'oops'", "1"),
    ]}),
    # A prompt drawn with Write-Host, as posh-git and many hand-written prompts do, that also
    # reads $? -- as starship and oh-my-posh do, to colour the prompt after a failure. Write-Host
    # output goes out while the prompt function runs, before the string it returns, so it must
    # still land between A and B; and $? must be the user's command's, not the integration's.
    "pwsh-write-host-prompt": ("pwsh", {
        "profile.ps1": """function prompt {
    $ok = $?
    Write-Host -NoNewline "hook-saw:$(if ($ok) { 0 } else { 1 }) "
    Write-Host -NoNewline 'user-prompt'
    return '> '
}
""",
    }, [], ["user-prompt"], {"commands": [
        ("echo hello", "0"),
        ("Get-Item /no/such/path-check-shell-integration", "1"),
    ], "between_ab": ["user-prompt"]}),
    # A prompt that returns its whole text, reading $? and $LASTEXITCODE the way starship's does.
    "pwsh-return-prompt": ("pwsh", {
        "profile.ps1": """function prompt {
    $ok = $global:?
    $code = $global:LASTEXITCODE
    "hook-saw:$(if ($ok) { 0 } else { 1 }) lec=$code user-prompt> "
}
""",
    }, [], ["user-prompt", "lec=3"], {"commands": [
        ("echo hello", "0"),
        ("{native-exit 3}", "3"),
    ], "hooks": ["0", "1"], "between_ab": ["user-prompt"]}),
    # PSReadLine imported and configured by the profile, so it is already loaded when the
    # integration runs rather than arriving after it.
    "pwsh-psreadline-profile": ("pwsh", {
        "profile.ps1": """Import-Module PSReadLine
Set-PSReadLineOption -ContinuationPrompt '>>> '
Set-PSReadLineKeyHandler -Chord Ctrl+g -Function AcceptLine
""",
    }, [], []),
    # Input over several lines: PSReadLine takes Enter on an unfinished statement as a newline
    # and draws the continuation prompt, so this is one command, one C and one D.
    "pwsh-multiline": ("pwsh", {}, [], ["multi-ran"], {"commands": [
        ("if ($true) {\r'multi-' + 'ran'\r}", "0"),
        ("echo hello", "0"),
    ]}),
    # A location outside the filesystem has no directory to report. The last filesystem one is
    # still where a new tab should open.
    "pwsh-provider": ("pwsh", {}, [], [], {"commands": [
        ("Set-Location Env:", "0"),
        ("Set-Location Function:", "0"),
    ], "absent_re": [r"\x1b\]7;file://[^/\x07\x1b]*(?:\x07|\x1b\\)",
                     r"\x1b\]9;9;\"?(?:Env|Function|HKEY)[^\x07]*\x07",
                     r"\x1b\]9;9;\"\"\x07"]}),
    # A prompt that throws still gets marked, and the terminal still gets a prompt.
    "pwsh-throwing-prompt": ("pwsh", {
        "profile.ps1": "function prompt { throw 'prompt is broken' }\n",
    }, [], []),
}

# ---- the features, the same cases for every shell -------------------------------------------
#
# Extras the feature scenarios use, on top of those above: "features" is TERMINAL_SHELL_FEATURES
# (absent when not given, so every scenario above runs with none); "shims" names the commands to
# shadow on PATH; "required_count" is patterns to find a set number of times, or once for each of
# the "prompts" or "commands" the run judged; "terminfo" compiles xterm-harness into {HOME}/terminfo and sets TERMINFO there;
# "required_re" is patterns the output must match; "windows" replaces any of these on Windows.
#
# A shim prints "shim-<name> term=... colorterm=... argv=..." and exits with $SHIM_EXIT, 0 unless
# the scenario sets it. The commands typed never contain
# "shim-" or "argv=", so what is checked can only have come from the shim itself.

# What each shell calls its own startup file, and how it defines a function that shadows a command
# -- which a wrapper must leave alone.
_RC = {"bash": ".bashrc", "zsh": ".zshrc", "fish": ".config/fish/config.fish", "pwsh": "profile.ps1"}


def _user_function(shell, name):
    # An alias where the shell has them, because that is what tells WHEN a wrapper was defined: a
    # user function defined later replaces an early wrapper anyway, but an alias expands into it,
    # and the wrapper runs under the user's own name. fish's aliases are functions.
    if shell in ("bash", "zsh"):
        return f"alias {name}='{name} --user-{name}'\n"
    if shell == "fish":
        return f"function {name}; echo user-{name}-ran; end\n"
    if shell == "pwsh":
        return f"function {name} {{ 'user-{name}-ran' }}\n"
    return f"{name}() {{ echo user-{name}-ran; }}\n"


def _user_ran(shell, name, rest):
    """What shows that the user's own sudo or ssh ran, and not a wrapper."""
    return f"argv=--user-{name} {rest}" if shell in ("bash", "zsh") else f"user-{name}-ran"


_SEND = "-o SendEnv=COLORTERM -o SendEnv=TERM_PROGRAM -o SendEnv=TERM_PROGRAM_VERSION"
_CURSORS = [r"\x1b\[[0-6] q"]


def _term_after(shell):
    return 'echo "term-after=$env:TERM"' if shell == "pwsh" else 'echo "term-after=$TERM"'


def _feature_scenarios(shell):
    sudo = "sudo -u root true"
    out = {
        # A bar at every prompt and the user's cursor back for every command. Counted, not just
        # found, so a bar that only went out once would not pass.
        f"{shell}-cursor": (shell, {}, [], [], {
            "features": "cursor:blink", "required_count": {r"\x1b\[5 q": "prompts", r"\x1b\[0 q": "commands"},
            "absent_re": [r"\x1b\[6 q"]}),
        f"{shell}-cursor-steady": (shell, {}, [], [], {
            "features": "cursor:steady", "required_count": {r"\x1b\[6 q": "prompts", r"\x1b\[0 q": "commands"},
            "absent_re": [r"\x1b\[5 q"]}),
        # Everything off. Nothing the features add may appear; fish keeps its own title.
        f"{shell}-features-off": (shell, {}, [], [], {
            "absent_re": _CURSORS + ([] if shell == "fish" else [r"\x1b\]2;"])}),
        f"{shell}-title": (shell, {}, [], [], {
            "features": "title", "commands": [("cd ~", "0"), ("echo title-probe", "0")],
            "required_re": [r"\x1b\]2;~\x07", r"\x1b\]2;echo title-probe\x07"],
            "absent_re": _CURSORS}),
        # sudo keeps TERMINFO, except for sudoedit; an -e after the command is the command's own.
        f"{shell}-sudo": (shell, {}, [], [
            "argv=--preserve-env=TERMINFO -u root true", "argv=-e /etc/hosts",
            "argv=--preserve-env=TERMINFO ls -e"], {
            "features": "sudo", "terminfo": True, "shims": ["sudo"],
            "commands": [(sudo, "0"), ("sudo -e /etc/hosts", "0"), ("sudo ls -e", "0")],
            "windows": {"required": ["argv=-u root true", "argv=-e /etc/hosts", "argv=ls -e"],
                        "absent": ["--preserve-env"]}}),
        # Without a TERMINFO there is nothing to keep, and with the feature off nothing is wrapped.
        f"{shell}-sudo-no-terminfo": (shell, {}, [], ["argv=-u root true"], {
            "features": "sudo", "shims": ["sudo"], "commands": [(sudo, "0")],
            "absent": ["--preserve-env"]}),
        f"{shell}-sudo-off": (shell, {}, [], ["argv=-u root true"], {
            "features": "cursor:blink,title", "terminfo": True, "shims": ["sudo"],
            "commands": [(sudo, "0")], "absent": ["--preserve-env"]}),
        # A sudo of the user's own is theirs. In zsh and fish it is defined after the integration
        # loads, which is what deferring the wrappers to the first prompt is for. The shim's argv
        # must not gain --preserve-env through the user's alias either.
        f"{shell}-sudo-user": (shell, {_RC[shell]: _user_function(shell, "sudo")}, [],
                               [_user_ran(shell, "sudo", "-u root true")], {
            "features": "sudo", "terminfo": True, "shims": ["sudo"], "commands": [(sudo, "0")],
            "absent": ["--preserve-env"]}),
        f"{shell}-ssh-env": (shell, {}, [], [
            f"shim-ssh term=xterm-256color colorterm=truecolor argv={_SEND} example.invalid"], {
            "features": "ssh-env", "shims": ["ssh"], "env": {"COLORTERM": "truecolor"},
            "commands": [("ssh example.invalid", "0")]}),
        # A TERM from a private terminfo is xterm-256color for the connection, and only for it.
        f"{shell}-ssh-env-terminfo": (shell, {}, [], [
            f"shim-ssh term=xterm-256color colorterm=truecolor argv={_SEND} example.invalid",
            "term-after=xterm-harness"], {
            "features": "ssh-env", "terminfo": True, "shims": ["ssh"],
            "env": {"COLORTERM": "truecolor", "TERM": "xterm-harness"},
            "commands": [("ssh example.invalid", "0"), (_term_after(shell), "0")]}),
        # What ssh exits with is what the command reports, wrapper or not.
        f"{shell}-ssh-env-status": (shell, {}, [], [f"argv={_SEND} example.invalid"], {
            "features": "ssh-env", "shims": ["ssh"], "env": {"SHIM_EXIT": "255"},
            "commands": [("ssh example.invalid", "255"), ("ssh example.invalid", "255")]}),
        # ssh-env is off by default, as in Ghostty: the defaults leave ssh alone.
        f"{shell}-ssh-off": (shell, {}, [], ["argv=example.invalid"], {
            "features": "cursor:blink,path,title", "shims": ["ssh"],
            "commands": [("ssh example.invalid", "0")], "absent": ["SendEnv"]}),
        f"{shell}-ssh-user": (shell, {_RC[shell]: _user_function(shell, "ssh")}, [],
                              [_user_ran(shell, "ssh", "example.invalid")], {
            "features": "ssh-env", "shims": ["ssh"], "commands": [("ssh example.invalid", "0")],
            "absent": ["SendEnv"]}),
    }
    if shell == "bash":
        # bash reads the title's command back from history, which HISTCONTROL can keep it out of.
        # Then the newest entry is the command before, and it must not become the title.
        out["bash-title-ignorespace"] = ("bash", {".bashrc": "HISTCONTROL=ignorespace\n"}, [], [], {
            "features": "title", "commands": [("echo seen", "0"), (" echo unseen", "0")],
            "required_count": {r"\x1b\]2;echo seen\x07": 1},
            "absent_re": [r"\x1b\]2; ?echo unseen"]})
    if shell == "zsh":
        # vi command mode gets a block, insert mode the bar again. ESC leaves insert mode, and the
        # pause keeps the Enter after it from arriving as one Alt+Enter keystroke.
        out["zsh-cursor-vi"] = ("zsh", {".zshrc": "bindkey -v\nKEYTIMEOUT=1\n"}, [], [], {
            "features": "cursor:blink", "commands": [("echo vi-ran\x1b{pause}", "0")],
            "required": ["vi-ran"], "required_re": [r"\x1b\[1 q", r"\x1b\[5 q"]})
    if shell == "fish":
        # fish sets the title itself, so with the feature on or off it is fish's.
        out["fish-title"] = ("fish", {}, [], [], {
            "features": "title", "commands": [("cd ~", "0"), ("echo title-probe", "0")],
            "required_re": [r"\x1b\][02];[^\x07]*title-probe"]})
    return out


for _shell in ("bash", "zsh", "fish", "pwsh"):
    SCENARIOS.update(_feature_scenarios(_shell))

args = sys.argv[1:]
SCENARIO = None
if "--list" in args:
    for name, spec in SCENARIOS.items():
        print(f"{name:26} {spec[0]}")
    sys.exit(0)
if "--scenario" in args:
    i = args.index("--scenario")
    SCENARIO = args[i + 1]
    del args[i:i + 2]
    if SCENARIO not in SCENARIOS:
        sys.exit(f"unknown scenario {SCENARIO}; --list shows them")

SHELL = args[0] if args else (SCENARIOS[SCENARIO][0] if SCENARIO else "zsh")

# An explicit binary, for testing a shell the system does not ship as its default —
# macOS bash is 3.2 from 2007, so a modern one has to be named. Windows PowerShell 5.1 is the
# pwsh scripts run by another binary: `pwsh powershell`.
BINARY = args[1] if len(args) > 1 else SHELL

if SCENARIO and SCENARIOS[SCENARIO][0] != SHELL:
    sys.exit(f"scenario {SCENARIO} is for {SCENARIOS[SCENARIO][0]}, not {SHELL}")

WINDOWS = os.name == "nt"
if WINDOWS and SHELL != "pwsh":
    sys.exit(f"{SHELL} is not run on Windows; only pwsh is")

here = os.path.dirname(os.path.abspath(__file__))
resources = os.path.join(
    here, "..", "src", "Terminal.ShellIntegration", "bin", "Release", "net10.0", "shell-integration"
)
resources = os.path.normpath(resources)

if not os.path.isdir(resources):
    sys.exit(f"scripts not found at {resources}\nbuild first: dotnet build src/Terminal.ShellIntegration -c Release")

env = dict(os.environ)
env["TERMINAL_SHELL_RESOURCES"] = resources
env["PS1"] = "$ "
env["TERMINAL_SHELL_INTEGRATION"] = "1"

# A terminal always says what it is, and this one answers queries as an xterm would. Inheriting TERM
# instead made the run depend on where it ran: CI runners set none, and zsh with no usable TERM
# never runs zle-line-init -- a difference no user of a real terminal ever sees, reported as a
# failure that would not reproduce at a desk.
env["TERM"] = "xterm-256color"

home = None
required = []
absent = []
absent_re = []
between_ab = []
extra_args = []
extras = {}
files = {}
# Nothing turns a feature on that the scenario did not, nor gives it a terminfo it did not ask for.
env.pop("TERMINAL_SHELL_FEATURES", None)
env.pop("TERMINFO", None)
required_re = []
required_count = {}
if SCENARIO:
    _, files, extra_args, required = SCENARIOS[SCENARIO][:4]
    extras = dict(SCENARIOS[SCENARIO][4]) if len(SCENARIOS[SCENARIO]) > 4 else {}
    if WINDOWS and "windows" in extras:
        overrides = extras.pop("windows")
        required = overrides.pop("required", required)
        extras.update(overrides)
    home = tempfile.mkdtemp(prefix="shell-integration-home-")
    for rel, content in files.items():
        path = os.path.join(home, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
    env["HOME"] = home
    env.pop("ZDOTDIR", None)
    # Where pwsh on Unix keeps PSReadLine's history, so a run never writes to the real one.
    env.pop("XDG_DATA_HOME", None)
    env.pop("XDG_CONFIG_HOME", None)
    for name, value in extras.get("env", {}).items():
        env[name] = value.replace("{HOME}", home)
    if "features" in extras:
        env["TERMINAL_SHELL_FEATURES"] = extras["features"]
    if extras.get("shims"):
        shims = os.path.join(home, "shims")
        os.makedirs(shims)
        for name in extras["shims"]:
            if WINDOWS:
                with open(os.path.join(shims, name + ".cmd"), "w") as f:
                    f.write(f"@echo shim-{name} term=%TERM% colorterm=%COLORTERM% argv=%*\n"
                            "@exit /b %SHIM_EXIT%\n")
            else:
                path = os.path.join(shims, name)
                with open(path, "w") as f:
                    f.write("#!/bin/sh\n"
                            f"printf 'shim-{name} term=%s colorterm=%s argv=%s\\n'"
                            ' "${TERM-unset}" "${COLORTERM-unset}" "$*"\n'
                            'exit "${SHIM_EXIT:-0}"\n')
                os.chmod(path, 0o755)
        env["PATH"] = shims + os.pathsep + env.get("PATH", "")
        env.setdefault("SHIM_EXIT", "0")
    if extras.get("terminfo"):
        # A TERM only this directory knows, as a host shipping its own terminfo would give.
        terminfo = os.path.join(home, "terminfo")
        os.makedirs(terminfo)
        if not WINDOWS:
            import subprocess
            source = subprocess.run(["infocmp", "-x", "xterm-256color"], check=True,
                                    capture_output=True, text=True).stdout
            source = re.sub(r"^xterm-256color\|", "xterm-harness|xterm-256color|", source, flags=re.M)
            with open(os.path.join(home, "harness.terminfo"), "w") as f:
                f.write(source)
            subprocess.run(["tic", "-x", "-o", terminfo, os.path.join(home, "harness.terminfo")], check=True)
        env["TERMINFO"] = terminfo
    required_re = extras.get("required_re", [])
    required_count = extras.get("required_count", {})
    required = required + extras.get("required", [])
    required = [r.replace("{HOME}", home) for r in required]
    absent = [a.replace("{HOME}", home) for a in extras.get("absent", [])]
    absent_re = extras.get("absent_re", [])
    between_ab = extras.get("between_ab", [])


def native_exit(code):
    """A NATIVE command that exits with `code`, which is what $LASTEXITCODE reports."""
    return f"cmd /c exit {code}" if WINDOWS else f"sh -c 'exit {code}'"


# The commands typed, each with the status its D must carry. Two with different statuses by
# default, so D can be checked for carrying the right one. Windows has no `false`.
if "commands" in extras:
    COMMANDS = [(re.sub(r"\{native-exit (\d+)\}", lambda m: native_exit(m.group(1)), text), status)
                for text, status in extras["commands"]]
else:
    COMMANDS = [("echo hello", "0"), (native_exit(1) if WINDOWS else "false", "1")]

if SHELL == "bash":
    env["TERMINAL_SHELL_BASH_INJECT"] = "login" if "-l" in extra_args else ""
    env["ENV"] = os.path.join(resources, "bash", "integration.bash")
    argv = [BINARY, "--posix", "-i"] + extra_args
elif SHELL == "zsh":
    # As Prepare does: the user's own ZDOTDIR is handed over only when there is one.
    if env.get("ZDOTDIR"):
        env["TERMINAL_SHELL_ZDOTDIR"] = env["ZDOTDIR"]
    env["ZDOTDIR"] = os.path.join(resources, "zsh")
    argv = [BINARY, "-i"] + extra_args
elif SHELL == "fish":
    # The parent of fish/, because fish searches each data directory for fish/vendor_conf.d.
    existing = env.get("XDG_DATA_DIRS", "")
    env["XDG_DATA_DIRS"] = resources + (os.pathsep + existing if existing else "")
    argv = [BINARY, "-i"]
elif SHELL == "pwsh":
    # -Command runs after the profiles, so the script wraps whatever prompt they installed.
    # -NoLogo keeps the banner out of the capture; -NoExit is what makes it interactive after.
    script = os.path.join(resources, "pwsh", "integration.ps1")
    command = f". '{script}'"
    profile_args = []
    if SCENARIO:
        # A scenario never reads a real profile. Its own, if it has one, is dot-sourced first in
        # the same -Command: the same scope and the same order as pwsh gives a profile.
        profile_args = ["-NoProfile"]
        if "profile.ps1" in files:
            command = f". '{os.path.join(home, 'profile.ps1')}'; " + command
    argv = [BINARY, "-NoLogo"] + profile_args + ["-NoExit", "-Command", command]
else:
    sys.exit(f"unknown shell {SHELL}")


class UnixPty:
    """The shell on a pty, which is what a terminal gives it."""

    def __init__(self, argv, env):
        import fcntl, pty, struct, termios
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe(argv[0], argv, env)
        # A real terminal always tells the pty its size; a 0x0 window makes some line editors
        # refuse to initialise, and PSReadLine is one of them.
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    def read(self, timeout):
        """Bytes if any arrived within `timeout`, b"" if none did, None once the shell is gone."""
        import select
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return b""
        try:
            chunk = os.read(self.fd, 65536)
        except OSError:
            return None
        return chunk or None

    def write(self, data):
        os.write(self.fd, data)


class WindowsPty:
    """The shell on a ConPTY, through pywinpty (pip install pywinpty).

    pywinpty carries its own conpty.dll and OpenConsole.exe -- the console host Windows Terminal
    ships -- rather than the one in the system, so this is the console a terminal bundling
    OpenConsole sees. The text comes back already decoded, and goes out as text.
    """

    def __init__(self, argv, env):
        from winpty import PTY
        program = shutil.which(argv[0], path=env.get("PATH"))
        if not program:
            sys.exit(f"{argv[0]} not found on PATH")
        import subprocess
        self.pty = PTY(120, 40)
        block = "\0".join(f"{k}={v}" for k, v in env.items()) + "\0"
        self.pty.spawn(program, cmdline=" " + subprocess.list2cmdline(argv[1:]), env=block)

    def read(self, timeout):
        text = self.pty.read(blocking=False)
        if text:
            return text.encode("utf-8")
        if not self.pty.isalive():
            return None
        time.sleep(timeout)
        return b""

    def write(self, data):
        self.pty.write(data.decode("utf-8"))


# On Windows PSReadLine keeps its history under %APPDATA%, which no variable moves, so a run
# would add its commands to the real one. It is put back as it was afterwards.
history_file = None
history_before = None
if WINDOWS:
    history_file = os.path.join(os.environ.get("APPDATA", ""), "Microsoft", "Windows", "PowerShell",
                                "PSReadLine", "ConsoleHost_history.txt")
    if os.path.exists(history_file):
        with open(history_file, "rb") as f:
            history_before = f.read()

shell = WindowsPty(argv, env) if WINDOWS else UnixPty(argv, env)

# Modern shells interrogate the terminal before drawing anything — fish asks for the kitty keyboard
# flags, the terminal version, the background colour, terminfo capabilities and the device
# attributes — and then WAITS. A harness that stays silent leaves it blocked before its first prompt,
# which looks identical to integration that never loaded. So this answers, minimally but plausibly.
QUERIES = [
    # Answer each query ONCE. PowerShell's console asks where the cursor is (DSR 6, below) on
    # every prompt, and .NET consumes exactly one reply; a second one arrives when nobody is
    # waiting and PSReadLine reads it as keystrokes -- "1;1R" typed in front of every command, so
    # every command is a parse error and even `exit` fails. That was a duplicated entry in this
    # list, and it cost an afternoon, because the symptom looks like the shell being broken.
    (re.compile(rb"\x1b\[\?u"), b"\x1b[?0u"),                              # kitty keyboard flags
    (re.compile(rb"\x1b\[>0?q"), b"\x1bP>|check-shell-integration\x1b\\"),  # XTVERSION
    (re.compile(rb"\x1b\]11;\?(?:\x07|\x1b\\)"),
     b"\x1b]11;rgb:0000/0000/0000\x1b\\"),                                  # background colour
    (re.compile(rb"\x1bP\+q[0-9a-fA-F]+(?:;[0-9a-fA-F]+)*\x1b\\"),
     b"\x1bP0+q\x1b\\"),                                                   # XTGETTCAP: not supported
    (re.compile(rb"\x1b\[c|\x1b\[0c"), b"\x1b[?6c"),                        # primary device attributes
    (re.compile(rb"\x1b\[5n"), b"\x1b[0n"),                                 # device status
    (re.compile(rb"\x1b\[6n"), b"\x1b[1;1R"),                               # cursor position
]


def pump(seconds, sink):
    """Read for a while, answering anything the shell asks."""
    end = time.time() + seconds
    while time.time() < end:
        # A real terminal answers a query in well under a millisecond. .NET's console reads the
        # reply to its cursor query with a short window, and a reply arriving after it lands in
        # the INPUT buffer as keystrokes -- "1;1R" typed into the command line. So the loop spins
        # tight rather than sleeping.
        chunk = shell.read(0.005)
        if chunk is None:
            return False
        if not chunk:
            continue

        sink.append(chunk)
        for pattern, reply in QUERIES:
            if pattern.search(chunk):
                shell.write(reply)
    return True


chunks = []

PROMPT_START = re.compile(rb"\x1b\]133;A")
PROMPT_END = re.compile(rb"\x1b\]133;B")


def count(pattern, sink):
    # Joined, not per chunk: a mark split across two reads is still one mark.
    return len(pattern.findall(b"".join(sink)))


def pump_until_prompt(seconds, sink, prompts_seen):
    """Pump until one more prompt has started (OSC 133;A) and, briefly, for its B."""
    end = time.time() + seconds
    while time.time() < end:
        if not pump(0.05, sink):
            return prompts_seen
        seen = count(PROMPT_START, sink)
        if seen > prompts_seen:
            # Paced on A rather than B, because a missing B is one of the things this checks for
            # and waiting on it would turn that finding into a ten-second stall.
            settle = time.time() + 1.0
            while time.time() < settle and count(PROMPT_END, sink) < seen:
                if not pump(0.05, sink):
                    break
            return seen
    return prompts_seen


try:
    # Type only once the shell is at a prompt. A fixed startup wait typed the first command into a
    # cold pwsh before PSReadLine was reading -- the first prompt drew and nothing ran after it,
    # which is exactly what a broken script looks like. Pacing on the prompt marks instead is both
    # robust on a slow machine and quick on a fast one; the ceiling is for a shell that never gets there.
    seen = pump_until_prompt(30.0, chunks, 0)
    pump(0.3, chunks)   # let the line editor finish initialising behind the prompt

    # CR, not LF: Enter is 0x0D on the wire. The line discipline maps it for bash, zsh and fish, but
    # PSReadLine puts the tty in raw mode and reads keys itself, and LF is Ctrl+J to it -- three
    # commands sent with LF became one line that never ran.
    # A shell that never reached a first prompt will not reach the next ones either.
    ceiling = 10.0 if seen else 1.0

    # zsh: what the user's session ends up with. The handed-over ZDOTDIR must be gone from the shell
    # and from what its children inherit. Written so the command as typed -- which the terminal
    # echoes -- never contains the text checked for, only its output does. First, so the two
    # commands below are still the last two the user hooks see.
    probe = SHELL == "zsh"
    if probe:
        shell.write(b"print -r -- \"probe zdotdir=${ZDOTDIR-unset} helper=${TERMINAL_SHELL_ZDOTDIR-gone}"
                    b" child=$(env | grep -c '^TERMINAL_SHELL_ZDOTDIR=')\"\r")
        seen = pump_until_prompt(ceiling, chunks, seen)
        required.append("helper=gone child=0")

    for text, _ in COMMANDS:
        # A command over several lines is typed a line at a time, as a person would, so the line
        # editor sees each Enter on its own.
        # {pause} splits a write, for a key that must arrive on its own -- ESC, which with the
        # next byte straight behind it reads as one Alt chord.
        def type_paced(chunk):
            parts = chunk.split("{pause}")
            for part in parts[:-1]:
                shell.write(part.encode("utf-8"))
                pump(0.3, chunks)
            shell.write(parts[-1].encode("utf-8") + b"\r")

        lines = text.split("\r")
        for line in lines[:-1]:
            type_paced(line)
            pump(0.3, chunks)
        type_paced(lines[-1])
        seen = pump_until_prompt(ceiling, chunks, seen)
    # Everything up to here is what the verdict is on. What follows `exit` is the shell leaving -- fish
    # reports a D for the exit command itself -- and is shown, not judged.
    judged = len(b"".join(chunks))
    shell.write(b"exit\r")
    pump(1.5, chunks)
finally:
    if history_file and os.path.exists(history_file):
        if history_before is None:
            os.remove(history_file)
        else:
            with open(history_file, "wb") as f:
                f.write(history_before)

out = b"".join(chunks)
text = out.decode("utf-8", "replace")
judged_text = out[:judged].decode("utf-8", "replace")

if home:
    shutil.rmtree(home, ignore_errors=True)

if os.environ.get("RAW"):
    # The stream itself, escapes made visible -- what to read when the marks are wrong.
    print(text.replace("\x1b", "<ESC>").replace("\x07", "<BEL>").replace("\r", "<CR>"))
    print("-" * 60)
# As a terminal reads them: ended by BEL or by ST (ESC \\), and with whatever parameters the shell
# adds -- fish sends A;click_events=1 and C;cmdline_url=... of its own. Matching only BEL and bare
# marks once hid a fish that sent every D twice, because that fish ends its marks with ST.
MARK = r"\x1b\]133;([A-D])((?:;[^\x07\x1b]*)?)(?:\x07|\x1b\\)"


def parse(stream):
    # The status is D's first parameter; other marks' parameters are not this harness's business.
    return [(kind, params.split(";")[1] if kind == "D" and params else "")
            for kind, params in re.findall(MARK, stream)]


marks = parse(text)
judged_marks = parse(judged_text)
cwd = re.findall(r"\x1b\](?:7|9;9);([^\x07\x1b]*)(?:\x07|\x1b\\)", text)

print(f"shell    : {SHELL}  ({BINARY})" + (f"  scenario {SCENARIO}" if SCENARIO else ""))
print("133 marks:", " ".join(m[0] + (f"({m[1]})" if m[1] else "") for m in marks) or "NONE")
print("osc 7    :", cwd[0] if cwd else "NONE")
print()

kinds = {m[0] for m in marks}
missing = {"A", "B", "C", "D"} - kinds

if missing:
    print(f"missing: {' '.join(sorted(missing))}")
    print("A = prompt start, B = prompt end, C = command start, D = command finished")
    sys.exit(1)

statuses = [m[1] for m in judged_marks if m[0] == "D"]
starts = sum(1 for m in judged_marks if m[0] == "A")
ends = sum(1 for m in judged_marks if m[0] == "B")
commands = sum(1 for m in judged_marks if m[0] == "C")
# The probe, when there is one, runs first and succeeds.
expected_statuses = (["0"] if probe else []) + [status for _, status in COMMANDS]
print(f"all four marks present; exit statuses reported: {', '.join(statuses)}")
print(f"expected {', '.join(expected_statuses)}, one for each command typed")
print(f"prompts  : {starts} started (A), {ends} ended (B); {commands} commands started (C)")

failures = []
# The verdict CI runs on: every mark, the statuses in order, a B for every prompt -- a theme
# that rebuilds the prompt drops one appended at startup -- and a directory report.
if statuses != expected_statuses:
    failures.append(f"statuses not {', '.join(expected_statuses)}")
# Exactly one of each: the first prompt and one after each command get an A and a B, each command
# a C. Fewer means something went unmarked; more means two parties are marking -- a shell with
# marks of its own, and the integration on top.
expected_prompts = len(expected_statuses) + 1
if starts != expected_prompts:
    failures.append(f"{starts} prompts marked with A, expected {expected_prompts}")
if ends != expected_prompts:
    failures.append(f"{ends} prompts marked with B, expected {expected_prompts}")
if commands != len(expected_statuses):
    failures.append(f"{commands} commands marked with C, expected {len(expected_statuses)}")
if not cwd:
    failures.append("no working directory report")

hooks = re.findall(r"hook-saw:(\d+)", text)
if hooks:
    print("user hook saw:", " ".join(hooks))
    # The last prompts follow the commands typed, and a hook reports what each one left behind.
    expected_hooks = extras.get("hooks", expected_statuses)
    if hooks[-len(expected_hooks):] != expected_hooks:
        failures.append("the user's own hook saw the wrong $?")
for needle in required:
    found = needle in text
    print(f"{'found  ' if found else 'MISSING'}  {needle}")
    if not found:
        failures.append(f"missing {needle!r}")
for needle in absent:
    found = needle in text
    print(f"{'PRESENT' if found else 'absent '}  {needle}")
    if found:
        failures.append(f"unexpected {needle!r}")
for pattern in required_re:
    found = re.search(pattern, judged_text)
    print(f"{'found  ' if found else 'MISSING'}  /{pattern}/")
    if not found:
        failures.append(f"missing /{pattern}/")
for pattern, expected in required_count.items():
    expected = {"prompts": expected_prompts, "commands": len(expected_statuses)}.get(expected, expected)
    n = len(re.findall(pattern, judged_text))
    print(f"{'found  ' if n == expected else 'COUNT  '}  /{pattern}/ x{n}, expected {expected}")
    if n != expected:
        failures.append(f"/{pattern}/ {n} times, expected {expected}")
for pattern in absent_re:
    found = re.search(pattern, text)
    print(f"{'PRESENT' if found else 'absent '}  /{pattern}/" + (f"  {found.group(0)!r}" if found else ""))
    if found:
        failures.append(f"unexpected /{pattern}/")
# Text the prompt draws must sit inside the prompt: after its A, before its B. Write-Host output
# goes out while the prompt function runs, ahead of the string it returns, so marks carried only
# in that string end up after the prompt they are meant to bracket.
for needle in between_ab:
    events = sorted([(m.start(), "A") for m in re.finditer(r"\x1b\]133;A", judged_text)]
                    + [(m.start(), "B") for m in re.finditer(r"\x1b\]133;B", judged_text)]
                    + [(m.start(), "N") for m in re.finditer(re.escape(needle), judged_text)])
    last, outside = None, 0
    for _, kind in events:
        if kind == "N":
            outside += last != "A"
        else:
            last = kind
    print(f"{'inside ' if not outside else 'OUTSIDE'}  {needle} between A and B"
          + (f" ({outside} not)" if outside else ""))
    if outside:
        failures.append(f"{needle!r} drawn outside its prompt's A and B")

if failures:
    print("FAIL: " + "; ".join(failures))
    sys.exit(1)
print("PASS")
