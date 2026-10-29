# Package lists read by setup/Install-Apps.ps1, setup/Install-AiTools.ps1 and
# scripts/Update-Apps.ps1. Add a package here; every script picks it up.

# Winget, Scoop, Bun and uv packages for the base install.
# Winget apps (install per-ID for clearer output and retries)
$wingetApps = @(
    'Dropbox.Dropbox', 'FSFhu.Hunspell', 'Google.GoogleDrive', 'Helvesec.RMUX',
    'HTTPie.HTTPie', 'IJHack.QtPass', 'LGUG2Z.masir', 'lin-ycv.EverythingCmdPal',
    'marlocarlo.psmux', 'Microsoft.PowerShell', 'Microsoft.PowerToys',
    'Microsoft.VisualStudio.BuildTools', 'Microsoft.VisualStudioCode',
    'Microsoft.WindowsTerminal', 'Tailscale.Tailscale', 'VideoLAN.VLC', 'WinFsp.WinFsp'
)
# Installer arguments for packages that need more than the default install.
$wingetOverrides = @{
    'Microsoft.VisualStudio.BuildTools' = @(
        '--override'
        ('--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools ' +
        '--includeRecommended')
    )
}

$scoopBuckets = @('extras')
$scoopAppsMain = @(
    '7zip', 'ag', 'aspell', 'atuin', 'bat', 'bitwarden-cli',
    'bottom', 'broot', 'btop', 'bun', 'busybox', 'clink', 'clink-completions', 'cmake',
    'curl', 'delta', 'direnv', 'dust', 'everything-cli', 'eza', 'far', 'fastfetch',
    'fd', 'ffmpeg', 'fzf', 'gcc', 'gdu', 'gh', 'ghostscript', 'git', 'git-crypt',
    'gitui', 'glow', 'gnupg', 'go', 'gping', 'helix', 'hledger', 'imagemagick', 'jq',
    'lazygit', 'less', 'lsd', 'lua', 'luarocks', 'mosh-client', 'msys2', 'navi',
    'neovim', 'nodejs-lts', 'ouch', 'pandoc', 'pkgconf', 'poppler', 'prek', 'procs',
    'pwsh', 'python', 'rclone', 'ripgrep', 'rtk', 'rustup', 'sd', 'sed', 'shellcheck',
    'shfmt', 'sqlite', 'starship', 'sysinternals', 'tealdeer', 'tectonic', 'texlab',
    'tree-sitter', 'uv', 'vale', 'vim', 'watchexec', 'wget', 'xh', 'yazi', 'yt-dlp',
    'zellij', 'zoxide'
)
$scoopAppsExtras = @(
    'activitywatch', 'antigravity-ide', 'autohotkey', 'bitwarden', 'everything',
    'everything-powertoys', 'gitu', 'googlechrome', 'gpg4win', 'handbrake', 'herdr',
    'kanata', 'komorebi', 'mupdf', 'notepadplusplus', 'quarto', 'television',
    'thorium-reader', 'totalcommander', 'wezterm', 'winrar', 'yasb', 'zed'
)
$uvTools = @('tmuxp')
$bunApps = @(
    '@github/copilot-language-server', '@marp-team/marp-cli', 'bibtex-tidy',
    'dockerfile-language-server-nodejs', 'js-beautify', 'prettier', 'typescript',
    'typescript-formatter', 'typescript-language-server', 'vim-language-server',
    'vscode-json-languageserver', 'yaml-language-server'
)

# PowerShell modules from PSGallery.
$psModules = @(
    'CompletionPredictor',
    'PSScriptAnalyzer'
)

# AI tools (setup/Install-AiTools.ps1).
$aiScoopApps = @('antigravity-cli', 'chatgpt', 'claude')
$aiBunTools = @(
    '@anthropic-ai/claude-code@latest', '@github/copilot', '@google/gemini-cli@latest',
    '@tawandotorg/claude-sync', 'oh-my-pi', 'opencode-ai', 'pi-coding-agent'
)
$aiUvTools = @('claude-swap')
$aiGoTools = @()

# Scoop apps closed without asking when their update is blocked, then started again
# right after, with Arguments if set. Exe is relative to the app's current folder.
$autoStopApps = @(
    @{
        ScoopApp = 'googlechrome'
        Exe = 'chrome.exe'
        Arguments = '--restore-last-session'
    }
    @{ ScoopApp = 'chatgpt'; Exe = 'ChatGPT.exe' }
)

# Other running apps Scoop can't replace. Each is stopped only after asking, when its
# update is blocked, and started again right after. Shortcuts are the Startup .lnk
# names that start it; a mode only has the ones it uses (NativeDesktop or KomorebiAHK).
$liveApps = @(
    @{
        App = 'AutoHotkey'
        ScoopApp = 'autohotkey'
        Processes = 'AutoHotkey64', 'AutoHotkeyUX', 'autohotkey'
        Shortcuts = 'NativeDesktop', 'KomorebiAHK'
        RestartOnCrash = $true
    }
    @{
        App = 'YASB'
        ScoopApp = 'yasb'
        Processes = 'yasb'
        Shortcuts = 'YASB'
        RestartOnCrash = $true
    }
    @{
        App = 'ActivityWatch'
        ScoopApp = 'activitywatch'
        Processes = 'aw-server'
        Shortcuts = 'ActivityWatch'
    }
)
