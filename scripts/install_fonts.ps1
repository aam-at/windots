param(
    [Parameter(Mandatory = $true)]
    [string]$FontFolder,

    [Parameter(Mandatory = $false)]
    [switch]$CurrentUser
)

# Load .NET drawing assembly
Add-Type -AssemblyName System.Drawing

# ────────────────────────────────────────────────
# Define NativeMethods with a unique namespace
# ────────────────────────────────────────────────
$namespace = "FontInstaller_" + [Guid]::NewGuid().ToString("N")

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

# Create a type reference dynamically
$Native = ("{0}.NativeMethods" -f $namespace) -as [type]

# ────────────────────────────────────────────────
# Font validation function
# ────────────────────────────────────────────────
function Test-FontFile {
    param([System.IO.FileInfo]$FontFile)

    try {
        $privateFont = New-Object System.Drawing.Text.PrivateFontCollection
        $privateFont.AddFontFile($FontFile.FullName)
        $fontName = $privateFont.Families[0].Name
        $privateFont.Dispose()
        return $true, $fontName
    } catch {
        return $false, $_.Exception.Message
    }
}

# ────────────────────────────────────────────────
# Font installation function
# ────────────────────────────────────────────────
function Install-Font {
    param(
        [System.IO.FileInfo]$FontFile,
        [bool]$IsCurrentUser,
        [type]$Native
    )

    $isValid, $result = Test-FontFile $FontFile
    if (-not $isValid) {
        Write-Warning "Invalid font file: $($FontFile.Name)"
        Write-Verbose "Error: $result"
        return
    }

    $fontName = $result

    try {
        if ($IsCurrentUser) {
            $fontPath = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts\$($FontFile.Name)"
            $registryPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
        } else {
            $fontPath = Join-Path $env:WINDIR "Fonts\$($FontFile.Name)"
            $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
        }

        if (Test-Path $fontPath) {
            Write-Host "Font already installed: $($FontFile.Name)"
            return
        }

        Copy-Item -Path $FontFile.FullName -Destination $fontPath -Force -ErrorAction Stop

        $registryValue = if ($IsCurrentUser) { $FontFile.Name } else { $fontPath }
        New-ItemProperty -Path $registryPath -Name $fontName -Value $registryValue -PropertyType String -Force -ErrorAction Stop | Out-Null

        if (-not $IsCurrentUser) {
            $result = $Native::AddFontResource($fontPath)
            if ($result -eq 0) {
                throw "AddFontResource failed for $fontPath"
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_FONTCHANGE = 0x001D
            $Native::SendMessage($HWND_BROADCAST, $WM_FONTCHANGE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }

        Write-Host "✅ Installed: $($FontFile.Name) [$fontName]"
    } catch {
        Write-Host "❌ Failed: $($FontFile.Name)"
        Write-Host "   Error: $($_.Exception.Message)"
    }
}

# ────────────────────────────────────────────────
# Main script logic
# ────────────────────────────────────────────────
try {
    # Check privileges
    if (-not $CurrentUser) {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).
            IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            throw "Administrator privileges required. Re-run as admin or use -CurrentUser."
        }
    }

    # Find font files
    $fontFiles = Get-ChildItem -Path $FontFolder -Include *.ttf, *.otf -Recurse -ErrorAction Stop
    if (-not $fontFiles) {
        Write-Host "No fonts found in $FontFolder."
        exit
    }

    $logFile = Join-Path $PSScriptRoot "FontInstallation.log"
    Start-Transcript -Path $logFile -Append | Out-Null

    Write-Host "─────────────────────────────────────────────"
    Write-Host "🖋️  Installing fonts from: $FontFolder"
    Write-Host "📦 Total fonts found: $($fontFiles.Count)"
    Write-Host "👤 Target: $(if ($CurrentUser) {'Current User'} else {'All Users'})"
    Write-Host "─────────────────────────────────────────────"

    $counter = 0
    foreach ($font in $fontFiles) {
        $counter++
        Write-Progress -Activity "Installing fonts..." `
                       -Status "$counter / $($fontFiles.Count): $($font.Name)" `
                       -PercentComplete (($counter / $fontFiles.Count) * 100)
        Install-Font $font $CurrentUser $Native
    }

    Write-Host "`n✅ Font installation completed successfully."
    Write-Host "📝 Log saved to: $logFile"
} catch {
    Write-Host "⚠️ Error: $($_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
