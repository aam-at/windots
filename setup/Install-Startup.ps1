<#
Creates the Startup-folder shortcuts for the chosen desktop mode (plus YASB and
Kanata, used by both),
removes the other mode's shortcuts, and starts anything not yet running.
Native mode also turns off the Win+L lock shortcut so Native-Desktop.ahk can
use Win+L as niri's focus-right; Komorebi mode turns it back on.

Usage:
  pwsh -File .\setup\Install-Startup.ps1 -DesktopMode Native
  pwsh -File .\setup\Install-Startup.ps1 -DesktopMode Komorebi -DryRun
#>

param(
    [switch]$DryRun,
    [ValidateSet('Native', 'Komorebi')]
    [string]$DesktopMode = 'Native',
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot
function RepoPath([string]$Relative) { Join-Path $RepoRoot $Relative }

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkingDirectory) {
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Save()
}

function Resolve-Executable([string[]]$Candidates) {
    foreach ($candidate in $Candidates) {
        if ([System.IO.Path]::IsPathRooted($candidate)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            continue
        }
        $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
}

function Resolve-KanataGui {
    # Scoop's kanata package only shims the console (tty) build; the tray-icon
    # (gui) build sits unshimmed in the app folder, so PATH lookup can't find it.
    $scoopRoot = if ([string]::IsNullOrWhiteSpace($env:SCOOP)) { Join-Path $HOME 'scoop' } else { $env:SCOOP }
    $kanataAppRoot = Join-Path $scoopRoot 'apps\kanata\current'
    Get-ChildItem -LiteralPath $kanataAppRoot -Filter 'kanata_windows_gui_winIOv2_*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*cmd_allowed*' } |
        Select-Object -First 1 -ExpandProperty FullName
}

function Resolve-VirtualDesktopHelper {
    $scoopRoot = if ([string]::IsNullOrWhiteSpace($env:SCOOP)) { Join-Path $HOME 'scoop' } else { $env:SCOOP }
    $helper = Join-Path $scoopRoot 'apps\windows-virtualdesktop-helper\current\WindowsVirtualDesktopHelper.exe'
    if (Test-Path -LiteralPath $helper -PathType Leaf) { return $helper }
}

function Ensure-StartupShortcut {
    param(
        [string]$Name,
        [string[]]$Candidates,
        [string]$Arguments,
        [string]$RunningProcessName
    )

    $target = Resolve-Executable $Candidates
    if (-not $target) {
        Write-Warn "$Name executable not found on PATH; skipping Startup shortcut."
        return $false
    }

    $startupDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $shortcutPath = Join-Path $startupDirectory "$Name.lnk"
    Write-Info "Creating Startup shortcut: $shortcutPath"
    if ($DryRun) { return $true }

    New-Shortcut -Path $shortcutPath -Target $target -Arguments $Arguments -WorkingDirectory (Split-Path -Parent $target)

    # Start it now too, so setup doesn't require a reboot to see it running.
    $processName = if ($RunningProcessName) { $RunningProcessName } else { [System.IO.Path]::GetFileNameWithoutExtension($target) }
    if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
        Write-Info "$Name is already running."
    }
    else {
        Write-Info "Starting $Name..."
        if ([string]::IsNullOrWhiteSpace($Arguments)) {
            Start-Process -FilePath $target -WorkingDirectory (Split-Path -Parent $target) | Out-Null
        }
        else {
            Start-Process -FilePath $target -ArgumentList $Arguments -WorkingDirectory (Split-Path -Parent $target) | Out-Null
        }
    }
    return $true
}

function Remove-StartupShortcut([string]$Name) {
    $startupDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $path = Join-Path $startupDirectory "$Name.lnk"
    if (-not (Test-Path -LiteralPath $path)) { return }

    Write-Info "Removing Startup shortcut: $path"
    if (-not $DryRun) { Remove-Item -LiteralPath $path -Force }
}

