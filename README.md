# Terminal.ShellIntegration

Makes a shell tell the terminal what it is doing.

A terminal can only know where a prompt began, when a command started, and what it exited with if
the shell says so — that is OSC 133. Stock bash and zsh say nothing, so a host is left guessing.
Every terminal that wants those features injects integration into the shell it spawns; this is that
injection, and nothing else.

```csharp
var result = ShellIntegration.Prepare(
    shellPath: "/bin/zsh",
    args: [],
    environment: currentEnvironment,
    resourcesDirectory: "/path/to/shell-integration");

if (result.Injected)
    Spawn(shellPath, result.Args, result.Environment);
else
    Console.WriteLine($"left alone: {result.Skipped}");
```

That is the whole API. Arguments and environment in, arguments and environment out.

## Install

```sh
dotnet add package Terminal.ShellIntegration
```

The scripts ship inside the package and are copied into your app's output directory under
`shell-integration/`, so `resourcesDirectory` is normally
`Path.Combine(AppContext.BaseDirectory, "shell-integration")`. The library itself references
nothing outside the BCL. MIT.

## What the shell then reports

| | |
|---|---|
| `OSC 133;A` | a prompt begins |
| `OSC 133;B` | the prompt ends and typing begins |
| `OSC 133;C` | a command starts, output follows |
| `OSC 133;D;<status>` | the command finished, with its exit status |
| `OSC 7` | the working directory |

Which buys jump-to-previous-prompt, click-to-select a command's output, exit status in the margin,
a new tab that opens where the old one was, and knowing whether the shell is busy without guessing.

## How each shell is reached

| shell | mechanism |
|---|---|
| **bash** | `--posix` plus `ENV` |
| **zsh** | `ZDOTDIR`, put back in `.zshenv` before any of the user's files run |
| **fish** | `XDG_DATA_DIRS` plus `vendor_conf.d`, which fish loads on its own; fish 4.0+ marks the prompt itself, and the script then adds only what fish does not |
| **PowerShell** | `-NoExit -Command ". integration.ps1"` — runs *after* the profiles, so it wraps the prompt they installed |

The PowerShell one is the one Ghostty never had to write, and it is the easiest of the four to
inject: `-Command` runs after every profile, so `$function:prompt` already holds whatever the
user — or oh-my-posh, or starship — put there, and the script wraps it rather than replacing it.
It also means `-NoProfile` still gets integration, which no profile-based mechanism could give.
The C mark comes from wrapping PSReadLine's line reader, installed lazily from the first prompt
because PSReadLine loads *after* `-Command` finishes.

The bash one is the only surprising one. `--init-file` looks like the obvious hook and is silently
ignored for a login shell, so it never runs for a great many people. POSIX mode sources `$ENV`
whatever kind of shell it is — the price being that the script must then replay bash's own startup
sequence, since bash skipped it.

