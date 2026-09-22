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

function Ensure-GitCheckout {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        if (Test-Path -LiteralPath (Join-Path $Destination '.git')) {
            Write-Info "$Name framework already present: $Destination"
            return $false
        }

        Write-Warn "$Name destination exists but is not a Git checkout; preserving it: $Destination"
        return $false
    }

    if (-not (Test-Command 'git')) {
        throw "Git is required to install the $Name framework."
    }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        Write-Info "Creating Emacs framework directory: $parent"
        Invoke-IfNotDryRun { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }

    Write-Info "Cloning $Name framework..."
    if (-not (Invoke-NativeCommand -Description "$Name framework" -Action { git clone --depth=1 $Repository $Destination | Out-Null })) {
        throw "Unable to clone the $Name framework."
    }

    return $true
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        $Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $property.Value = $Value
    }
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
            Set-ObjectProperty -Object $Destination -Name $sourceProperty.Name -Value $sourceProperty.Value
        }
    }
}

function Invoke-ElevatedScript {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [hashtable]$Arguments = @{}
    )

    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    foreach ($entry in $Arguments.GetEnumerator()) {
        if ($entry.Value -is [switch] -or $entry.Value -is [bool]) {
            if ($entry.Value) { $argumentList += "-$($entry.Key)" }
        }
        else {
            $argumentList += "-$($entry.Key)", "$($entry.Value)"
        }
    }

    $shell = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $shell) { $shell = Get-Command powershell -CommandType Application -ErrorAction Stop | Select-Object -First 1 }

    try {
        $process = Start-Process -FilePath $shell.Source -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
        return $process.ExitCode -eq 0
    }
    catch {
        return $false
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
