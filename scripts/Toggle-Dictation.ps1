<#
Toggle dictation, the Windows port of ~/dotfiles/scripts/toggle-dictation.sh.
Bound to Win+S in shells\Niri-Common.ahk. First press records the default mic
and remembers the destination pane; second press stops and transcribes with
Whisper on OpenVINO in the background. The transcript goes to that remembered pane, so
focus may move while Whisper works:

  herdr   the focused herdr pane, when the foreground window hosts a herdr client
  tmux    rmux/psmux: the pane passed in DICTATION_TMUX_PANE (bind S in the tmux
          confs), else the active pane of the client the foreground window hosts
  focus   anything else: typed at the focused window with SendInput

Needs ffmpeg, python and uv (Scoop) and the OpenVINO setup,
setup\Install-WhisperOpenVino.ps1. The model runs on the NPU first on battery and the
GPU first on AC (CPU as the last resort). Overrides: DICTATION_DEVICE (a comma list
such as NPU,GPU, tried in order; disables the power switch), DICTATION_MIC (dshow
device name; default is the first one), DICTATION_LANG.

Run with pwsh (7.3+, for correct native argument quoting), no profile:
  pwsh -NoProfile -File Toggle-Dictation.ps1
State and logs: %LOCALAPPDATA%\windots\dictation
#>