The mechanism follows [Ghostty's](https://github.com/ghostty-org/ghostty), which is MIT licensed and
had already solved problems worth not rediscovering.

## Design

**No dependencies.** The library references nothing outside the BCL; the scripts use shell builtins
only, and fork no processes. There is no UI, no PTY and no terminal emulator here — the transform is
a pure function over strings, which is what makes the shell-specific quirks testable without
spawning anything.

**The host keeps two decisions**: whether to inject at all, since a user must be able to turn it
off, and where the scripts live, since only the host knows where its own files are. The scripts have
to be real files on disk, because a shell sources a path.

**Shells are left alone** when they are not recognised, when they were asked to run a command and
exit, when integration is already present — a shell spawned from an instrumented one would emit
every mark twice — and when the scripts are missing. Each case says which, because a shell that
reports nothing looks exactly like a shell that was never instrumented.

## Testing

```
dotnet test                                    # the transform: arguments and environment
dotnet build src/Terminal.ShellIntegration -c Release
python3 tools/check-shell-integration.py zsh   # a real shell, through a pty
python3 tools/check-shell-integration.py bash /opt/homebrew/bin/bash
python3 tools/check-shell-integration.py fish
python3 tools/check-shell-integration.py pwsh
python3 tools/check-shell-integration.py zsh --scenario zsh-xdg   # a user configuration that broke it once
python3 tools/check-shell-integration.py --list                   # every scenario
```

Without `--scenario` the shell reads your own configuration. A scenario gives it a throwaway `HOME`
holding one particular setup instead, and checks that the user's files ran, that every prompt got
its `B`, and that the user's own prompt hooks saw their command's `$?` rather than the integration's.

Both halves are needed, and the second is not optional. Four bugs were found by running real shells
while the unit tests stayed green throughout — the C# side had the right answer every time:

- **zsh**: `local status=$?` silently breaks a function, because `status` is a special parameter in
  zsh aliased to `$?`. The prompt still drew; only the `A` and `D` marks went missing.
- **bash**: `PS0` reaches its hook through a command substitution, so the flag saying a command was
  running died with the subshell. `C` survived by accident — its output was captured into `PS0`'s
  value and printed as part of the prompt.
- **fish**: it searches each data directory for `fish/vendor_conf.d`, so naming the `fish` folder
  itself made it look for `fish/fish/vendor_conf.d` and load nothing, quietly.
- **OSC 7**: the path is unescaped by whoever reads it, so a directory named `a%2Fb` arrived as
  `a/b`. Only a well-formed escape corrupts — spaces and non-ASCII survive — so only the percent is
  escaped.

PowerShell added three more, two of them in the harness rather than the script:

- **Enter is CR.** The harness sent `\n`, which the tty line discipline maps for bash, zsh and
  fish — but PSReadLine puts the tty in raw mode and reads keys itself, and LF is Ctrl+J to it.
  Three commands became one line that never ran.
- **Answer each terminal query once.** The harness gained a second answer to the cursor-position
  query; .NET consumed the first, and the second was typed — `1;1R` in front of every command,
  so every command was a parse error and even `exit` failed. The symptom looks exactly like a
  broken shell, and it was a duplicated line in a list.
- **`-Command` is history entry 1.** The script that loads via `-Command` is recorded in history,
  so "history advanced since the last prompt" was true before the user typed anything and the
  first prompt carried a D for a command nobody ran. The first prompt now only records where
  history stands.

Three more came from configurations rather than shells, and are scenarios now:

- **zsh with `ZDOTDIR` in `.zshenv`** (`zsh-xdg`). The XDG layout moves `ZDOTDIR` in `.zshenv`, and
  the integration lived in an injected `.zshrc` that was only reached while `ZDOTDIR` still pointed
  at it — so zsh went to the user's directory instead and integration silently never loaded. The
  injected `.zshenv` now puts the user's `ZDOTDIR` back before their `.zshenv` runs, as Ghostty
  does, and then loads `integration.zsh` from the resources directory under zsh's own emulation,
  so nothing depends on a `.zshrc` in the injected directory ever being read. Handing over `HOME`
  when they had no `ZDOTDIR` broke the
  `${ZDOTDIR:-~/.config/zsh}` spelling of the same thing (`zsh-xdg-default`), so nothing is handed
  over then.
- **A theme that rebuilds `PS1`** (`zsh-rebuild-ps1`, `bash-rebuild-ps1`). `B` was appended to the
  prompt once, at startup; powerlevel10k or starship replaces the prompt every time and `B` went
  with it. It is now re-added by a hook that runs after the user's. zsh runs its first round of
  hooks from a copy of the list, so on the very first prompt `B` comes from `zle-line-init` instead.
- **`$?` in the string form of `PROMPT_COMMAND`** (`bash-string-pc`). Each part sees the status of
  the one before it, and the integration's ran first, so the user's own hooks always saw `0`. The
  integration now hands the command's status on. The array form gives every element the command's
  status (bash 5.3), so its order never mattered there.

And two in fish and the harness itself:

- **fish marks its own prompt.** Since 4.0 fish sends `A`, `C` and `D` itself, and since 4.3 `B`
  too, so the terminal got every mark twice. The harness never saw it: it only read marks ended by
  BEL and without parameters, and fish 4.8 ends its marks with ST (`ESC \`) and adds
  `click_events=1` and `cmdline_url=`. fish 4.2.1 ends them with BEL, and that is what CI's
  Ubuntu 26.04 runner caught. The harness now reads marks as a terminal does and requires exactly
  one of each per prompt and command; the script asks fish (`status test-feature mark-prompt`)
  and leaves to it whatever it sends, keeping `OSC 7` and, before 4.3, `B`.
- **`TERM`.** The harness passed its own environment through, and CI runners set no `TERM`; zsh
  without one never runs `zle-line-init`, which on the first prompt is where `B` comes from under a
  theme that rebuilds the prompt. A terminal always sets `TERM`, so the harness now does too.

Verified against pwsh 7.6.5 on macOS. **Windows is not yet verified**: the script emits
`OSC 9;9` with a bare path there rather than `file://`, because `file://host/C:/x` decodes to
`/C:/x`, and Windows PowerShell 5.1 is targeted by syntax but has not been run.

The harness answers terminal queries as it goes. Modern shells interrogate the terminal before
drawing anything — fish asks for the kitty keyboard flags, the terminal version, the background
colour, terminfo capabilities and the device attributes — and then wait. Silence leaves them blocked
before the first prompt, which again looks exactly like integration that never loaded.

Verified against zsh 5.9, bash 5.3.15, and fish 4.8.1, 4.2.1 and 3.7.1. macOS ships bash 3.2 from 2007, which does not
source `$ENV` in POSIX mode at all; Ghostty documents the same limitation for the same bash.

## License

MIT. The injection mechanisms follow Ghostty's, which is MIT.
