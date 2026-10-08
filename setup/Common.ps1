<#
Shared logging, dry-run, and command-detection helpers for windots scripts.
Dot-source: . (Join-Path $PSScriptRoot 'Common.ps1')
Expects the dot-sourcing script to declare -DryRun where Invoke-IfNotDryRun
is used; [CmdletBinding()] gives it -Verbose for Write-Verbose detail.
#>

# The shared dotfiles checkout; Configure-Env.ps1 persists DOTFILES, and a
# fresh machine (before that step) falls back to Bootstrap.ps1's clone path.
$DotfilesRoot = if ($env:DOTFILES) { $env:DOTFILES } else { Join-Path $HOME 'dotfiles' }
$ScoopRoot = if ([string]::IsNullOrWhiteSpace($env:SCOOP)) {
    Join-Path $HOME 'scoop'
}
else { $env:SCOOP }
# This checkout; $PSScriptRoot is setup\ even when dot-sourced.
$WindotsRoot = Split-Path -Parent $PSScriptRoot
function WindotsPath([string]$Relative) { Join-Path $WindotsRoot $Relative }

$script:Warnings = [System.Collections.Generic.List[string]]::new()

function Write-Info($msg) { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Warn($msg) {
    $script:Warnings.Add($msg)
    Write-Host "[WARN]  $msg" -ForegroundColor Yellow
}

function Test-Command([string]$Name) {
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-IfNotDryRun {
    param([scriptblock]$Action)
    if (-not $DryRun) { & $Action }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [int[]]$SuccessExitCodes = @(0)
    )

    if ($DryRun) { return $true }

    $nativeOutput = @(& $Action 2>&1)
    if ($LASTEXITCODE -notin $SuccessExitCodes) {
        $nativeOutput | Out-Host
        Write-Warn "$Description failed with exit code $LASTEXITCODE."
        return $false
    }

    $nativeOutput | Out-String | Write-Verbose

    return $true
}

function Get-EmacsRoots {
    [pscustomobject]@{
        ConfigRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
            Join-Path $HOME '.config\emacs'
        }
        else { Join-Path $env:XDG_CONFIG_HOME 'emacs' }
        DataRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) {
            Join-Path $HOME '.local\share\emacs'
        }
        else { Join-Path $env:XDG_DATA_HOME 'emacs' }
        StateRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_STATE_HOME)) {
            Join-Path $HOME '.local\state\emacs'
        }
        else { Join-Path $env:XDG_STATE_HOME 'emacs' }
    }
}

# Runs a program elevated (UAC prompt), by default pwsh; returns its exit code,
# or $null when elevation is declined.
function Invoke-Elevated(
    [string[]]$ArgumentList,
    [string]$FilePath = (Get-Process -Id $PID).Path
) {
    try {
        $start = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; Verb = 'RunAs' }
        (Start-Process @start -Wait -PassThru).ExitCode
    }
    catch { $null }
}

# Reruns a script elevated with the parameters it was given ($PSBoundParameters),
# in a window left open to read the output. Warns when elevation is declined.
function Invoke-ScriptElevated(
    [string]$ScriptPath,
    [System.Collections.IDictionary]$Parameters
) {
    $quote = { "'" + ($args[0] -replace "'", "''") + "'" }
    $params = foreach ($name in $Parameters.Keys) {
        $value = $Parameters[$name]
        if ($value -is [switch]) { "-${name}:`$$([bool]$value)" }
        else { "-$name " + (@($value | ForEach-Object { & $quote $_ }) -join ',') }
    }
    $invocation = "& $(& $quote $ScriptPath) $params"
    $command = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
    $exitCode = Invoke-Elevated '-NoProfile', '-NoExit', '-EncodedCommand', $command
    if ($null -eq $exitCode) { Write-Warning 'Elevation declined.' }
}

# Per-profile Emacs paths and the environment variables its framework reads.
function Get-ProfilePaths {
    param([Parameter(Mandatory)][string]$Name)

    $roots = Get-EmacsRoots
    switch ($Name) {
        'doom' {
            $paths = [pscustomobject]@{
                Framework = Join-Path $roots.DataRoot 'doom'
                Profile = Join-Path $roots.ConfigRoot 'doom'
                Local = Join-Path $roots.StateRoot 'doom'
            }
            $paths | Add-Member Environment @{
                EMACSDIR = $paths.Framework
                DOOMDIR = $paths.Profile
                DOOMLOCALDIR = $paths.Local
            }
            return $paths
        }
        default {
            return [pscustomobject]@{
                Framework = Join-Path $roots.DataRoot 'spacemacs'
                Profile = Join-Path $roots.ConfigRoot $Name
                Local = $null
                Environment = @{ SPACEMACSDIR = (Join-Path $roots.ConfigRoot $Name) }
            }
        }
    }
}

# Runs $Body with $Vars set in the process environment, then restores them.
function Invoke-WithEnvironment([hashtable]$Vars, [scriptblock]$Body) {
    $saved = @{}
    try {
        foreach ($name in $Vars.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            Set-Item -Path "Env:$name" -Value $Vars[$name]
        }
        & $Body
    }
    finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) {
                Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
            }
            else { Set-Item -Path "Env:$name" -Value $saved[$name] }
        }
    }
}

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$identity
        return $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Stop-AutoHotkeyScript([string]$ScriptPath) {
    # Normalize so callers can pass '..' paths; AHK's command line holds the resolved
    # one.
    $ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
    Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkeyUX.exe'" |
        Where-Object { $_.CommandLine -like "*$ScriptPath*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}
