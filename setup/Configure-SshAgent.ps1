<#
Enables the Windows OpenSSH agent service (prompting for UAC if needed) and
loads an SSH private key into it.

Usage:
    pwsh -File .\setup\Configure-SshAgent.ps1
    pwsh -File .\setup\Configure-SshAgent.ps1 -KeyPath $HOME\.ssh\id_ed25519
    pwsh -File .\setup\Configure-SshAgent.ps1 -DryRun

Windows associates keys added to this agent with the signed-in Windows
account, so the key remains available after later sign-ins without storing
its passphrase in this repository or a startup task.
#>

param(
    [string]$KeyPath = (Join-Path $HOME '.ssh\id_ed25519'),
    [switch]$DryRun,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
    throw "SSH private key not found: $KeyPath"
}

$agent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
if ($null -eq $agent) {
    throw 'Windows OpenSSH ssh-agent service is not installed.'
}
if ($agent.StartType -ne 'Automatic' -or $agent.Status -ne 'Running') {
    Write-Info 'Configuring ssh-agent to start automatically at boot.'
    if ($DryRun) {
        Write-Info "Would unlock SSH key in ssh-agent: $KeyPath"
        exit 0
    }

    $enableAgent = 'Set-Service -Name ssh-agent -StartupType Automatic; Start-Service -Name ssh-agent'
    if (Test-IsAdmin) {
        Invoke-Expression $enableAgent
    }
    else {
        Write-Info 'Requesting administrator approval to enable the ssh-agent service...'
        $shell = (Get-Process -Id $PID).Path
        try { Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-Command', $enableAgent) -Verb RunAs -Wait }
        catch { throw 'Enabling the ssh-agent service needs administrator approval.' }
    }
    if ((Get-Service -Name ssh-agent).Status -ne 'Running') {
        throw 'Windows OpenSSH ssh-agent failed to start.'
    }
}

$fingerprints = @(& ssh-add -l 2>$null)
if ($LASTEXITCODE -eq 0) {
    $keyFingerprint = @(& ssh-keygen -lf $KeyPath 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $keyFingerprint) {
        $fingerprint = ($keyFingerprint -split '\s+')[1]
        if ($fingerprints | Where-Object { $_ -like "*$fingerprint*" }) {
            Write-Info "SSH key is already unlocked in ssh-agent: $KeyPath"
            exit 0
        }
    }
}

Write-Info "Unlocking SSH key in ssh-agent: $KeyPath"
if ($DryRun) { exit 0 }

# ssh-add deliberately prompts in this foreground terminal. The passphrase is
# never written to disk; after a successful add, Windows persists the key in
# the user-bound ssh-agent service for future logons.
& ssh-add $KeyPath
if ($LASTEXITCODE -ne 0) {
    throw "ssh-add failed with exit code $LASTEXITCODE."
}
