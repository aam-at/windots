<#
 PowerShell profile for windots, kept close to the fish setup in
 ~/dotfiles/config/fish (aliases from ~/dotfiles/general/aliases, fzf
 pickers, zoxide, direnv, starship) and to kitty's shell
 integration (prompt marks, cwd reporting for new tabs and splits).
 Shared by pwsh 7 and Windows PowerShell 5.1 (herdr's fallback shell).
#>

# Persisted by setup\Configure-Env.ps1; defaults for a machine not set up yet.
if (-not $env:DOTFILES) { $env:DOTFILES = "$HOME\dotfiles" }
if (-not $env:WINDOTS) { $env:WINDOTS = "$HOME\windots" }
$ENV:_ZO_DATA_DIR = "$HOME\OneDrive\Documents\PowerShell"
$ENV:STARSHIP_CONFIG = "$env:DOTFILES\config\starship.toml"
$ENV:STARSHIP_LOG = 'error'
$ENV:CLAUDE_CODE_USE_POWERSHELL_TOOL = '1'

# fish: EDITOR is an emacsclient, ALTERNATE_EDITOR nvim. Emacs-Daemon.ps1
# names each daemon's socket after its profile and records the default one.
$emacsDefaultProfile = Join-Path $(if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { "$HOME\.local\state" }) 'emacs\default-profile'
if (-not $env:EMACS_SOCKET_NAME -and (Test-Path -LiteralPath $emacsDefaultProfile)) { $env:EMACS_SOCKET_NAME = Get-Content -LiteralPath $emacsDefaultProfile -Raw }
if (-not $env:ALTERNATE_EDITOR) { $env:ALTERNATE_EDITOR = 'nvim' }
if (-not $env:EDITOR) { $env:EDITOR = 'emacsclient -c' }
if (-not $env:VISUAL) { $env:VISUAL = $env:EDITOR }

# fzf theme and bindings from config.fish (Linux-only openers dropped).
$ENV:FZF_DEFAULT_OPTS = @'
--info=inline --layout reverse --border top --multi
--color=fg:#d5c4a1,bg:#282828,hl:#fabd2f
--color=fg+:#282828,bg+:#83a598,hl+:#282828
--color=info:#83a598,prompt:#bdae93,pointer:#83a598
--color=marker:#83a598,spinner:#fabd2f,header:#928374
--prompt="$ " --pointer="▶" --marker="✓"
--bind "?:toggle-preview"
--bind "alt-j:preview-down,alt-k:preview-up"
--bind "ctrl-d:preview-page-down,ctrl-u:preview-page-up"
--bind "ctrl-a:select-all,ctrl-s:toggle-sort"
--bind "ctrl-c:execute(code {+})"
--bind "ctrl-v:execute(nvim {+})"
--bind "ctrl-y:execute-silent(echo {+}| clip)"
--bind "tab:down,btab:up"
'@ -replace "`r?`n", ' '

if (-not ([Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') -or
    ([Environment]::GetCommandLineArgs() -contains '-NonInteractive')) { return }

# Tool init scripts cost 75-150 ms each to generate, so keep them under
# %LOCALAPPDATA%\windots\init and regenerate when the tool's exe changes
# (a Scoop shim is followed to the app it launches).
function Import-ToolInit([string]$Name, [string[]]$InitArgs) {
    if (-not ($exe = Get-Command $Name -CommandType Application -ErrorAction Ignore | Select-Object -First 1)) { return }
    $source = $exe.Source
    $shim = [IO.Path]::ChangeExtension($source, '.shim')
    if (Test-Path -LiteralPath $shim) { $source = (Get-Content -LiteralPath $shim -TotalCount 1) -replace '^path\s*=\s*"?|"$' }
    $cache = Join-Path $env:LOCALAPPDATA "windots\init\$Name.ps1"
    if (-not (Test-Path -LiteralPath $cache) -or (Get-Item -LiteralPath $cache).LastWriteTime -lt (Get-Item -LiteralPath $source).LastWriteTime) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $cache) -Force | Out-Null
        & $exe.Source @InitArgs | Out-File -LiteralPath $cache -Encoding utf8
    }
    $cache
}

# === Aliases (~/dotfiles/general/aliases) ===
# PowerShell ships aliases such as gc, gl, gp, gm, ls and cat, and aliases win
# over functions, so drop the built-in ones these names replace.
$shellAliases = [ordered]@{
    # Navigation
    '..' = 'Set-Location ..'; '...' = 'Set-Location ../..'; '....' = 'Set-Location ../../..'; '.....' = 'Set-Location ../../../..'
    # Names are case-insensitive here, so fish's D (Downloads) would clash with d.
    d = 'Set-Location ~/Dropbox'; H = 'Set-Location ~'
    # eza listings
    ls = 'eza --icons --hyperlink'; l = 'eza --icons --hyperlink --classify --grid'
    ll = 'eza --icons --hyperlink -l'; lld = 'eza --icons --hyperlink -l --group-directories-first'
    la = 'eza --icons --hyperlink -a'; lla = 'eza --icons --hyperlink -la'; lt = 'eza --icons --hyperlink --tree'
    lst = 'eza --icons --hyperlink --sort=new'; lss = 'eza --icons --hyperlink --sort=size'
    lg = 'eza --icons --hyperlink --git'; lh = 'eza --icons --hyperlink -lh'
    ld = 'eza --icons --hyperlink -l --group-directories-first --only-dirs'
    # Search, view and system tools
    find = 'fd --type f'; findd = 'fd --type d'; finda = 'fd --hidden'; findi = 'fd -i'
    grep = 'grep.exe --color=auto'; cat = 'bat'; catn = 'bat --number'; catA = 'bat --show-all'
    ping = 'gping'; untar = 'tar -xvf'; targz = 'tar -cvzf'; untargz = 'tar -xvzf'
    pbcopy = 'Set-Clipboard'; pbpaste = 'Get-Clipboard'
    # Editors
    v = 'nvim'; vi = 'nvim'; vim = 'nvim'; em = 'emacs'; en = 'emacs -nw'
    e = 'emacsclient -n'; et = 'emacsclient -t'; ec = 'emacsclient -c -a emacs'
    # Git
    gcl = 'git clone'; gd = 'git diff'; gdc = 'git diff --cached'; ga = 'git add'; gall = 'git add -A'
    gf = 'git fetch --all --prune'; gft = 'git fetch --all --prune --tags'
    gs = 'git status -sb --ignore-submodules'; gss = 'git status -sb --ignore-submodules'; gst = 'git status -sb --ignore-submodules'
    gsu = 'git submodule update --init --recursive'; gl = 'git logtree'; gpr = 'git pull --rebase'
    gp = 'git push'; gpo = 'git push origin'; gpt = 'git push --tags'; gpu = 'git push --set-upstream'
    gc = 'git commit -v'; gca = 'git commit -v -a'; gcm = 'git commit -v -m'; gci = 'git commit --interactive'
    gb = 'git branch'; gba = 'git branch -a'; gbt = 'git branch --track'; gbd = 'git branch -D'
    gm = 'git merge --no-ff'; grs = 'git reset --soft'; grh = 'git reset --hard'
    gco = 'git checkout'; gcob = 'git checkout -b'; gcp = 'git cherry-pick'
    gt = 'git tag'; gta = 'git tag -a'; gtd = 'git tag -d'; gtl = 'git tag -l'
}
foreach ($name in $shellAliases.Keys) { if (Get-Alias -Name $name -ErrorAction Ignore) { Remove-Item -LiteralPath "Alias:$name" -Force } }
Invoke-Expression (($shellAliases.GetEnumerator() | ForEach-Object { "function global:$($_.Key) { $($_.Value) @args }" }) -join "`n")
Set-Alias -Name su -Value Update-ShellElevation -Option AllScope -Force
Set-Alias -Name rm -Value Remove-ItemExtended -Option AllScope -Force
Set-Alias -Name which -Value Show-Command -Option AllScope -Force

# === Functions (~/dotfiles/config/fish/functions) ===
function reload { . $PROFILE.CurrentUserAllHosts }
function touch([Parameter(Mandatory)][string]$Name) { New-Item -ItemType File -Path $Name -Force | Out-Null }
function Show-Command([Parameter(Mandatory)][string]$Name) { Get-Command $Name | Select-Object -ExpandProperty Definition }
function Remove-ItemExtended([switch]$rf, [Parameter(Mandatory)][string]$Path) { Remove-Item $Path -Recurse:$rf -Force:$rf }

function Update-ShellElevation {
    if ((Get-Command sudo -ErrorAction Ignore) -and (@(& sudo --help 2>&1) -join "`n") -notmatch 'Sudo is disabled') {
        & sudo -E pwsh -NoLogo -Interactive -NoExit -c 'Clear-Host'
        if ($LASTEXITCODE -eq 0) { return }
    }
    Start-Process pwsh -Verb RunAs
}

# yazi, cd to its last directory on quit.
function y {
    $cwdFile = New-TemporaryFile
    yazi @args --cwd-file="$cwdFile"
    $cwd = Get-Content -LiteralPath $cwdFile -Raw
    if ($cwd -and $cwd -ne $PWD.Path) { Set-Location -LiteralPath $cwd }
    Remove-Item -LiteralPath $cwdFile
}

# broot, running the cd (or other command) it prints.
function br {
    $cmdFile = New-TemporaryFile
    broot --outcmd "$cmdFile" @args
    if ($LASTEXITCODE -eq 0 -and ($cmd = Get-Content -LiteralPath $cmdFile -Raw)) { Invoke-Expression $cmd }
    Remove-Item -LiteralPath $cmdFile
}

# cd to a directory picked with fzf.
function ff([string]$Root = '.') {
    $dir = fd --type d --follow . $Root | fzf +m
    if ($dir) { Set-Location -LiteralPath $dir }
}

# cd into the directory of a picked file.
function cdf {
    $file = fzf +m --exit-0 --query="$args"
    if ($file) { Set-Location -LiteralPath (Split-Path -Parent (Resolve-Path -LiteralPath $file)) }
}

# Open picked files in $EDITOR.
function fe {
    $files = @(fzf --multi --select-1 --exit-0 --query="$args")
    if ($files) { Invoke-Expression "$env:EDITOR $(($files | ForEach-Object { "'$_'" }) -join ' ')" }
}

# Open a picked file: Enter in $EDITOR, Ctrl+O with its default app.
function fo {
    $key, $file = fzf --exit-0 --expect=ctrl-o, ctrl-e --query="$args"
    if (-not $file) { return }
    if ($key -eq 'ctrl-o') { Invoke-Item -LiteralPath $file } else { Invoke-Expression "$env:EDITOR '$file'" }
}

# Kill picked processes.
function fkill {
    $rows = Get-Process | Where-Object Id | ForEach-Object { '{0,7} {1}' -f $_.Id, $_.ProcessName } | fzf --multi
    $rows | ForEach-Object { Stop-Process -Id ([int]($_.Trim() -split '\s+')[0]) -Force }
}

# === Prompt and tools ===
if ($init = Import-ToolInit starship init, powershell, --print-full-init) {
    . $init
    # kitty shell integration equivalents for Windows Terminal: OSC 133;A marks
    # each prompt (scroll between prompts) and OSC 9;9 reports the directory,
    # so new tabs and splits open where this shell is.
    $starshipPrompt = $function:prompt
    function global:prompt {
        $prompt = & $starshipPrompt
        $esc, $bel = [char]27, [char]7
        $cwd = if ($PWD.Provider.Name -eq 'FileSystem') { "$esc]9;9;`"$($PWD.ProviderPath)`"$bel" }
        "$esc]133;A$bel$cwd$prompt"
    }
}
if ($init = Import-ToolInit zoxide init, powershell) { . $init }

if ($PSVersionTable.PSVersion.Major -ge 7 -and ($init = Import-ToolInit direnv hook, pwsh)) { . $init }

# === Line editor (fish-style) ===
# Windows PowerShell too: herdr's panes run it on Windows, where the shared
# herdr config's fish isn't installed.
if (Get-Module PSReadLine) {
    function Get-Rgb([string]$Hex) { $n = [Convert]::ToInt32($Hex, 16); "$([char]27)[38;2;$($n -shr 16);$(($n -shr 8) -band 255);$($n -band 255)m" }
    # Separate calls: one rejected option (predictions need a VT console)
    # would otherwise drop the rest, leaving Windows mode where Ctrl+D is ^D.
    Set-PSReadLineOption -EditMode Emacs
    Set-PSReadLineOption -BellStyle None -HistoryNoDuplicates -HistorySearchCursorMovesToEnd
    # fish_color_* from config.fish (gruvbox).
    $colors = @{
        Default = Get-Rgb d5c4a1; Command = Get-Rgb 458588; Keyword = Get-Rgb b16286; String = Get-Rgb 98971a
        Operator = Get-Rgb fabd2f; Parameter = Get-Rgb 689d6a; Variable = Get-Rgb d3869b; Number = Get-Rgb d5c4a1
        Comment = Get-Rgb 928374; Error = Get-Rgb fb4934
        Selection = "$([char]27)[48;2;131;165;152m"
    }
    # Windows PowerShell's PSReadLine 2.0 predates inline predictions.
    if ((Get-PSReadLineOption).PSObject.Properties['InlinePredictionColor']) { $colors.InlinePrediction = Get-Rgb 928374 }
    Set-PSReadLineOption -Colors $colors
    try { Set-PSReadLineOption -PredictionSource HistoryAndPlugin -PredictionViewStyle InlineView -ErrorAction Stop } catch { }
    # On the first idle prompt, not here: imported from the profile it keeps
    # `pwsh -File`/`-Command` from ever exiting. OnIdle fires only at a prompt.
    $null = Register-EngineEvent PowerShell.OnIdle -MaxTriggerCount 1 -Action { Import-Module CompletionPredictor -ErrorAction SilentlyContinue }

    # Emacs mode already binds Ctrl+A/E/F/B/D/W/K/Y/P/N/_ and Alt+F/B/D/Y/./U;
    # these add fish's extras. Word moves also take the next word of an
    # inline suggestion, like fish's Alt+F.
    $emacsKeys = [ordered]@{
        'Ctrl+RightArrow' = 'ForwardWord'; 'Ctrl+LeftArrow' = 'BackwardWord'
        'Alt+RightArrow'  = 'ForwardWord'; 'Alt+LeftArrow' = 'BackwardWord'
        'Ctrl+Delete'     = 'KillWord'; 'Ctrl+Backspace' = 'BackwardKillWord'
        'Ctrl+u'          = 'BackwardKillLine'; 'Ctrl+/' = 'Undo'
        # Alt+L accepts the suggestion (Emacs: downcase word).
        'Alt+l' = 'AcceptSuggestion'
        # fish: Up/Down search history by the typed prefix, Tab opens the pager.
        UpArrow           = 'HistorySearchBackward'; DownArrow = 'HistorySearchForward'
        Tab     = 'MenuComplete'
    }
    # try: Windows PowerShell may load PSReadLine 2.0, which lacks e.g. AcceptSuggestion.
    foreach ($key in $emacsKeys.GetEnumerator()) { try { Set-PSReadLineKeyHandler -Chord $key.Key -Function $key.Value } catch { } }
    # After -EditMode, which resets every binding including starship's Enter handler.
    if ($starshipPrompt) { Enable-TransientPrompt }

    # fzf key bindings as in fish (`fzf --fish` plus FZF_*_OPTS from config.fish).
    # Ctrl+T: insert picked paths at the cursor.
    Set-PSReadLineKeyHandler -Chord Ctrl+t -BriefDescription FzfFiles -ScriptBlock {
        $paths = @(fzf --multi --preview 'bat -n --color=always {}')
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
        if ($paths) { [Microsoft.PowerShell.PSConsoleReadLine]::Insert((($paths | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' ')) }
    }
    # Ctrl+R: pick a history entry (newest first) to replace the line; Ctrl+Y copies it.
    Set-PSReadLineKeyHandler -Chord Ctrl+r -BriefDescription FzfHistory -ScriptBlock {
        $line = $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        $history = [Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems().CommandLine
        [array]::Reverse($history)
        $picked = ($history | Select-Object -Unique) -join "`0" |
            fzf --read0 --no-multi --scheme=history --query=$line --header 'Press CTRL-Y to copy command into clipboard' --color header:italic --bind 'ctrl-y:execute-silent(echo {}| clip)+abort'
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
        if ($picked) { [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $line.Length, ($picked -join "`n")) }
    }
    # Alt+C: cd into a picked directory; Ctrl+T in the picker opens it in a new tab.
    Set-PSReadLineKeyHandler -Chord Alt+c -BriefDescription FzfCd -ScriptBlock {
        $dir = fzf --no-multi --walker=dir, follow --walker-skip=.git, node_modules, target --preview 'eza --tree --level 2 --icons=always {}' --bind 'ctrl-t:execute-silent(wt -w 0 nt -d {})'
        if ($dir) { Set-Location -LiteralPath $dir }
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
    }
}

if ((Get-Command fastfetch -ErrorAction Ignore) -and -not $env:FASTFETCH_DISABLE) { fastfetch }
