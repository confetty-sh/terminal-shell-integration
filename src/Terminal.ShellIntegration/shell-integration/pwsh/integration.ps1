# Shell integration for PowerShell: OSC 133 prompt marks and OSC 7 working directory, plus the
# features the host turned on in TERMINAL_SHELL_FEATURES.
#
# Loaded by `pwsh -NoExit -Command ". <this file>"`. That runs AFTER the profiles, so
# $function:prompt is whatever the user -- or oh-my-posh, or starship -- installed, and it is
# wrapped rather than replaced. Nothing of the user's is displaced, and -NoProfile still works,
# because this arrives by -Command rather than by profile.
#
# Kept 5.1-compatible on purpose. `e, the ternary and ?? are 7-only, and Windows PowerShell is
# still the default shell on a great many machines that Confetty will land on first.

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { return }

# A shell that dot-sources this twice would emit every mark twice.
if (Test-Path variable:Global:__TerminalIntegration) { return }

$Global:__TerminalIntegration = @{
    OriginalPrompt   = $function:prompt
    OriginalReadLine = $null
    CommandRunning   = $false
    LastHistoryId    = -1    # -1 until the first prompt has seen where history stands
    ReadLineReturned = $true # false while PSReadLine is still reading the line its prompt drew
    ExitCodeBefore   = $null # $LASTEXITCODE, and the newest error, as they stood when the
    ErrorBefore      = $null # command began: what decides which of the two its failure was
    Bar              = $null # DECSCUSR for the prompt's cursor, when the cursor feature is on
    Title            = $false
    SudoPath         = $null # the programs the wrappers below run
    SshPath          = $null
}

# Whether the host turned a feature on. The list is Ghostty's shape -- cursor:blink,sudo,title --
# so a name is matched whole, ahead of the colon that carries a setting. Case matters, as in
# Ghostty's own names.
function Global:__Terminal-HasFeature([string] $Name) {
    foreach ($entry in "$env:TERMINAL_SHELL_FEATURES".Split(',')) {
        if ($entry.Split(':')[0] -ceq $Name) { return $true }
    }
    return $false
}

if (__Terminal-HasFeature 'cursor') {
    # 5 blinks, 6 is steady.
    $Global:__TerminalIntegration.Bar = 5
    if (",$env:TERMINAL_SHELL_FEATURES," -clike '*,cursor:steady,*') { $Global:__TerminalIntegration.Bar = 6 }
}
$Global:__TerminalIntegration.Title = __Terminal-HasFeature 'title'

function Global:__Terminal-Osc([string] $Body) {
    return "$([char]27)]$Body$([char]7)"
}

