<#
Links config files and folders from this repo and the dotfiles checkout
($env:DOTFILES, default ~/dotfiles) into place.

Usage:
  pwsh -File .\setup\Install-Links.ps1
  pwsh -File .\setup\Install-Links.ps1 -Force
  pwsh -File .\setup\Install-Links.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function DotfilesPath([string]$Relative) { Join-Path $DotfilesRoot $Relative }

function Remove-PathSafe([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $true }
    $isLink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if (-not $isLink -and -not $Force) {
        Write-Warn "Existing path is not a link; preserving it. Re-run with -Force to replace: $Path"
        return $false
    }

    Write-Info "Removing existing path: $Path"
    if (-not $DryRun) {
        if ($isLink) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        else { Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop }
    }
    return $true
}

function Ensure-Link([string]$Destination, [string]$Source) {
    try {
        $sourcePath = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).ProviderPath
    }
    catch {
        Write-Warn "Target missing; skip link: $Source"
        return
    }

    if ((Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue) -and -not (Remove-PathSafe $Destination)) { return }

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        Write-Info "Creating parent directory: $parent"
        if (-not $DryRun) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    }

    # Files need Developer Mode (the Registry step) to symlink unelevated. No
    # copy fallback: a copied config silently stops following the repo.
    $type = if (Test-Path -LiteralPath $sourcePath -PathType Container) { 'Junction' } else { 'SymbolicLink' }
    Write-Info "Creating ${type}: $Destination -> $sourcePath"
    if ($DryRun) { return }
    try { New-Item -ItemType $type -Path $Destination -Target $sourcePath -Force | Out-Null }
    catch { Write-Warn "Cannot link $Destination -> ${sourcePath}: $($_.Exception.Message)" }
}