param(
    [ValidateSet('Toggle', 'Transcribe', 'Notify')][string]$Action = 'Toggle',
    [string]$Message
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new()
Add-Type -AssemblyName System.Windows.Forms

$state = Join-Path $env:LOCALAPPDATA 'windots\dictation'
$null = New-Item -ItemType Directory -Force $state
$pidFile = "$state\pid"; $targetFile = "$state\target.json"; $raw = "$state\recording.raw"
$log = "$state\whisper.log"; $failed = "$state\last-failed-transcript.txt"
$workerPidFile = "$state\worker.pid"
$whisperOv = Join-Path ($env:DOTFILES ?? (Join-Path $HOME 'dotfiles')) 'scripts\whisper_ov.py'

Add-Type -Namespace Win -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT {
    [FieldOffset(0)] public uint type; [FieldOffset(8)] public ushort vk;
    [FieldOffset(10)] public ushort scan; [FieldOffset(12)] public uint flags; }
[DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int size);
public static void Type(string s) {
    var i = new INPUT[s.Length * 2];
    for (int k = 0; k < s.Length; k++) {
        i[2*k] = new INPUT { type = 1, scan = s[k], flags = 4 };      // KEYEVENTF_UNICODE
        i[2*k+1] = new INPUT { type = 1, scan = s[k], flags = 6 };    // | KEYEVENTF_KEYUP
    }
    SendInput((uint)i.Length, i, 40);
}
'@

# A balloon needs its tray icon alive for a moment, so it lives in its own
# short process and never delays the toggle or the transcription.
if ($Action -eq 'Notify') {
    $icon = [Windows.Forms.NotifyIcon]@{ Icon = [Drawing.SystemIcons]::Information; Visible = $true }
    $icon.ShowBalloonTip(4000, 'Dictation', $Message, 'None')
    Start-Sleep 5
    $icon.Dispose()
    return
}
function Notify($text) {
    Start-Process pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-File', $PSCommandPath, '-Action', 'Notify', '-Message', "`"$($text -replace '"', "'")`""
}

function Get-LiveProcess($file, $name) {
    if (Test-Path $file) { Get-Process -Id ([int](Get-Content $file)) -ErrorAction SilentlyContinue | Where-Object ProcessName -EQ $name }
}

# Where the transcript goes, decided when recording starts. Descendants of the
# foreground window's process say which multiplexer client it hosts.
# ponytail: Windows Terminal is one process for all its windows, so a herdr
# client in another WT window also matches; tell them apart by window title if
# that bites.
function Get-Target {
    if ($env:DICTATION_TMUX_PANE) {
        return @{ kind = 'tmux'; id = $env:DICTATION_TMUX_PANE; bin = $env:DICTATION_TMUX ?? 'rmux' }
    }
    $fg = 0
    $null = [Win.Native]::GetWindowThreadProcessId([Win.Native]::GetForegroundWindow(), [ref]$fg)
    $procs = Get-CimInstance Win32_Process
    $tree = @($fg); do {
        $n = $tree.Count
        $tree = @($tree + $procs.Where({ $_.ParentProcessId -in $tree }).ProcessId | Select-Object -Unique)
    } while ($tree.Count -gt $n)
    $clients = $procs.Where({ $_.ProcessId -in $tree -and $_.CommandLine -notmatch '\b(server|daemon)\b' })

    if ($clients.Where({ $_.Name -eq 'herdr.exe' })) {
        # Exactly one focused pane, or the target is ambiguous.
        $focused = @((herdr pane list | ConvertFrom-Json).result.panes.Where({ $_.focused }).pane_id)
        if ($focused.Count -eq 1) { return @{ kind = 'herdr'; id = $focused[0] } }
    }
    foreach ($bin in 'rmux', 'psmux') {
        if ($clients.Where({ $_.Name -eq "$bin.exe" })) {
            $pane = @(& $bin list-clients -F '#{pane_id}')
            if ($pane.Count -eq 1) { return @{ kind = 'tmux'; id = $pane[0]; bin = $bin } }
        }
    }
    @{ kind = 'focus' }
}

function Send-ToTarget($t, $text) {
    switch ($t.kind) {
        'herdr' { $null = herdr pane send-text $t.id $text; $LASTEXITCODE -eq 0 }
        'tmux' {
            # A named buffer leaves the default tmux paste buffer alone.
            $text | & $t.bin load-buffer -b dictation-target -
            if ($LASTEXITCODE) { return $false }
            & $t.bin paste-buffer -d -b dictation-target -t $t.id
            $LASTEXITCODE -eq 0
        }
        default { [Win.Native]::Type($text); $true }
    }
}

# Whisper large-v3-turbo on OpenVINO (setup\Install-WhisperOpenVino.ps1) through
# dotfiles' whisper_ov.py, which keeps the pipeline loaded in a background server
# (started through uv, which caches its environment): a warm NPU or GPU transcribes
# a few seconds of speech in well under a second. It reads DICTATION_DEVICE and
# DICTATION_LANG itself.

# Device preference by power: the NPU first on battery (lowest power draw), the GPU
# first on AC (faster). An explicit DICTATION_DEVICE wins. The server fixes its
# devices when it starts, so a change of preference restarts it, and the next
# transcription reloads the model (1-3 s) on the other device.
function Use-PowerDevice {
    # A value this function set earlier (children inherit it) is not an override.
    $spec = $env:DICTATION_DEVICE
    if (-not $spec -or $env:DICTATION_DEVICE_DERIVED) {
        $spec = [Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Offline' ? 'NPU,GPU' : 'GPU,NPU'
        $env:DICTATION_DEVICE_DERIVED = '1'
    }
    $last = "$state\device"
    if ((Test-Path $last) -and (Get-Content $last) -ne $spec) {
        python $whisperOv --stop
        foreach ($i in 1..50) {
            # until the old server has let go of the port
            try { [Net.Sockets.TcpClient]::new('127.0.0.1', [int]($env:WHISPER_OV_PORT ?? 47600)).Dispose() } catch { break }
            Start-Sleep -Milliseconds 100
        }
    }
    Set-Content $last $spec
    $env:DICTATION_DEVICE = $spec
}

function Get-Transcript {
    Use-PowerDevice
    $out = python $whisperOv $raw 2>>$log
    if ($LASTEXITCODE) { throw "Transcription failed (see $log)" }
    $out -join ' '
}

function Invoke-Transcribe {
    Set-Content $workerPidFile $PID
    try {
        $t = Get-Content $targetFile -Raw | ConvertFrom-Json
        Notify 'Transcribing...'
        Set-Content $log ''
        # Drop bracketed non-speech tags such as [BLANK_AUDIO], then trim.
        $text = ((Get-Transcript) -replace '\[[A-Z_ ]+\]' -replace '\s+', ' ' -replace '^[^\p{L}\p{N}]+').Trim()
        if (-not $text) { Notify 'No speech detected'; return }

        if (Send-ToTarget $t $text) {
            Notify ($t.kind -eq 'focus' ? "Typed: $text" : "Transcript ready in $($t.kind) pane $($t.id) - check it and press Enter")
        }
        else {
            Set-Content $failed $text; Set-Clipboard $text
            throw "Target unavailable; transcript copied and saved in $failed"
        }
    }
    catch { Add-Content $log $_.Exception.Message; Notify $_.Exception.Message }
    finally { Remove-Item $workerPidFile, $targetFile, $raw -ErrorAction SilentlyContinue }
}

if ($Action -eq 'Transcribe') { return Invoke-Transcribe }

# Toggle. An exclusive lock file makes a key repeat or double press a no-op
# instead of a race on the pid and audio files.
try { $lock = [IO.File]::Open("$state\lock", 'OpenOrCreate', 'ReadWrite', 'None') } catch { return }
try {
    if ($rec = Get-LiveProcess $pidFile 'ffmpeg') {
        Remove-Item $pidFile
        # ffmpeg writes raw PCM with -flush_packets, so killing it loses about a
        # packet; Transcribe wraps the file in a WAV. Scoop's ffmpeg is a shim
        # that spawns the real one, so kill the tree. The pause lets the mic's
        # last buffer arrive.
        Start-Sleep -Milliseconds 300
        taskkill /T /F /PID $rec.Id >$null
        $rec.WaitForExit(2000) | Out-Null
        Start-Process pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-File', $PSCommandPath, '-Action', 'Transcribe'
    }
    elseif (Get-LiveProcess $workerPidFile 'pwsh') {
        Notify 'Still transcribing the previous recording'
    }
    else {
        Get-Target | ConvertTo-Json | Set-Content $targetFile
        # ponytail: the first dshow device is usually the default mic; set
        # DICTATION_MIC when it isn't. Its ASCII "Alternative name" line stands in
        # for the friendly name, whose non-ASCII characters (Intel(R)) get mangled.
        $mic = $env:DICTATION_MIC
        if (-not $mic) {
            $devices = @(ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | ForEach-Object ToString)
            $mic = $devices[($devices.IndexOf($devices.Where({ $_ -match '\(audio\)' }, 'First')[0]) + 1)] -replace '^.*?"(.*)"$', '$1'
        }
        $ffmpeg = Start-Process ffmpeg -WindowStyle Hidden -PassThru -RedirectStandardError $log -ArgumentList `
            '-y', '-f', 'dshow', '-i', "`"audio=$mic`"", '-ar', '16000', '-ac', '1', '-flush_packets', '1', '-f', 's16le', $raw
        Start-Sleep -Milliseconds 400
        if ($ffmpeg.HasExited) { Remove-Item $targetFile; throw "Failed to start recording (see $log)" }
        Set-Content $pidFile $ffmpeg.Id
        # Load the model while you talk (a no-op when the server is already up).
        Use-PowerDevice
        Start-Process python -WindowStyle Hidden -ArgumentList "`"$whisperOv`"", '--start'
        Notify 'Recording... press the hotkey again to stop'
    }
}
catch { Notify $_.Exception.Message } finally { $lock.Dispose() }
