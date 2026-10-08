<#
Dictation's transcribe-and-deliver half, the Windows port of
~/dotfiles/scripts/toggle-dictation.sh. Win+S runs yasb\dictation\dictate.exe, which
records the mic (a native recorder: the chime follows the press by ~0.2 s), and
starts this script twice:

  -Action Prepare      when recording starts: finds the destination pane, picks the
                       device and loads the model while you talk.
  -Action Transcribe   when recording stops: transcribes with Whisper on OpenVINO
                       and delivers the text. The destination was fixed at the
                       start, so focus may move while Whisper works:

  herdr   the focused herdr pane, when the foreground window hosts a herdr client
  tmux    rmux/psmux: the pane passed in DICTATION_TMUX_PANE (bind S in the tmux
          confs), else the active pane of the client the foreground window hosts
  focus   anything else: typed at the focused window with SendInput

Needs python and uv (Scoop), yasb\dictation\dictate.exe (built by setup) and the
OpenVINO setup, setup\Install-WhisperOpenVino.ps1. The model runs on the NPU first on
battery and the GPU first on AC (CPU as the last resort). Overrides: DICTATION_DEVICE
(a comma list such as NPU,GPU, tried in order; disables the power switch),
DICTATION_LANG.
The microphone is chosen from the right-click menu of the bar's dictation widget.

Run with pwsh (7.3+, for correct native argument quoting), no profile:
  pwsh -NoProfile -File Toggle-Dictation.ps1
State and logs: %LOCALAPPDATA%\windots\dictation
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'Transcribe', 'Notify')]
    [string]$Action,
    [string]$Message,
    # The window that had focus at the key press, from the hotkey; Prepare starts a
    # moment later, which is long enough for focus to have moved.
    [int]$ForegroundPid
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Text.UTF8Encoding]::new()
Add-Type -AssemblyName System.Windows.Forms

$state = Join-Path $env:LOCALAPPDATA 'windots\dictation'
$null = New-Item -ItemType Directory -Force $state
$targetFile = "$state\target.json"; $raw = "$state\recording.raw"
$log = "$state\whisper.log"; $failed = "$state\last-failed-transcript.txt"
. "$PSScriptRoot\..\setup\Common.ps1"
$whisperOv = Join-Path $DotfilesRoot 'scripts\whisper_ov.py'
. "$PSScriptRoot\Stop-WhisperServer.ps1"