# PowerShell profiles are a one-line stub that dot-sources scripts\Profile.ps1,
# not a link: installers that edit $PROFILE replace the file, which breaks a
# link and leaves a copy that silently stops following the repo. What they
# add lands in the stub instead, and this warns about it.
function Ensure-ProfileStub([string]$Path) {
    $source = WindotsPath 'scripts\Profile.ps1'
    $stub = ". '$source'"
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() })
        if ($lines.Count -eq 1 -and $lines[0] -eq $stub) { return }
        if ($lines -contains $stub) {
            Write-Warn "Profile has lines beyond the windots stub (move them into scripts\Profile.ps1 or drop them): $Path`n  $(($lines | Where-Object { $_ -ne $stub }) -join "`n  ")"
            return
        }
        # A copy of the repo profile is the old drift; anything else is yours.
        if ((Get-FileHash -LiteralPath $Path).Hash -ne (Get-FileHash -LiteralPath $source).Hash) {
            if (-not $Force) {
                Write-Warn "Profile is not the windots stub; preserving it. Re-run with -Force to back it up and replace it: $Path"
                return
            }
            Write-Info "Backing up profile: $Path.bak"
            Invoke-IfNotDryRun { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force }
        }
    }
    Write-Info "Writing profile stub: $Path"
    Invoke-IfNotDryRun {
        if ($item) { Remove-Item -LiteralPath $Path -Force }
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        Set-Content -LiteralPath $Path -Value $stub -Encoding utf8
    }
}

$linkMap = @{
    (Join-Path $HOME '.local\bin\cc-personal.cmd')                                                            = (WindotsPath 'cmd\cc-personal.cmd')
    (Join-Path $HOME '.local\bin\cc-work.cmd')                                                                = (WindotsPath 'cmd\cc-work.cmd')
    (Join-Path $HOME '.local\bin\y.cmd')                                                                      = (WindotsPath 'cmd\y.cmd')
    (Join-Path $env:LOCALAPPDATA 'clink\default_settings')                                                    = (WindotsPath 'config\clink\default_settings')
    (Join-Path $env:LOCALAPPDATA 'clink\_inputrc')                                                            = (WindotsPath 'config\clink\_inputrc')
    (Join-Path $env:LOCALAPPDATA 'clink\starship.lua')                                                        = (WindotsPath 'config\clink\starship.lua')
    (Join-Path $HOME '.config\kanata')                                                                        = (WindotsPath 'config\kanata')
    (Join-Path $HOME '.config\komorebi')                                                                      = (WindotsPath 'shells\komorebi')
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\KeyboardShortcuts\windots-common.yaml')                    = (WindotsPath 'shells\windots-common.yaml')
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\KeyboardShortcuts\windots-native.yaml')                    = (WindotsPath 'shells\native\windots-native.yaml')
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\KeyboardShortcuts\windots-komorebi.yaml')                  = (WindotsPath 'shells\komorebi\windots-komorebi.yaml')
    (Join-Path $HOME '.config\wezterm')                                                                       = (DotfilesPath 'config\wezterm')
    (Join-Path $HOME '.config\yasb')                                                                          = (WindotsPath 'yasb')
    (Join-Path $HOME '.gitconfig')                                                                            = (WindotsPath 'config\git\config')
    (Join-Path $HOME '.ideavimrc')                                                                            = (DotfilesPath 'idea\ideavimrc')
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json') = (WindotsPath 'config\terminal\settings.json')
    (Join-Path $env:LOCALAPPDATA 'direnv')                                                                    = (DotfilesPath 'config\direnv')
    (Join-Path $env:LOCALAPPDATA 'fastfetch')                                                                 = (WindotsPath 'config\fastfetch')
    (Join-Path $env:LOCALAPPDATA 'lazygit')                                                                   = (DotfilesPath 'config\lazygit')
    (Join-Path $HOME '.config\starship.toml')                                                                 = (DotfilesPath 'config\starship.toml')
    (Join-Path $HOME '.config\psmux')                                                                         = (WindotsPath 'psmux')
    (Join-Path $env:APPDATA 'rmux')                                                                           = (WindotsPath 'rmux')
    (Join-Path $HOME '.config\theme')                                                                         = (DotfilesPath 'themes\gruvbox-dark')
    (Join-Path $HOME '.claude\settings.json')                                                                 = (DotfilesPath 'config\agents\claude\settings.json')
    (Join-Path $HOME '.codex\config.toml')                                                                    = (DotfilesPath 'config\agents\codex\config.toml')
    (Join-Path $env:LOCALAPPDATA 'nvim')                                                                      = (DotfilesPath 'config\lazyvim')
    (Join-Path $env:LOCALAPPDATA 'television\config\config.toml')                                             = (DotfilesPath 'config\television\config.toml')
    (Join-Path $env:APPDATA 'gitu')                                                                           = (DotfilesPath 'config\gitu')
    (Join-Path $env:APPDATA 'gitui')                                                                          = (DotfilesPath 'config\gitui')
    (Join-Path $env:APPDATA 'helix')                                                                          = (DotfilesPath 'config\helix')
    (Join-Path $env:APPDATA 'herdr\config.toml')                                                              = (WindotsPath 'config\herdr\config.toml')
    (Join-Path $env:APPDATA 'yazi\config')                                                                    = (DotfilesPath 'config\yazi')
    (Join-Path $env:APPDATA 'Zed')                                                                            = (DotfilesPath 'config\zed')
    (Join-Path $HOME '.config\emacs\doom')                                                                    = (DotfilesPath 'emacs\doom')
    (Join-Path $HOME '.config\emacs\config')                                                                  = (DotfilesPath 'emacs\config')
    (Join-Path $HOME '.config\emacs\funcs')                                                                   = (DotfilesPath 'emacs\funcs')
    (Join-Path $HOME '.config\emacs\local')                                                                   = (DotfilesPath 'emacs\local')
    (Join-Path $HOME '.config\emacs\spacemacs\config')                                                        = (DotfilesPath 'emacs\config')
    (Join-Path $HOME '.config\emacs\spacemacs\funcs')                                                         = (DotfilesPath 'emacs\funcs')
    (Join-Path $HOME '.config\emacs\spacemacs\layers')                                                        = (DotfilesPath 'emacs\spacemacs')
    (Join-Path $HOME '.config\emacs\spacemacs\init.el')                                                       = (DotfilesPath 'emacs\spacemacs\init.el')
}

try {
    foreach ($link in $linkMap.GetEnumerator()) { Ensure-Link $link.Key $link.Value }
    # pwsh 7's and Windows PowerShell 5.1's (herdr's fallback shell).
    $profiles = @($PROFILE.CurrentUserAllHosts, (Join-Path $HOME 'Documents\WindowsPowerShell\profile.ps1')) | Select-Object -Unique
    foreach ($path in $profiles) { Ensure-ProfileStub $path }

    # The psmux plugins psmux\psmux.conf declares, from the psmux-plugins monorepo.
    $plugins = Join-Path $HOME '.psmux\plugins'
    $missing = @('psmux-logging', 'psmux-resurrect') | Where-Object { -not (Test-Path -LiteralPath (Join-Path $plugins $_)) }
    if ($missing) {
        Write-Info "Installing psmux plugins: $missing"
        Invoke-IfNotDryRun {
            $clone = Join-Path ([IO.Path]::GetTempPath()) 'psmux-plugins'
            Remove-Item -LiteralPath $clone -Recurse -Force -ErrorAction SilentlyContinue
            git clone --quiet --depth 1 https://github.com/psmux/psmux-plugins.git $clone
            if ($LASTEXITCODE -ne 0) { throw 'Cloning psmux-plugins failed.' }
            New-Item -ItemType Directory -Path $plugins -Force | Out-Null
            foreach ($name in $missing) { Copy-Item -LiteralPath (Join-Path $clone $name) -Destination $plugins -Recurse }
            Remove-Item -LiteralPath $clone -Recurse -Force
        }
    }
}
catch {
    Write-Error $_
    exit 1
}
