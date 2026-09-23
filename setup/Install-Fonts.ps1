<#
Clones the font repositories below into ~/local/tools and installs their
.ttf/.otf files. Installs machine-wide when elevated, per-user otherwise.

Usage:
  pwsh -File .\setup\Install-Fonts.ps1
  pwsh -File .\setup\Install-Fonts.ps1 -DryRun
#>

param(
    [switch]$DryRun,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
    [string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$fontsRoot = Join-Path $HOME 'local\tools'
$fontsMap = @{
    'adobe-fonts'     = 'https://github.com/adobe-fonts/source-code-pro.git'
    'all-icons-fonts' = 'https://github.com/domtronn/all-the-icons.el.git'
    'iawriter-fonts'  = 'https://github.com/iaolo/iA-Fonts.git'
    'icons-fonts'     = 'https://github.com/sebastiencs/icons-in-terminal.git'
    'jetbrains-fonts' = 'https://github.com/JetBrains/JetBrainsMono.git'
    'nerd-fonts'      = 'https://github.com/ryanoasis/nerd-fonts.git'
    'powerline-fonts' = 'https://github.com/powerline/fonts.git'
}

$namespace = 'WindotsFontInstaller'
if ($null -eq ("$namespace.NativeMethods" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace $namespace {
    public static class NativeMethods {
        [DllImport("gdi32.dll", EntryPoint="AddFontResourceW", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern int AddFontResource(string lpFileName);
        [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)]
        public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    }
}
"@
}
$Native = ("$namespace.NativeMethods" -as [type])

function Install-Font {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$FontFile,
        [Parameter(Mandatory)][bool]$IsCurrentUser
    )

    try {
        if ($IsCurrentUser) {
            $fontsDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
            $registryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        }
        else {
            $fontsDirectory = Join-Path $env:WINDIR 'Fonts'
            $registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        }

        $fontPath = Join-Path $fontsDirectory $FontFile.Name
        # Windows loads fonts by file, not by value name; the filename keeps
        # each face's value stable and distinct.
        $fontKind = if ($FontFile.Extension -ieq '.otf') { 'OpenType' } else { 'TrueType' }
        $registryName = "$($FontFile.BaseName) ($fontKind)"
        # Current-user fonts need an absolute registry path. Windows resolves
        # machine-wide font filenames relative to %WINDIR%\Fonts.
        $registryValue = if ($IsCurrentUser) { $fontPath } else { $FontFile.Name }

        $copied = $false
        if (-not (Test-Path -LiteralPath $fontPath)) {
            New-Item -ItemType Directory -Path $fontsDirectory -Force | Out-Null
            Copy-Item -LiteralPath $FontFile.FullName -Destination $fontPath -ErrorAction Stop
            $copied = $true
        }

        New-ItemProperty -Path $registryPath -Name $registryName -Value $registryValue -PropertyType String -Force | Out-Null

        if ($Native::AddFontResource($fontPath) -eq 0) {
            throw 'Windows could not load the registered font.'
        }

        $state = if ($copied) { 'Installed' } else { 'Registered' }
        Write-DebugInfo "${state}: $($FontFile.Name)"
        return $true
    }
    catch {
        Write-Warn "Font failed: $($FontFile.Name): $($_.Exception.Message)"
        return $false
    }
}

function Install-FontFolder([string]$FontFolder, [bool]$IsCurrentUser) {
    $fontFiles = @(Get-ChildItem -LiteralPath $FontFolder -File -Recurse |
            Where-Object { $_.Extension -in '.ttf', '.otf' })
    if ($fontFiles.Count -eq 0) { throw "No .ttf or .otf files found in $FontFolder." }

    Write-Info "Installing $($fontFiles.Count) font files from $FontFolder..."
    $failed = 0
    foreach ($font in $fontFiles) {
        if (-not (Install-Font -FontFile $font -IsCurrentUser $IsCurrentUser)) { $failed++ }
    }
    if ($failed -gt 0) { throw "$failed of $($fontFiles.Count) font files failed to install from $FontFolder." }
}

$isCurrentUser = -not (Test-IsAdmin)
Write-Info "Downloading and installing fonts for $(if ($isCurrentUser) { 'the current user' } else { 'all users' })..."
if (-not (Test-Path -LiteralPath $fontsRoot)) {
    Write-Info "Creating fonts directory: $fontsRoot"
    Invoke-IfNotDryRun { New-Item -ItemType Directory -Path $fontsRoot -Force | Out-Null }
}

foreach ($kvp in $fontsMap.GetEnumerator()) {
    $dest = Join-Path $fontsRoot $kvp.Key
    if (-not (Test-Path -LiteralPath $dest)) {
        Write-Info "Cloning $($kvp.Key)..."
        if (-not (Invoke-NativeCommand -Description "font repository $($kvp.Key)" -Action { git clone --depth=1 $kvp.Value $dest | Out-Null })) {
            throw "Unable to clone font repository: $($kvp.Key)"
        }
    }
    if ($DryRun) { Write-Info "Would install fonts from $dest"; continue }
    Install-FontFolder $dest $isCurrentUser
}

if (-not $DryRun) { [void]$Native::SendMessage([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero) }
Write-Info 'Font installation step complete. Restart affected applications to refresh their font lists.'
