param(
    [Parameter(Mandatory)]
    [string]$FontFolder,

    [switch]$CurrentUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

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

function Get-FontFamilyName {
    param([Parameter(Mandatory)][System.IO.FileInfo]$FontFile)

    $privateFonts = [System.Drawing.Text.PrivateFontCollection]::new()
    try {
        $privateFonts.AddFontFile($FontFile.FullName)
        if ($privateFonts.Families.Count -eq 0) { throw 'The file contains no font family.' }
        return $privateFonts.Families[0].Name
    }
    finally { $privateFonts.Dispose() }
}

function Get-FontRegistryName {
    param(
        [Parameter(Mandatory)][string]$FamilyName,
        [Parameter(Mandatory)][System.IO.FileInfo]$FontFile
    )

    # Family names alone are not unique: weights and styles would overwrite
    # each other. The filename produces a stable, distinct value per face.
    $fontKind = if ($FontFile.Extension -ieq '.otf') { 'OpenType' } else { 'TrueType' }
    return "$FamilyName $($FontFile.BaseName) ($fontKind)"
}

function Test-FontRegistration {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$RegistryName,
        [Parameter(Mandatory)][string]$ExpectedValue
    )

    $property = (Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue).PSObject.Properties[$RegistryName]
    return $null -ne $property -and $property.Value -eq $ExpectedValue
}

function Install-Font {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$FontFile,
        [Parameter(Mandatory)][bool]$IsCurrentUser
    )

    try {
        $familyName = Get-FontFamilyName -FontFile $FontFile
        if ($IsCurrentUser) {
            $fontsDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
            $registryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        }
        else {
            $fontsDirectory = Join-Path $env:WINDIR 'Fonts'
            $registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        }

        $fontPath = Join-Path $fontsDirectory $FontFile.Name
        $registryName = Get-FontRegistryName -FamilyName $familyName -FontFile $FontFile
        # Current-user fonts need an absolute registry path. Windows resolves
        # machine-wide font filenames relative to %WINDIR%\Fonts.
        $registryValue = if ($IsCurrentUser) { $fontPath } else { $FontFile.Name }

        $copied = $false
        if (-not (Test-Path -LiteralPath $fontPath)) {
            New-Item -ItemType Directory -Path $fontsDirectory -Force | Out-Null
            Copy-Item -LiteralPath $FontFile.FullName -Destination $fontPath -ErrorAction Stop
            $copied = $true
        }

        if (-not (Test-FontRegistration -RegistryPath $registryPath -RegistryName $registryName -ExpectedValue $registryValue)) {
            New-ItemProperty -Path $registryPath -Name $registryName -Value $registryValue -PropertyType String -Force | Out-Null
        }

        if ($Native::AddFontResource($fontPath) -eq 0) {
            throw 'Windows could not load the registered font.'
        }

        $state = if ($copied) { 'Installed' } else { 'Registered' }
        Write-Host "OK  ${state}: $($FontFile.Name) [$familyName]"
        return $true
    }
    catch {
        Write-Error "Failed: $($FontFile.Name): $($_.Exception.Message)"
        return $false
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal] $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $CurrentUser -and -not $isAdmin) {
        throw 'Administrator privileges required. Re-run as administrator or use -CurrentUser.'
    }

    $fontFiles = @(Get-ChildItem -LiteralPath $FontFolder -File -Recurse |
            Where-Object { $_.Extension -in '.ttf', '.otf' })
    if ($fontFiles.Count -eq 0) { throw "No .ttf or .otf files found in $FontFolder." }

    Write-Host "Installing $($fontFiles.Count) font files for $(if ($CurrentUser) { 'the current user' } else { 'all users' })..."
    $failed = 0
    foreach ($font in $fontFiles) {
        if (-not (Install-Font -FontFile $font -IsCurrentUser $CurrentUser)) { $failed++ }
    }

    [void]$Native::SendMessage([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($failed -gt 0) { throw "$failed of $($fontFiles.Count) font files failed to install." }
    Write-Host "Installed and registered $($fontFiles.Count) font files. Restart affected applications to refresh their font lists."
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
