<#
Applies the Windows registry settings used by this dotfiles setup.

Usage:
  pwsh -File .\setup\Configure-Registry.ps1
  pwsh -File .\setup\Configure-Registry.ps1 -DryRun

Run from an elevated terminal (or let Setup.ps1 prompt for UAC approval) to
also enable Windows Sudo, Developer Mode, long paths, the closed-lid agent
power plan, and the persistent Windows OpenSSH agent.
#>

param(
    [switch]$DryRun,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Set-Dword([string]$Path, [string]$Name, [int]$Value) {
    Write-Info "Setting ${Path}\$Name=$Value"
    if (-not $DryRun) {
        New-Item -Path $Path -Force | Out-Null
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    }
}

function Set-PowerCfg([string[]]$Arguments) {
    Write-Info "powercfg $($Arguments -join ' ')"
    if ($DryRun) { return }

    & powercfg @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg failed: $($Arguments -join ' ')"
    }
}

function Enable-SshAgent {
    $agent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if ($null -eq $agent) {
        Write-Warn 'Windows OpenSSH ssh-agent service is not installed; skipping SSH key persistence.'
        return
    }

    Write-Info 'Configuring ssh-agent to start automatically at boot.'
    if ($DryRun) { return }

    Set-Service -Name ssh-agent -StartupType Automatic
    if ($agent.Status -ne 'Running') {
        Start-Service -Name ssh-agent
    }
}

$explorerAdvanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-Dword $explorerAdvanced 'Hidden' 1
Set-Dword $explorerAdvanced 'HideFileExt' 0
Set-Dword $explorerAdvanced 'ShowSuperHidden' 0
Set-Dword $explorerAdvanced 'TaskbarEndTask' 1

if (-not (Test-IsAdmin)) {
    Write-Warn 'Skipping Windows Sudo, Developer Mode, Win32 long paths, persistent ssh-agent, and power-plan settings; they require an elevated session.'
    exit 0
}

Set-Dword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo' 'Enabled' 3
Set-Dword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowDevelopmentWithoutDevLicense' 1
Set-Dword 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1
Enable-SshAgent

<#
Agent power mode
----------------
These settings are written through powercfg rather than New-ItemProperty.
Windows keeps the per-plan values under:

  HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\
    <active scheme GUID>\<subgroup GUID>\<setting GUID>

The relevant DWORD names are ACSettingIndex (plugged in) and DCSettingIndex
(on battery). powercfg is used so the active scheme is updated safely and
Windows immediately reloads the policy.

  Sleep after
    subgroup: SUB_SLEEP (238c9fa8-0aad-41ed-83f4-97be242c8f20)
    setting:  STANDBYIDLE (29f6c1db-86da-48c5-9fdb-f2b67b1f44da)
    DCSettingIndex = 0: never enter sleep from battery idle.

  Hibernate after
    subgroup: SUB_SLEEP
    setting:  HIBERNATEIDLE (9d7815a6-7ee4-497e-8888-515a05f02364)
    DCSettingIndex = 0: never hibernate from battery idle.
    Critical-battery policy is intentionally unchanged, so Windows can still
    protect the system when the battery is nearly empty.

  Lid close action
    subgroup: SUB_BUTTONS (4f971e89-eebd-4455-a8de-9e59040e7347)
    setting:  LIDACTION (5ca83367-6e45-459f-a27b-476b1d01c936)
    ACSettingIndex = 0 and DCSettingIndex = 0: do nothing.
    The laptop's built-in panel turns off physically when the lid is shut;
    external monitors and agent processes keep running.

Modern Standby can hide LIDACTION. The -ATTRIB_HIDE command removes the
hidden attribute from the setting metadata at:

  HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\
    4f971e89-eebd-4455-a8de-9e59040e7347\
    5ca83367-6e45-459f-a27b-476b1d01c936

This is deliberately applied to SCHEME_CURRENT only; it does not change the
other built-in power plans.
#>
$lidAction = '5ca83367-6e45-459f-a27b-476b1d01c936'
Set-PowerCfg @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'STANDBYIDLE', '0')
Set-PowerCfg @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HIBERNATEIDLE', '0')
Set-PowerCfg @('-attributes', 'SUB_BUTTONS', $lidAction, '-ATTRIB_HIDE')
Set-PowerCfg @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', $lidAction, '0')
Set-PowerCfg @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', $lidAction, '0')
Set-PowerCfg @('/setactive', 'SCHEME_CURRENT')