# A balloon needs its tray icon alive for a moment, so it lives in its own
# short process and never delays the toggle or the transcription.
if ($Action -eq 'Notify') {
    $icon = [Windows.Forms.NotifyIcon]@{
        Icon = [Drawing.SystemIcons]::Information
        Visible = $true
    }
    $icon.ShowBalloonTip(4000, 'Dictation', $Message, 'None')
    Start-Sleep 5
    $icon.Dispose()
    return
}
function Notify($text) {
    Start-Process pwsh -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-File', $PSCommandPath, '-Action', 'Notify'
        '-Message', "`"$($text -replace '"', "'")`""
    )
}

# The window and typing helpers take about 0.3 s to compile, so they wait until the
# target lookup or the typing needs them: recording must not wait, and a balloon
# process never needs them.
function Initialize-Native {
    if ('Win.Native' -as [type]) { return }
    Add-Type -Namespace Win -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT {
    [FieldOffset(0)] public uint type; [FieldOffset(8)] public ushort vk;
    [FieldOffset(10)] public ushort scan; [FieldOffset(12)] public uint flags; }
[DllImport("user32.dll")]
public static extern uint SendInput(uint n, INPUT[] i, int size);
public static void Type(string s) {
    var i = new INPUT[s.Length * 2];
    for (int k = 0; k < s.Length; k++) {
        // KEYEVENTF_UNICODE
        i[2*k] = new INPUT { type = 1, scan = s[k], flags = 4 };
        // | KEYEVENTF_KEYUP
        i[2*k+1] = new INPUT { type = 1, scan = s[k], flags = 6 };
    }
    SendInput((uint)i.Length, i, 40);
}
'@
}

# Where the transcript goes, decided when recording starts. Descendants of the
# foreground window's process say which multiplexer client it hosts.
# ponytail: Windows Terminal is one process for all its windows, so a herdr
# client in another WT window also matches; tell them apart by window title if
# that bites.
# Runs an rmux/psmux command and returns its output lines, or $null if it fails or
# takes over 3 s. rmux answers nothing while it loads its config (minutes), and
# waiting on it would hang Prepare, or strand the worker.
function Invoke-Tmux([string]$Bin, [string[]]$Arguments, [string]$Text) {
    $out = New-TemporaryFile
    $in = if ($null -ne $Text) { New-TemporaryFile }
    try {
        $redirect = @{ RedirectStandardOutput = $out }
        if ($in) {
            [IO.File]::WriteAllText($in, $Text, [Text.UTF8Encoding]::new())
            $redirect.RedirectStandardInput = $in
        }
        $p = Start-Process $Bin $Arguments -NoNewWindow -PassThru @redirect
        if (-not $p.WaitForExit(3000)) { $p.Kill($true); return $null }
        if ($p.ExitCode) { return $null }
        , @(Get-Content $out)
    }
    finally { Remove-Item $out, $in -ErrorAction SilentlyContinue }
}

function Get-Target {
    if ($env:DICTATION_TMUX_PANE) {
        return @{
            kind = 'tmux'
            id = $env:DICTATION_TMUX_PANE
            bin = $env:DICTATION_TMUX ?? 'rmux'
        }
    }
    $fg = $ForegroundPid
    Initialize-Native
    if (-not $fg) {
        $null = [Win.Native]::GetWindowThreadProcessId(
            [Win.Native]::GetForegroundWindow(), [ref]$fg)
    }
    $procs = Get-CimInstance Win32_Process
    $tree = @($fg); do {
        $n = $tree.Count
        $tree = @($tree +
            $procs.Where({ $_.ParentProcessId -in $tree }).ProcessId |
                Select-Object -Unique)
    } while ($tree.Count -gt $n)
    $clients = $procs.Where({
            $_.ProcessId -in $tree -and $_.CommandLine -notmatch '\b(server|daemon)\b'
        })

    if ($clients.Where({ $_.Name -eq 'herdr.exe' })) {
        # Exactly one focused pane, or the target is ambiguous.
        $herdrPanes = (herdr pane list | ConvertFrom-Json).result.panes
        $focused = @($herdrPanes.Where({ $_.focused }).pane_id)
        if ($focused.Count -eq 1) { return @{ kind = 'herdr'; id = $focused[0] } }
    }
    foreach ($bin in 'rmux', 'psmux') {
        if ($clients.Where({ $_.Name -eq "$bin.exe" })) {
            $pane = Invoke-Tmux $bin 'list-clients', '-F', '#{pane_id}'
            if ($pane -and $pane.Count -eq 1) {
                return @{ kind = 'tmux'; id = $pane[0]; bin = $bin }
            }
        }
    }
    @{ kind = 'focus' }
}

function Send-ToTarget($t, $text) {
    switch ($t.kind) {
        'herdr' { $null = herdr pane send-text $t.id $text; $LASTEXITCODE -eq 0 }
        'tmux' {
            # A named buffer leaves the default tmux paste buffer alone.
            $load = 'load-buffer', '-b', 'dictation-target', '-'
            $paste = 'paste-buffer', '-d', '-b', 'dictation-target', '-t', $t.id
            $null -ne (Invoke-Tmux $t.bin $load $text) -and
            $null -ne (Invoke-Tmux $t.bin $paste)
        }
        default { Initialize-Native; [Win.Native]::Type($text); $true }
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
    $spec = $env:DICTATION_DEVICE
    if (-not $spec) {
        $power = [Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
        $spec = $power -eq 'Offline' ? 'NPU,GPU' : 'GPU,NPU'
    }
    $last = "$state\device"
    if ((Test-Path $last) -and (Get-Content $last) -ne $spec) {
        Stop-WhisperServer $whisperOv
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
    try {
        # Prepare writes the target about a second after recording starts; wait if you
        # stopped sooner than that, and deliver to the focused window if it never comes.
        foreach ($i in 1..50) {
            if (Test-Path $targetFile) { break }
            Start-Sleep -Milliseconds 100
        }
        $t = if (Test-Path $targetFile) {
            Get-Content $targetFile -Raw | ConvertFrom-Json
        }
        else { @{ kind = 'focus' } }
        Set-Content $log ''
        # Drop bracketed non-speech tags such as [BLANK_AUDIO], then trim.
        $text = (Get-Transcript) -replace '\[[A-Z_ ]+\]' -replace '\s+', ' '
        $text = ($text -replace '^[^\p{L}\p{N}]+').Trim()
        if (-not $text) { Notify 'No speech detected'; return }

        # No balloon on success: a balloon takes a second to appear, long after the text
        # has, and the bar's dictation widget already shows the transcribing state.
        if (-not (Send-ToTarget $t $text)) {
            Set-Content $failed $text; Set-Clipboard $text
            throw "Target unavailable; transcript copied and saved in $failed"
        }
    }
    catch { Add-Content $log $_.Exception.Message; Notify $_.Exception.Message }
    finally { Remove-Item $targetFile, $raw -ErrorAction SilentlyContinue }
}

if ($Action -eq 'Transcribe') { return Invoke-Transcribe }

# Prepare: dictate.exe runs this when recording starts. The destination is fixed now,
# and the model loads while you talk (a no-op when the server is already up).
try {
    Get-Target | ConvertTo-Json | Set-Content $targetFile
    Use-PowerDevice
    Start-Process python -WindowStyle Hidden -ArgumentList "`"$whisperOv`"", '--start'
}
catch { Notify $_.Exception.Message }
