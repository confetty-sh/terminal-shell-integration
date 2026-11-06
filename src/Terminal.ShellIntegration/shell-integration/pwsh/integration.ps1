# Shell integration for PowerShell: OSC 133 prompt marks and OSC 7 working directory.
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
}

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
            [Console]::Write((__Terminal-Osc '133;C'))
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
