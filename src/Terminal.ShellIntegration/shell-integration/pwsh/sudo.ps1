# sudo, keeping TERMINFO: the sudo feature, reached through the `sudo` alias integration.ps1 sets.
#
# A script rather than a function, for the exit status. A function's caller sees $? true whatever
# the native command inside it did, so a sudo that failed would be reported as success; a script
# that exits with a code sets both $? and $LASTEXITCODE for its caller, exactly as sudo itself does.

$program = $Global:__TerminalIntegration.SudoPath

# sudoedit (-e, --edit) is left alone, since it never runs a program on this terminal. The first
# argument that is neither an option, an option's value, nor an assignment is the command sudo is
# to run, and what follows it is that command's own -- so `sudo -u www -e f` is sudoedit, and
# `sudo ls -e` is not.
$valueLetters = 'CDgpRrTtUu'
$valueOptions = '--close-from', '--chdir', '--group', '--prompt', '--chroot', '--role',
    '--command-timeout', '--type', '--other-user', '--user'
$keep = $true
$skip = $false
foreach ($arg in $args) {
    $text = "$arg"
    if ($skip) { $skip = $false; continue }
    if (($text -ceq '-e') -or ($text -ceq '--edit')) { $keep = $false; break }
    if ($valueOptions -ccontains $text) { $skip = $true; continue }
    if ($text -ceq '--') { break }
    if ($text.StartsWith('--')) { continue }
    if (($text.Length -gt 1) -and $text.StartsWith('-')) {
        # Short options, alone or run together: -E, -iu root, -uroot. A letter that takes a value
        # takes the rest of the run, or the next argument when it is the last.
        for ($i = 1; $i -lt $text.Length; $i++) {
            if ($text[$i] -ceq 'e') { $keep = $false; break }
            if ($valueLetters.IndexOf($text[$i]) -ge 0) { $skip = ($i -eq $text.Length - 1); break }
        }
        if (-not $keep) { break }
        continue
    }
    if ($text.Contains('=')) { continue }
    break
}

$flags = @()
if ($keep) { $flags = @('--preserve-env=TERMINFO') }

# Piped input goes on to sudo; without any, sudo keeps the terminal as its stdin.
if ($MyInvocation.ExpectingInput) { $input | & $program @flags @args }
else { & $program @flags @args }
exit $LASTEXITCODE
