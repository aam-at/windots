<#
Shared logging, dry-run, and command-detection helpers for windots scripts.
Dot-source: . (Join-Path $PSScriptRoot 'Common.ps1')
Expects the dot-sourcing script to declare -LogLevel (and -DryRun where
Invoke-IfNotDryRun is used).
#>

# The shared dotfiles checkout; Configure-Env.ps1 persists DOTFILES, and a
# fresh machine (before that step) falls back to Bootstrap.ps1's clone path.
$DotfilesRoot = if ($env:DOTFILES) { $env:DOTFILES } else { Join-Path $HOME 'dotfiles' }

$script:LogLevels = @{ Debug = 0; Info = 1; Warn = 2; Error = 3 }
$script:Warnings = [System.Collections.Generic.List[string]]::new()

function Test-LogLevel([string]$Level) { $script:LogLevels[$Level] -ge $script:LogLevels[$LogLevel] }
function Write-DebugInfo($msg) { if (Test-LogLevel 'Debug') { Write-Host "[DEBUG] $msg" -ForegroundColor DarkGray } }
function Write-Info($msg) { if (Test-LogLevel 'Info') { Write-Host "[INFO]  $msg" -ForegroundColor Cyan } }
function Write-Warn($msg) { $script:Warnings.Add($msg); if (Test-LogLevel 'Warn') { Write-Host "[WARN]  $msg" -ForegroundColor Yellow } }
function Write-Err($msg) { if (Test-LogLevel 'Error') { Write-Host "[ERROR] $msg" -ForegroundColor Red } }

function Test-Command([string]$Name) { $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

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

    if (Test-LogLevel 'Debug') { $nativeOutput | Out-Host }

    return $true
}

function Merge-ObjectProperties {
    param(
        [Parameter(Mandatory)]
        [psobject]$Destination,

        [Parameter(Mandatory)]
        [psobject]$Source
    )

    foreach ($sourceProperty in $Source.PSObject.Properties) {
        $destinationProperty = $Destination.PSObject.Properties[$sourceProperty.Name]
        if (($null -ne $destinationProperty) -and
            ($destinationProperty.Value -is [pscustomobject]) -and
            ($sourceProperty.Value -is [pscustomobject])) {
            Merge-ObjectProperties -Destination $destinationProperty.Value -Source $sourceProperty.Value
        }
        else {
            $Destination | Add-Member -NotePropertyName $sourceProperty.Name -NotePropertyValue $sourceProperty.Value -Force
        }
    }
}

function Get-EmacsRoots {
    [pscustomobject]@{
        ConfigRoot = if ([string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) { Join-Path $HOME '.config\emacs' } else { Join-Path $env:XDG_CONFIG_HOME 'emacs' }
        DataRoot   = if ([string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) { Join-Path $HOME '.local\share\emacs' } else { Join-Path $env:XDG_DATA_HOME 'emacs' }
        StateRoot  = if ([string]::IsNullOrWhiteSpace($env:XDG_STATE_HOME)) { Join-Path $HOME '.local\state\emacs' } else { Join-Path $env:XDG_STATE_HOME 'emacs' }
    }
}

function Test-IsAdmin {
    try {
        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Stop-AutoHotkeyScript([string]$ScriptPath) {
    # Normalize so callers can pass '..' paths; AHK's command line holds the resolved one.
    $ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
    Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkeyUX.exe'" |
        Where-Object { $_.CommandLine -like "*$ScriptPath*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}
