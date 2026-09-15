<#
Shared logging, dry-run, and command-detection helpers for windots scripts.
Dot-source: . (Join-Path $PSScriptRoot 'Common.ps1')
Expects the dot-sourcing script to declare -LogLevel (and -DryRun where
Invoke-IfNotDryRun is used).
#>

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

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkingDirectory) {
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Save()
}

function Stop-AutoHotkeyScript([string]$ScriptPath) {
    Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkeyUX.exe'" |
        Where-Object { $_.CommandLine -like "*$ScriptPath*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}
