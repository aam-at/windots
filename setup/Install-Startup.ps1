<#
Creates the Startup-folder shortcuts for the chosen desktop mode (plus YASB, thide
and Kanata, used by both),
removes the other mode's shortcuts, and starts anything not yet running.
Both modes turn off the Win+L lock shortcut so the AutoHotkey bindings can use
Win+L as niri's focus-right.

Usage:
  pwsh -File .\setup\Install-Startup.ps1 -DesktopMode Native
  pwsh -File .\setup\Install-Startup.ps1 -DesktopMode Komorebi -DryRun
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet('Native', 'Komorebi')]
    [string]$DesktopMode = 'Native'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$ScoopRoot = if ([string]::IsNullOrWhiteSpace($env:SCOOP)) { Join-Path $HOME 'scoop' } else { $env:SCOOP }

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
    $kanataAppRoot = Join-Path $ScoopRoot 'apps\kanata\current'
    Get-ChildItem -LiteralPath $kanataAppRoot -Filter 'kanata_windows_gui_winIOv2_*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*cmd_allowed*' } |
        Select-Object -First 1 -ExpandProperty FullName
}

function Resolve-VirtualDesktopHelper {
    $helper = Join-Path $ScoopRoot 'apps\windows-virtualdesktop-helper\current\WindowsVirtualDesktopHelper.exe'
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
    # Only this session counts: a service with the same exe (Everything's) runs in session 0.
    if (Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object SessionId -eq (Get-Process -Id $PID).SessionId) {
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

# Native helpers: battery.exe behind the YASB battery widget (hidden until it
# builds), language.exe behind the language widget, window-watcher.exe, which replaces aw-watcher-window and
# aw-watcher-afk (no ActivityWatch data until it builds), psmux-agent.exe
# (psmux's status stats, auto-save and aw-watcher-tmux), and dotfiles'
# tools\wellbeing\wellbeing.exe
# (screen time, limits, focus mode, bedtime). The build skips an exe newer
# than its source.
function Build-NativeHelpers {
    $buildScript = WindotsPath 'yasb\Build-Native.ps1'
    $helpers = @(
        @{ Source = WindotsPath 'yasb\battery\battery.c'; Libs = 'powrprof' }
        @{ Source = WindotsPath 'yasb\language\language.c' }
        @{ Source = WindotsPath 'yasb\activitywatch\window-watcher.c'; Libs = 'ws2_32'; Windows = $true }
        @{ Source = WindotsPath 'psmux\psmux-agent.c'; Libs = 'ws2_32'; Windows = $true }
        @{ Source = Join-Path $DotfilesRoot 'tools\wellbeing\wellbeing.c'; Libs = 'ws2_32', 'dwmapi'; Windows = $true }
    )
    foreach ($helper in $helpers) {
        Write-Info "Building $($helper.Source)"
        if ($DryRun) { continue }
        try { & $buildScript @helper }
        catch { Write-Warn "$($_.Exception.Message) (retry: pwsh -File $buildScript $($helper.Source))" }
    }
}

# aw-server serves dotfiles' tools\wellbeing\dashboard (screen time and
# wellbeing's settings) at
# /pages/wellbeing/, on its own origin so the page can query it. Returns
# whether aw-server.toml changed, which takes a restart.
function Set-WellbeingDashboard {
    $config = Join-Path $env:LOCALAPPDATA 'activitywatch\activitywatch\aw-server\aw-server.toml'
    $entry = "wellbeing = '{0}'" -f ((Join-Path $DotfilesRoot 'tools\wellbeing\dashboard') -replace '\\', '/')
    $text = if (Test-Path -LiteralPath $config) { Get-Content -LiteralPath $config -Raw } else { "[server]`n`n[server.custom_static]`n" }
    if ($text.Contains($entry)) { return $false }
    $text = $text -replace '(?m)^wellbeing\s*=.*\r?\n', ''
    if ($text -notmatch '(?m)^\[server\.custom_static\]') { $text += "`n[server.custom_static]`n" }
    $text = $text -replace '(?m)^\[server\.custom_static\][ \t]*\r?\n', "[server.custom_static]`n$entry`n"
    Write-Info "Serving the wellbeing dashboard from aw-server: $config"
    Invoke-IfNotDryRun {
        New-Item -ItemType Directory -Path (Split-Path -Parent $config) -Force | Out-Null
        Set-Content -LiteralPath $config -Value $text -NoNewline
    }
    return $true
}

try {
    # Both desktop scripts lock via Win+Alt+L / Win+X instead.
    Set-LockShortcut $false

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
        # komorebi.json's app_specific_configuration_path: the community rules
        # (floating dialogs, ignored tray windows), fetched fresh, not vendored.
        Write-Info 'Fetching Komorebi applications.json'
        $env:KOMOREBI_CONFIG_HOME = WindotsPath 'shells\komorebi'
        [void](Invoke-NativeCommand -Description 'komorebic fetch-asc' -Action { komorebic fetch-asc })
        $komorebiConfig = WindotsPath 'shells\komorebi\komorebi.json'
        $komorebiArguments = 'start --clean-state --config "{0}"' -f $komorebiConfig
        [void](Ensure-StartupShortcut -Name 'Komorebi' -Candidates @('komorebic-no-console', 'komorebic') -Arguments $komorebiArguments -RunningProcessName 'komorebi')
        $komorebiAhk = WindotsPath 'shells\komorebi\komorebi.ahk'
        [void](Ensure-StartupShortcut -Name 'KomorebiAHK' -Candidates @('autohotkey', 'AutoHotkey64') -Arguments ('"{0}"' -f $komorebiAhk) -RunningProcessName 'AutoHotkeyUX')
        # masir: focus follows the mouse, limited to windows Komorebi manages.
        # It is a console app, which Windows Terminal (the default terminal)
        # would open a tab for; conhost --headless runs it with no window.
        if ($masir = Resolve-Executable @((Join-Path $env:ProgramFiles 'masir\bin\masir.exe'), 'masir')) {
            [void](Ensure-StartupShortcut -Name 'Masir' -Candidates @(Join-Path $env:SystemRoot 'System32\conhost.exe') -Arguments ('--headless "{0}"' -f $masir) -RunningProcessName 'masir')
        }
        Remove-StartupShortcut 'VirtualDesktopHelper'
        if (-not $DryRun) { Get-Process -Name WindowsVirtualDesktopHelper -ErrorAction SilentlyContinue | Stop-Process -Force }
    }
    else {
        Remove-StartupShortcut 'Komorebi'
        Remove-StartupShortcut 'KomorebiAHK'
        Remove-StartupShortcut 'Masir'
        if (-not $DryRun) { Get-Process -Name masir -ErrorAction SilentlyContinue | Stop-Process -Force }
        $virtualDesktopHelperCandidates = @(Resolve-VirtualDesktopHelper) + @('WindowsVirtualDesktopHelper') | Where-Object { $_ }
        # Native-Desktop.ahk owns Win+1..9; the helper only shows the desktop number.
        [void](Ensure-StartupShortcut -Name 'VirtualDesktopHelper' -Candidates $virtualDesktopHelperCandidates -Arguments '' -RunningProcessName 'WindowsVirtualDesktopHelper')
        $nativeDesktop = WindotsPath 'shells\native\Native-Desktop.ahk'
        [void](Ensure-StartupShortcut -Name 'NativeDesktop' -Candidates @('autohotkey', 'AutoHotkey64') -Arguments ('"{0}"' -f $nativeDesktop) -RunningProcessName 'AutoHotkeyUX')
    }
    # YASB is the top bar in both modes; its config lists "$env:YASB_WORKSPACES"
    # as the workspace widget, so each mode shows only its own workspaces.
    $yasbWorkspaces = if ($DesktopMode -eq 'Komorebi') { 'komorebi_workspaces' } else { 'windows_desktops' }
    Write-Info "Setting YASB_WORKSPACES=$yasbWorkspaces"
    Invoke-IfNotDryRun { [Environment]::SetEnvironmentVariable('YASB_WORKSPACES', $yasbWorkspaces, 'User') }
    Build-NativeHelpers
    [void](Ensure-StartupShortcut -Name 'YASB' -Candidates @('yasb') -Arguments '')
    # thide (scoop\thide.json) hides the Windows taskbar in both modes: the YASB
    # dock slides in from the bottom edge, where the taskbar would pop up too.
    # Target the real exe, not the Scoop shim, which would stay running beside it.
    # Everything stays in the tray so searches (and the es CLI) are instant.
    [void](Ensure-StartupShortcut -Name 'Everything' -Candidates @((Join-Path $ScoopRoot 'apps\everything\current\Everything.exe')) -Arguments '-startup' -RunningProcessName 'Everything')
    # ActivityWatch logs the active app and AFK time locally, for a daily view
    # of where focus went (http://127.0.0.1:5600). Only its server runs: the
    # native window-watcher.exe replaces both Python watchers, and aw-qt (a
    # tray icon that starts them) isn't needed. aw-server is a console app,
    # so conhost --headless runs it with no window, like masir.
    $awServer = Join-Path $ScoopRoot 'apps\activitywatch\current\aw-server\aw-server.exe'
    # A running aw-server reads its config only on start.
    if ((Set-WellbeingDashboard) -and -not $DryRun) { Get-Process -Name aw-server -ErrorAction SilentlyContinue | Stop-Process -Force }
    [void](Ensure-StartupShortcut -Name 'ActivityWatch' -Candidates @(Join-Path $env:SystemRoot 'System32\conhost.exe') -Arguments ('--headless "{0}"' -f $awServer) -RunningProcessName 'aw-server')
    [void](Ensure-StartupShortcut -Name 'WindowWatcher' -Candidates @((WindotsPath 'yasb\activitywatch\window-watcher.exe')) -Arguments '' -RunningProcessName 'window-watcher')
    [void](Ensure-StartupShortcut -Name 'PsmuxAgent' -Candidates @((WindotsPath 'psmux\psmux-agent.exe')) -Arguments '' -RunningProcessName 'psmux-agent')
    [void](Ensure-StartupShortcut -Name 'Wellbeing' -Candidates @((Join-Path $DotfilesRoot 'tools\wellbeing\wellbeing.exe')) -Arguments '' -RunningProcessName 'wellbeing')
    [void](Ensure-StartupShortcut -Name 'THide'-Candidates @((Join-Path $ScoopRoot 'apps\thide\current\thide.exe'), 'thide') -Arguments 'start' -RunningProcessName 'thide')
    $kanataConfig = Join-Path $HOME '.config\kanata\config.kbd'
    $kanataCandidates = @(Resolve-KanataGui) + @('kanata_gui', 'kanata-gui', 'kanata') | Where-Object { $_ }
    [void](Ensure-StartupShortcut -Name 'Kanata' -Candidates $kanataCandidates -Arguments ('-c "{0}"' -f $kanataConfig))
}
catch {
    Write-Error $_
    exit 1
}
