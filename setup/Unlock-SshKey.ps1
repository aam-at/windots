<#
Loads an SSH private key into the persistent Windows OpenSSH agent.

Usage:
  pwsh -File .\setup\Unlock-SshKey.ps1
  pwsh -File .\setup\Unlock-SshKey.ps1 -KeyPath $HOME\.ssh\id_ed25519
  pwsh -File .\setup\Unlock-SshKey.ps1 -DryRun

The ssh-agent service must be enabled first. Configure-Registry.ps1 does that
as an elevated setup step. Windows associates keys added to this agent with
the signed-in Windows account, so the key remains available after later
sign-ins without storing its passphrase in this repository or a startup task.
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
if ($agent.Status -ne 'Running') {
    if ($DryRun) {
        Write-Info "Would unlock SSH key in ssh-agent: $KeyPath"
        exit 0
    }
    throw 'Windows OpenSSH ssh-agent is not running. Run Setup.ps1 or Configure-Registry.ps1 from an elevated PowerShell session first.'
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
