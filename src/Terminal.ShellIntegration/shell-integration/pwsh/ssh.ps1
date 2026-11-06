# ssh, offering the terminal's environment: the ssh-env feature, reached through the `ssh` alias
# integration.ps1 sets. A script rather than a function for the exit status -- see sudo.ps1.
#
# SendEnv adds to whatever the user's ssh_config sends, and the remote takes only what its
# sshd_config AcceptEnv allows. When TERM comes from a private terminfo (TERMINFO is set) the remote
# will not have it, so the connection gets xterm-256color instead, put back afterwards however ssh
# ends.

$program = $Global:__TerminalIntegration.SshPath
$send = '-o', 'SendEnv=COLORTERM', '-o', 'SendEnv=TERM_PROGRAM', '-o', 'SendEnv=TERM_PROGRAM_VERSION'

$term = $env:TERM
if (-not [string]::IsNullOrEmpty($env:TERMINFO)) { $env:TERM = 'xterm-256color' }
try {
    # Piped input goes on to ssh; without any, ssh keeps the terminal as its stdin.
    if ($MyInvocation.ExpectingInput) { $input | & $program @send @args }
    else { & $program @send @args }
} finally {
    $env:TERM = $term
}
exit $LASTEXITCODE