function Set-LockShortcut([bool]$Enabled) {
    $policy = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'
    Write-Info "$(if ($Enabled) { 'Enabling' } else { 'Disabling' }) the Win+L lock shortcut"
    if ($DryRun) { return }
    try {
        New-ItemProperty -Path $policy -Name DisableLockWorkstation -Value ([int](-not $Enabled)) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warn "Cannot change the Win+L lock shortcut; run setup\Configure-Registry.ps1 elevated first. ($($_.Exception.Message))"
    }
}

try {
    # Native-Desktop.ahk locks via Win+Alt+L / Win+X; Komorebi keeps Win+L.
    Set-LockShortcut ($DesktopMode -eq 'Komorebi')

    # The helper's startupWithWindows option adds its own Run entry, which
    # doubled it up alongside the Startup shortcut below (and ran it in
    # Komorebi mode too). The shortcut is the only launcher.
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Get-ItemProperty -Path $runKey -Name 'Windows Virtual Desktop Helper' -ErrorAction SilentlyContinue) {
        Write-Info 'Removing the Windows Virtual Desktop Helper Registry startup entry'
        Invoke-IfNotDryRun { Remove-ItemProperty -Path $runKey -Name 'Windows Virtual Desktop Helper' }
    }

    if ($DesktopMode -eq 'Komorebi') {
        # --ahk is end-of-life in komorebic (not in `komorebic start --help`
        # any more): it prints a deprecation notice and never actually starts
        # AutoHotkey, so we launch it ourselves against the real script path.
        Remove-StartupShortcut 'NativeDesktop'
        $komorebiConfig = RepoPath 'shells\komorebi\komorebi.json'
        $komorebiArguments = 'start --clean-state --config "{0}"' -f $komorebiConfig
        [void](Ensure-StartupShortcut -Name 'Komorebi' -Candidates @('komorebic-no-console', 'komorebic') -Arguments $komorebiArguments -RunningProcessName 'komorebi')
        $komorebiAhk = RepoPath 'shells\komorebi\komorebi.ahk'
        [void](Ensure-StartupShortcut -Name 'KomorebiAHK' -Candidates @('autohotkey', 'AutoHotkey64') -Arguments ('"{0}"' -f $komorebiAhk) -RunningProcessName 'AutoHotkeyUX')
        Remove-StartupShortcut 'VirtualDesktopHelper'
        if (-not $DryRun) { Get-Process -Name WindowsVirtualDesktopHelper -ErrorAction SilentlyContinue | Stop-Process -Force }
    }
    else {
        Remove-StartupShortcut 'Komorebi'
        Remove-StartupShortcut 'KomorebiAHK'
        $virtualDesktopHelperCandidates = @(Resolve-VirtualDesktopHelper) + @('WindowsVirtualDesktopHelper') | Where-Object { $_ }
        # Native-Desktop.ahk owns Win+1..9; the helper only shows the desktop number.
        [void](Ensure-StartupShortcut -Name 'VirtualDesktopHelper' -Candidates $virtualDesktopHelperCandidates -Arguments '' -RunningProcessName 'WindowsVirtualDesktopHelper')
        $nativeDesktop = RepoPath 'shells\native\Native-Desktop.ahk'
        [void](Ensure-StartupShortcut -Name 'NativeDesktop' -Candidates @('autohotkey', 'AutoHotkey64') -Arguments ('"{0}"' -f $nativeDesktop) -RunningProcessName 'AutoHotkeyUX')
    }
    # YASB is the top bar in both modes; its workspace widgets adapt to the mode.
    [void](Ensure-StartupShortcut -Name 'YASB' -Candidates @('yasb') -Arguments '')
    $kanataConfig = Join-Path $HOME '.config\kanata\config.kbd'
    $kanataCandidates = @(Resolve-KanataGui) + @('kanata_gui', 'kanata-gui', 'kanata') | Where-Object { $_ }
    [void](Ensure-StartupShortcut -Name 'Kanata' -Candidates $kanataCandidates -Arguments ('-c "{0}"' -f $kanataConfig))
}
catch {
    Write-Error $_
    exit 1
}