function Global:__Terminal-ReportCwd {
    # The FILESYSTEM location, not the current one. In Env:, Function: or HKLM: there is no
    # directory -- ProviderPath is empty, or a registry key -- and the last real directory is still
    # where a new tab should open.
    $location = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    if ([string]::IsNullOrEmpty($location)) { return '' }

    # $IsWindows is 7-only; on 5.1 it is simply absent, and $env:OS is the older tell.
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        # OSC 9;9 with a bare quoted path -- the form Microsoft's own prompts emit and the
        # emulator already reads. A file:// URI for C:\Users would decode to /C:/Users, a leading
        # slash that no Windows API accepts.
        return (__Terminal-Osc "9;9;`"$location`"")
    }

    # Not $host, which is PowerShell's own automatic variable and must not be assigned.
    $machine = [Environment]::MachineName
    return (__Terminal-Osc "7;file://$machine$($location.Replace('%', '%25'))")
}

# The C mark -- "output begins here" -- has to go out after Enter and before the command runs,
# and the only hook that sits there is PSReadLine's line reader. It is wrapped, not replaced, so
# every key handler the user configured keeps working; this only looks at the line it returns.
function Global:__Terminal-InstallReadLineHook {
    $state = $Global:__TerminalIntegration
    if ($null -ne $state.OriginalReadLine) { return }

    $existing = Get-Command -Name PSConsoleHostReadLine -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $existing) { return }

    $state.OriginalReadLine = $existing.ScriptBlock

    function Global:PSConsoleHostReadLine {
        $state = $Global:__TerminalIntegration
        $state.ReadLineReturned = $false
        try {
            $line = & $state.OriginalReadLine
        } finally {
            # Even when reading was cut short, so the next prompt is known for a new one.
            $state.ReadLineReturned = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $state.CommandRunning = $true
            __Terminal-RememberBefore
            $out = __Terminal-Osc '133;C'
            # 0 is the terminal's own default, so the user's cursor, for as long as the command runs.
            if ($null -ne $state.Bar) { $out += "$([char]27)[0 q" }
            if ($state.Title) { $out += __Terminal-Osc "2;$(__Terminal-Printable $line)" }
            [Console]::Write($out)
        }
        return $line
    }
}

# Where $LASTEXITCODE and the error list stand before a command, so that afterwards it can be told
# which of them its failure came from. $LASTEXITCODE is the code of the last NATIVE command and is
# left alone by everything else, so after `git` fails with 3 a failing cmdlet still finds 3 there.
function Global:__Terminal-RememberBefore {
    $state = $Global:__TerminalIntegration
    $state.ExitCodeBefore = $Global:LASTEXITCODE
    $state.ErrorBefore = $null
    if ($Global:Error.Count -gt 0) { $state.ErrorBefore = $Global:Error[0] }
}

# The status for D, from $? and $LASTEXITCODE as the command left them.
function Global:__Terminal-ExitCode([bool] $Succeeded, $LastExit) {
    if ($Succeeded) { return 0 }
    if (-not (($LastExit -is [int]) -and ($LastExit -ne 0))) { return 1 }

    # A native command ran if it moved $LASTEXITCODE. When it did not move, the failure is still
    # the native one unless PowerShell recorded an error of its own -- a cmdlet, a throw -- which
    # it does for everything but a native command. Compared by identity: the list stops growing
    # at $MaximumErrorCount, so its length would stop saying anything.
    $state = $Global:__TerminalIntegration
    $newError = ($Global:Error.Count -gt 0) -and
        (-not [object]::ReferenceEquals($Global:Error[0], $state.ErrorBefore))
    if (($LastExit -ne $state.ExitCodeBefore) -or (-not $newError)) { return $LastExit }
    return 1
}

function Global:prompt {
    # FIRST, before anything in here can overwrite them. $? is the success of the last
    # statement the user ran; $LASTEXITCODE is the code of the last NATIVE command, which a
    # failing cmdlet leaves untouched -- so $? decides whether $LASTEXITCODE is even relevant.
    $succeeded = $?
    $lastExit = $LASTEXITCODE

    $state = $Global:__TerminalIntegration

    # PSReadLine draws the prompt again while it is still reading the line -- input over several
    # lines, InvokePrompt from a key handler, a transient prompt. That is the same prompt redrawn,
    # not a new one, so it gets no marks: zsh's reset-prompt does not rerun precmd either. Only
    # once the hook is in, since without PSReadLine there is no reading to be in the middle of.
    if (($null -ne $state.OriginalReadLine) -and -not $state.ReadLineReturned) {
        return (__Terminal-UserPrompt $succeeded)
    }

    $out = ''

    # PSReadLine loads AFTER -Command finishes and interactive mode begins, so it was not there
    # when this file ran. Install the hook the first time the prompt draws, when it is.
    __Terminal-InstallReadLineHook

    # Without PSReadLine there is no C mark, but history still says whether a command ran.
    #
    # Measured from the first prompt rather than from zero: pwsh records the -Command that
    # loaded this file as history entry 1, so "history advanced" was true before the user had
    # typed anything, and the very first prompt carried a D for a command nobody ran.
    $last = Get-History -Count 1 -ErrorAction SilentlyContinue
    $historyAdvanced = $false
    if ($state.LastHistoryId -lt 0) {
        $state.LastHistoryId = 0
        if ($null -ne $last) { $state.LastHistoryId = $last.Id }
    } elseif ($null -ne $last) {
        $historyAdvanced = $last.Id -gt $state.LastHistoryId
    }

    if ($state.CommandRunning -or $historyAdvanced) {
        $out += __Terminal-Osc "133;D;$(__Terminal-ExitCode $succeeded $lastExit)"
        $state.CommandRunning = $false
    }

    if ($null -ne $last) { $state.LastHistoryId = $last.Id }

    $out += __Terminal-ReportCwd
    $out += __Terminal-Osc '133;A'

    # The bar only once the line reader is wrapped: that is what puts the user's cursor back for
    # the command, and without it the bar would stay for everything that runs.
    if (($null -ne $state.Bar) -and ($null -ne $state.OriginalReadLine)) { $out += "$([char]27)[$($state.Bar) q" }
    if ($state.Title) { $out += __Terminal-Osc "2;$(__Terminal-TitleLocation)" }

    # Written now rather than returned with the prompt. A prompt drawn with Write-Host -- posh-git,
    # and a great many hand-written ones -- is on the screen before its function returns, so marks
    # that rode in the returned string came after the prompt they were meant to open.
    [Console]::Write($out)

    $prompt = __Terminal-UserPrompt $succeeded

    # Without PSReadLine, the next command is whatever runs before the next prompt.
    if ($null -eq $state.OriginalReadLine) { __Terminal-RememberBefore }

    return $prompt + (__Terminal-Osc '133;B')
}

# The user's own prompt, whatever installed it, seeing the $? their command left: starship and
# oh-my-posh read it to colour the prompt after a failure, and by now it says only that this
# script's own statements succeeded. It cannot be assigned, but a statement that fails sets it, and
# with -ErrorAction Ignore that one is recorded nowhere.
function Global:__Terminal-UserPrompt([bool] $Succeeded) {
    $original = $Global:__TerminalIntegration.OriginalPrompt
    if ($null -ne $original) {
        try {
            # A ScriptBlock invoked returns a collection, hence the join.
            if (-not $Succeeded) { Write-Error '' -ErrorAction Ignore }
            return ((& $original) -join '')
        } catch {
            # A prompt that throws would take the marks down with it. PowerShell draws its
            # default in that case, and so does this.
        }
    }
    return "PS $($ExecutionContext.SessionState.Path.CurrentLocation)$('>' * ($NestedPromptLevel + 1)) "
}

# A title has no room for control characters: an ESC or BEL in one would end it early and the rest
# would arrive as output. A command over several lines becomes one.
function Global:__Terminal-Printable([string] $Text) {
    return ($Text -replace '[\x00-\x1f\x7f]', '')
}

# Where the shell is, for the title, with the home directory spelled ~ -- and only the home directory
# itself or what is under it, so /home/jo is not taken for ~ when home is /home/j. Any location,
# not only a directory: in Env: the title says Env:\.
function Global:__Terminal-TitleLocation {
    $location = $ExecutionContext.SessionState.Path.CurrentLocation.Path
    $homeDir = $HOME
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { $comparison = [StringComparison]::OrdinalIgnoreCase }
    else { $comparison = [StringComparison]::Ordinal }
    if (-not [string]::IsNullOrEmpty($homeDir) -and $homeDir.Length -gt 1) {
        $homeDir = $homeDir.TrimEnd('\', '/')
        if ($location.Equals($homeDir, $comparison)) {
            $location = '~'
        } elseif ($location.StartsWith($homeDir + [IO.Path]::DirectorySeparatorChar, $comparison)) {
            $location = '~' + $location.Substring($homeDir.Length)
        }
    }
    return (__Terminal-Printable $location)
}

# ---- features that wrap a command ------------------------------------------------------------
#
# Only over a plain program: an alias or function of the user's is theirs, and wrapping it would
# either lose what it does or loop. The profiles have run by now, so theirs are known.
function Global:__Terminal-PlainProgram([string] $Name) {
    if ($null -ne (Get-Command -Name $Name -CommandType Alias, Function -ErrorAction SilentlyContinue)) { return $null }
    $program = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $program) { return $null }
    return $program.Source
}

# sudo: keep TERMINFO, which sudo's env_reset drops. Only when there is one -- a host that ships its
# own terminfo sets it, and a TERM from the system database needs nothing kept. Not on Windows,
# which has no terminfo.
#
# Each wrapper is a script of its own beside this one, reached through an alias, not a function:
# through a function a command that failed reads as success -- see sudo.ps1.
if ((__Terminal-HasFeature 'sudo') -and -not [string]::IsNullOrEmpty($env:TERMINFO) `
        -and -not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    $Global:__TerminalIntegration.SudoPath = __Terminal-PlainProgram 'sudo'
    if ($null -ne $Global:__TerminalIntegration.SudoPath) {
        Set-Alias -Name sudo -Value (Join-Path $PSScriptRoot 'sudo.ps1') -Scope Global
    }
}

# ssh-env: offer the remote what this terminal is -- see ssh.ps1.
if (__Terminal-HasFeature 'ssh-env') {
    $Global:__TerminalIntegration.SshPath = __Terminal-PlainProgram 'ssh'
    if ($null -ne $Global:__TerminalIntegration.SshPath) {
        Set-Alias -Name ssh -Value (Join-Path $PSScriptRoot 'ssh.ps1') -Scope Global
    }
}

# ssh-terminfo and path are accepted and do nothing. Ghostty installs its own terminfo on the remote
# and puts its own CLI on PATH; a host whose TERM every remote already has (xterm-256color) has no
# terminfo to install, and this library has no CLI.
