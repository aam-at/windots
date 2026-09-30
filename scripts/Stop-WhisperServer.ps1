# Stops dotfiles' whisper_ov.py server and waits until it has let go of its port, so
# whatever starts next gets a fresh server instead of connecting to the dying one.
# Dot-sourced by Toggle-Dictation.ps1, Benchmark-Whisper.ps1 and Install-WhisperOpenVino.ps1.
function Stop-WhisperServer([string]$Tool) {
    python $Tool --stop
    foreach ($i in 1..50) {
        try { [Net.Sockets.TcpClient]::new('127.0.0.1', [int]($env:WHISPER_OV_PORT ?? 47600)).Dispose() } catch { return }
        Start-Sleep -Milliseconds 100
    }
}
