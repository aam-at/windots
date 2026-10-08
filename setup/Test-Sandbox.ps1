<#
Runs Bootstrap.ps1 + Setup.ps1 in a throwaway Windows Sandbox against this
working tree (uncommitted changes included), as a fresh-machine smoke test.
The repo is mapped read-only and copied to ~/windots inside the sandbox;
the transcript lands in .sandbox/setup.log here.

Usage:
  pwsh -File .\setup\Test-Sandbox.ps1
#>

[CmdletBinding()]
param(
    # Internal: set by the sandbox logon command.
    [switch]$InSandbox
)

$ErrorActionPreference = 'Stop'
$sandboxRepo = 'C:\windots-src'
$sandboxLogs = 'C:\windots-logs'

if ($InSandbox) {
    Start-Transcript -Path (Join-Path $sandboxLogs 'setup.log') -Force | Out-Null
    try {
        # The sandbox user is an administrator, which get.scoop.sh refuses
        # without -RunAsAdmin; Bootstrap.ps1 then sees Scoop and moves on.
        Invoke-Expression "& {$(Invoke-RestMethod https://get.scoop.sh)} -RunAsAdmin"
        $env:PATH = "$HOME\scoop\shims;$env:PATH"
        scoop install git
        # Bootstrap would clone origin/master; copy the working tree instead.
        robocopy $sandboxRepo "$HOME\windots" /E /NFL /NDL /NJH /NJS /XD .sandbox |
            Out-Null
        # Piping redirects the pwsh child's stdout so the transcript sees it;
        # stderr stays on the console (redirected, 5.1 makes it terminating).
        & "$HOME\windots\setup\Bootstrap.ps1" | Out-Host
    }
    catch { Write-Host "[SANDBOX] $_" -ForegroundColor Red }
    finally {
        Stop-Transcript | Out-Null
        Set-Content -Path (Join-Path $sandboxLogs 'done') -Value (Get-Date)
    }
    return
}

$repo = Split-Path $PSScriptRoot -Parent
$logs = Join-Path $repo '.sandbox'
Remove-Item -Recurse -Force $logs -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $logs | Out-Null

$command = 'powershell -NoProfile -ExecutionPolicy Bypass ' +
"-File $sandboxRepo\setup\Test-Sandbox.ps1 -InSandbox"
$wsb = Join-Path $logs 'windots.wsb'
@"
<Configuration>
  <MemoryInMB>8192</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$repo</HostFolder>
      <SandboxFolder>$sandboxRepo</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$logs</HostFolder>
      <SandboxFolder>$sandboxLogs</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>$command</Command></LogonCommand>
</Configuration>
"@ | Set-Content -Path $wsb -Encoding UTF8
Start-Process $wsb
Write-Host "Sandbox started; follow $logs\setup.log ('done' appears when finished)."
