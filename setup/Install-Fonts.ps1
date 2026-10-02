<#
Clones the font repositories below into ~/local/tools and installs their
.ttf/.otf files. Installs machine-wide when elevated, per-user otherwise.

Usage:
  pwsh -File .\setup\Install-Fonts.ps1
  pwsh -File .\setup\Install-Fonts.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [switch]$DryRun
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

# Tabler Icons has no font in its git repo (1 GB of SVGs); the npm package ships
# one, plus a filled set. YASB's caffeinate widget uses the filled mug and the outline mug-off.
$tablerFonts = 'tabler-icons', 'tabler-icons-filled' | ForEach-Object {
    "https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.48.0/dist/fonts/$_.ttf"
}

if ($null -eq ('Windots.Font' -as [type])) {
    Add-Type -Namespace Windots -Name Font -MemberDefinition @'
[DllImport("gdi32.dll", EntryPoint="AddFontResourceW", CharSet=CharSet.Unicode, SetLastError=true)]
public static extern int AddFontResource(string lpFileName);
[DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
'@
}
$Native = 'Windots.Font' -as [type]

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
        Write-Verbose "${state}: $($FontFile.Name)"
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

$tablerDest = Join-Path $fontsRoot 'tabler-fonts'
foreach ($url in $tablerFonts) {
    $file = Join-Path $tablerDest ([IO.Path]::GetFileName($url))
    if (Test-Path -LiteralPath $file) { continue }
    Write-Info "Downloading $url..."
    if ($DryRun) { continue }
    New-Item -ItemType Directory -Path $tablerDest -Force | Out-Null
    Invoke-WebRequest -Uri $url -OutFile $file
    # The font names its family "tabler-icons", the outline set's name; give it
    # its own so the two never shadow each other.
    if ($file -like '*-filled.ttf') {
        @'
import sys
from fontTools.ttLib import TTFont
font = TTFont(sys.argv[1])
for record in font['name'].names:
    if record.nameID in (1, 4, 16):
        record.string = 'tabler-icons-filled'
    elif record.nameID == 6:
        record.string = 'tabler-icons-filled-Regular'
font.save(sys.argv[1])
'@ | uv run --quiet --with fonttools python - $file
        if ($LASTEXITCODE) { throw 'Renaming the filled Tabler font failed.' }
    }
}
if (-not $DryRun) { Install-FontFolder $tablerDest $isCurrentUser }

# Broadcast WM_FONTCHANGE; a plain SendMessage waits forever on any window that
# isn't pumping messages, so skip hung ones (SMTO_ABORTIFHUNG) after 1s each.
if (-not $DryRun) { $result = [IntPtr]::Zero; [void]$Native::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 0x2, 1000, [ref]$result) }
Write-Info 'Font installation step complete. Restart affected applications to refresh their font lists.'
