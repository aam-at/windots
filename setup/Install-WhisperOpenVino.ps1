<#
Sets up Whisper on OpenVINO for scripts\Toggle-Dictation.ps1 through dotfiles'
scripts\whisper_ov.py, which `uv run` gives its own cached Python environment
(no venv to manage): downloads that environment (a few hundred MB) and the
pre-converted large-v3-turbo int8 model from the OpenVINO collection on Hugging
Face (about 1 GB), then warms the compiled-model cache for each -Device by
starting the server on it once.

The first NPU compile takes several minutes (about 6 on a Core Ultra X7 358H);
later starts load the cache in ~2 s. Warming here keeps that wait out of the
first dictation. Dictation uses the NPU on battery and the GPU on AC, so both
are warmed by default.

Usage:
  pwsh -File .\setup\Install-WhisperOpenVino.ps1                 # NPU and GPU
  pwsh -File .\setup\Install-WhisperOpenVino.ps1 -Device NPU     # warm just the NPU

Needs python and Scoop's uv (setup\Install-Apps.ps1 installs both) and, for NPU/GPU,
Intel's driver (Windows Update ships both).
#>

[CmdletBinding()]
param([ValidateSet('NPU', 'GPU', 'CPU')][string[]]$Device = @('NPU', 'GPU'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
$tool = Join-Path $DotfilesRoot 'scripts\whisper_ov.py'
. (Join-Path $PSScriptRoot '..\scripts\Stop-WhisperServer.ps1')

uv run --quiet $tool --download
if ($LASTEXITCODE) { throw 'model download failed' }

# A recording quiet enough to be skipped still makes the server load the model, so
# one second of silence compiles and caches it without transcribing anything.
$silence = Join-Path ([IO.Path]::GetTempPath()) 'whisper-ov-warmup.raw'
[IO.File]::WriteAllBytes($silence, [byte[]]::new(32000))
try {
    foreach ($d in $Device) {
        Write-Host "Warming the $d cache (the first NPU compile takes minutes)..."
        Stop-WhisperServer $tool
        $env:DICTATION_DEVICE = $d
        python $tool $silence
        if ($LASTEXITCODE) { throw "warm-up on $d failed (see $env:LOCALAPPDATA\windots\dictation\whisper-server.log)" }
    }
}
finally {
    Stop-WhisperServer $tool
    Remove-Item Env:DICTATION_DEVICE -ErrorAction SilentlyContinue
    Remove-Item $silence -ErrorAction SilentlyContinue
}
