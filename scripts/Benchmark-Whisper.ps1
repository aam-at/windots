<#
Times dictation on each OpenVINO device (NPU, GPU, CPU) through dotfiles'
whisper_ov.py, the way Toggle-Dictation.ps1 runs it (setup\Install-WhisperOpenVino.ps1
sets it up). For each device it stops the server, starts one on that device, and
times the first request (server start, model load and one transcription) and then
-Runs warm ones. Caches must already be warm, or the NPU row measures the compile.
A device this machine lacks is reported under the device it fell back to.

Usage:
  pwsh -File .\scripts\Benchmark-Whisper.ps1                       # a spoken sample (Windows TTS)
  pwsh -File .\scripts\Benchmark-Whisper.ps1 -Audio my.wav -Runs 5
#>

[CmdletBinding()]
param(
    [string]$Audio,
    [int]$Runs = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$work = Join-Path ([IO.Path]::GetTempPath()) 'whisper-bench'
$null = New-Item -ItemType Directory -Force $work
if (-not $Audio) {
    $Audio = Join-Path $work 'sample.wav'
    Add-Type -AssemblyName System.Speech
    $voice = [Speech.Synthesis.SpeechSynthesizer]::new()
    $voice.SetOutputToWaveFile($Audio)
    $voice.Speak('Please run the unit tests and then commit the changes.')
    $voice.Dispose()
}
$raw = Join-Path $work 'sample.raw'
ffmpeg -y -loglevel error -i $Audio -f s16le -ar 16000 -ac 1 $raw
if ($LASTEXITCODE) { throw "ffmpeg could not read $Audio" }

$tool = Join-Path ($env:DOTFILES ?? (Join-Path $HOME 'dotfiles')) 'scripts\whisper_ov.py'
. "$PSScriptRoot\Stop-WhisperServer.ps1"

# One request: wall seconds, the device that served it, its generate time, the text.
function Invoke-Request {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $out = python $tool $raw 2>&1 | ForEach-Object ToString
    $info = $out | Where-Object { $_ -match '^device=(\w+) audio=\S+ generate=([\d.]+)s' }
    if ($LASTEXITCODE -or -not $info) { throw "request failed: $($out -join ' ')" }
    [pscustomobject]@{
        Wall = $watch.Elapsed.TotalSeconds; Device = $Matches[1]; Generate = [double]$Matches[2]
        Text = ($out | Where-Object { $_ -notmatch '^device=' }) -join ' '
    }
}

$saved = $env:DICTATION_DEVICE
try {
    $rows = foreach ($device in 'NPU', 'GPU', 'CPU') {
        Stop-WhisperServer $tool
        $env:DICTATION_DEVICE = $device
        $first = Invoke-Request
        $warm = 1..$Runs | ForEach-Object { Invoke-Request }
        [pscustomobject]@{
            Device              = if ($first.Device -ne $device) { "$device (ran on $($first.Device))" } else { $device }
            'First request (s)' = [math]::Round($first.Wall, 2)
            'Warm request (s)'  = [math]::Round(($warm | Measure-Object Wall -Average).Average, 2)
            'Warm generate (s)' = [math]::Round(($warm | Measure-Object Generate -Average).Average, 2)
            Text                = $first.Text
        }
    }
}
finally {
    Stop-WhisperServer $tool
    if ($null -ne $saved) { $env:DICTATION_DEVICE = $saved } else { Remove-Item Env:DICTATION_DEVICE -ErrorAction SilentlyContinue }
}
$rows | Format-Table -AutoSize -Wrap
