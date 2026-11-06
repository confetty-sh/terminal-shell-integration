# sudo, keeping TERMINFO: the sudo feature, reached through the `sudo` alias integration.ps1 sets.
#
# A script rather than a function, for the exit status. A function's caller sees $? true whatever
# the native command inside it did, so a sudo that failed would be reported as success; a script
# that exits with a code sets both $? and $LASTEXITCODE for its caller, exactly as sudo itself does.

$program = $Global:__TerminalIntegration.SudoPath

# sudoedit (-e, --edit) is left alone, since it never runs a program on this terminal. The first
# argument that is neither an option nor an assignment is the command sudo is to run, and what
# follows it is that command's own.
$keep = $true
foreach ($arg in $args) {
    $text = "$arg"
    if (($text -ceq '-e') -or ($text -ceq '--edit')) { $keep = $false; break }
    if (-not ($text.StartsWith('-') -or $text.Contains('='))) { break }
}

$flags = @()
if ($keep) { $flags = @('--preserve-env=TERMINFO') }

# Piped input goes on to sudo; without any, sudo keeps the terminal as its stdin.
if ($MyInvocation.ExpectingInput) { $input | & $program @flags @args }
else { & $program @flags @args }
exit $LASTEXITCODE
