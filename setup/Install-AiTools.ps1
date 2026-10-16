<#
Installs AI tools, whatever they are written in: Scoop apps, Bun (Node), uv
(Python), Go and vendor installers. Needs Scoop (with the extras bucket) and the
runtimes from Install-Apps.ps1.

Usage:
  pwsh -File .\setup\Install-AiTools.ps1
  pwsh -File .\setup\Install-AiTools.ps1 -DryRun

Claude accounts are switched with `cswap` (claude-swap); claude-sync syncs
~/.claude through cloud storage. Configure both once with `cswap add` and
`claude-sync init`.
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Packages.ps1')

$failures = [System.Collections.Generic.List[string]]::new()

function Install-Tools([string]$Runtime, [string[]]$Tools, [scriptblock]$Install) {
    if (-not $Tools) { return }
    if (-not (Test-Command $Runtime)) {
        Write-Warn "$Runtime not found; skipping $Runtime tools."
        return
    }
    foreach ($tool in $Tools) {
        Write-Info "$Runtime install $tool"
        if (-not (Invoke-NativeCommand -Description "$Runtime tool $tool" -Action {
                    & $Install $tool
                })) {
            $failures.Add("${Runtime}:$tool")
        }
    }
}

Install-Tools 'scoop' $aiScoopApps {
    param($t)
    scoop prefix $t *>$null
    if ($LASTEXITCODE -eq 0) { scoop update $t } else { scoop install $t }
}
Install-Tools 'bun' $aiBunTools { param($t) bun add --global $t }
Install-Tools 'uv' $aiUvTools { param($t) uv tool install --upgrade $t }
Install-Tools 'go' $aiGoTools { param($t) go install $t }

# Codex: OpenAI's native Windows installer.
Write-Info 'Installing Codex with the native installer'
Invoke-IfNotDryRun {
    try {
        Invoke-WithEnvironment @{ CODEX_NON_INTERACTIVE = '1' } {
            Invoke-RestMethod 'https://chatgpt.com/codex/install.ps1' |
                Invoke-Expression
        }
    }
    catch {
        Write-Warn "Codex installation failed: $_"
        $failures.Add('installer:codex')
    }
}

Write-Info 'Installing OMP'
Invoke-IfNotDryRun {
    try { Invoke-RestMethod 'https://omp.sh/install.ps1' | Invoke-Expression }
    catch {
        Write-Warn "OMP installation failed: $_"
        $failures.Add('installer:omp')
    }
}

if ($failures.Count -gt 0) {
    throw "AI tool installation failed: $($failures -join ', ')"
}

Write-Info 'AI tool installation step complete.'
