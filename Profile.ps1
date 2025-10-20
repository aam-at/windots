<#
 Profile.ps1 — PowerShell profile for windots
 Refactored for resilience, optional tooling, and fast startup.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-Command {
    param([Parameter(Mandatory=$true)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# Aliases
Set-Alias -Name cat -Value bat
Set-Alias -Name df -Value Get-Volume
Set-Alias -Name ff -Value Find-File
Set-Alias -Name grep -Value Find-String
Set-Alias -Name l -Value Get-ChildItemPretty
Set-Alias -Name la -Value Get-ChildItemPretty
Set-Alias -Name ll -Value Get-ChildItemPretty
Set-Alias -Name ls -Value Get-ChildItemPretty
Set-Alias -Name rm -Value Remove-ItemExtended
Set-Alias -Name su -Value Update-ShellElevation
Set-Alias -Name tif -Value Show-ThisIsFine
Set-Alias -Name touch -Value New-File
Set-Alias -Name vi -Value nvim
Set-Alias -Name vim -Value nvim
Set-Alias -Name which -Value Show-Command

# Functions
function Find-File {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline,Mandatory=$true)][string]$SearchTerm)
    Write-Verbose "Searching for '$SearchTerm'"
    Get-ChildItem -Recurse -Filter "*$SearchTerm*" -ErrorAction SilentlyContinue | Format-Table -AutoSize
}

function Update-ShellElevation {
    [CmdletBinding()]
    param()
    Write-Verbose "Elevating shell to administrator"
    if (Test-Command sudo) { sudo -E pwsh -NoLogo -Interactive -NoExit -c "Clear-Host" }
    else { Start-Process pwsh -Verb RunAs }
}

function Find-String {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true,Position=0)][string]$SearchTerm,
        [Parameter(Position=1)][string]$Directory,
        [switch]$Recurse
    )
    if ($Directory) {
        if ($Recurse) { Get-ChildItem -Recurse $Directory | Select-String $SearchTerm; return }
        Get-ChildItem $Directory | Select-String $SearchTerm; return
    }
    if ($Recurse) { Get-ChildItem -Recurse | Select-String $SearchTerm; return }
    Get-ChildItem | Select-String $SearchTerm
}

function New-File {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Name)
    Write-Verbose "Creating file '$Name'"
    New-Item -ItemType File -Name $Name -Path $PWD -Force | Out-Null
}

function Show-Command {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Name)
    Get-Command $Name | Select-Object -ExpandProperty Definition
}

function Get-OrCreateSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$secretName)
    Write-Verbose "Getting secret $secretName"
    $secretValue = Get-Secret $secretName -AsPlainText -ErrorAction SilentlyContinue
    if (!$secretValue) {
        $createSecret = Read-Host "No secret found matching $secretName, create one? Y/N"
        if ($createSecret.ToUpper() -eq 'Y') {
            $secretValue = Read-Host -Prompt "Enter secret value for ($secretName)" -AsSecureString
            Set-Secret -Name $secretName -SecureStringSecret $secretValue
            $secretValue = Get-Secret $secretName -AsPlainText
        } else { throw "Secret not found and not created, exiting" }
    }
    return $secretValue
}

function Get-ChildItemPretty {
    [CmdletBinding()]
    param([string]$Path = $PWD)
    Write-Host ""
    if (Test-Command eza) {
        eza -a -l --header --icons --hyperlink --time-style relative --group-directories-first --git $Path
    } else {
        Get-ChildItem -Force $Path | Format-Table Mode,Length,LastWriteTime,Name -AutoSize
    }
    Write-Host ""
}

function Show-ThisIsFine {
    [CmdletBinding()]
    param()
    if (Test-Command Show-ColorScript) { Show-ColorScript -Name thisisfine } else { Write-Host "(colorscript not installed)" }
}

function Remove-ItemExtended {
    [CmdletBinding()]
    param([switch]$rf,[Parameter(Mandatory=$true)][string]$Path)
    Remove-Item $Path -Recurse:$rf -Force:$rf -ErrorAction Stop
}

# Environment Variables
$ENV:HOME = $HOME
$ENV:DotsLocalRepo = "$HOME\dotfiles"
$ENV:WindotsLocalRepo = "$HOME\windots"
$ENV:_ZO_DATA_DIR = "$HOME\OneDrive\Documents\PowerShell"
$ENV:FZF_DEFAULT_OPTS = '--color=fg:-1,fg+:#ffffff,bg:-1,bg+:#3c4048 --color=hl:#5ea1ff,hl+:#5ef1ff,info:#ffbd5e,marker:#5eff6c --color=prompt:#ff5ef1,spinner:#bd5eff,pointer:#ff5ea0,header:#5eff6c --color=gutter:-1,border:#3c4048,scrollbar:#7b8496,label:#7b8496 --color=query:#ffffff --border="rounded" --border-label="" --preview-window="border-rounded" --height 40% --preview="bat -n --color=always {}"'
$ENV:STARSHIP_CONFIG = "$ENV:DotsLocalRepo\config\starship.toml"

function Invoke-Starship-TransientFunction { if (Test-Command starship) { & starship module character } }
if (Test-Command starship) { Invoke-Expression (& starship init powershell) }
if (Get-Command Enable-TransientPrompt -ErrorAction SilentlyContinue) { Enable-TransientPrompt }
if (Test-Command zoxide) { Invoke-Expression (& { ( zoxide init powershell | Out-String ) }) }
if (Test-Command direnv) { Invoke-Expression "$(direnv hook pwsh)" }

if (Get-Module -ListAvailable -Name PSReadLine) {
    try {
        $colors = @{
            'Operator'         = "`e[35m"
            'Parameter'        = "`e[36m"
            'String'           = "`e[32m"
            'Command'          = "`e[34m"
            'Variable'         = "`e[37m"
            'Comment'          = "`e[38;5;244m"
            'InlinePrediction' = "`e[38;5;244m"
        }
        Set-PSReadLineOption -Colors $colors
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin
        Set-PSReadLineOption -PredictionViewStyle InlineView
        Set-PSReadLineKeyHandler -Function AcceptSuggestion -Key Alt+l
        if (Get-Module -ListAvailable -Name CompletionPredictor) { Import-Module -Name CompletionPredictor }
    } catch { }
}

# Skip fastfetch for non-interactive shells
if ([Environment]::GetCommandLineArgs().Contains('-NonInteractive')) { return }
if (Test-Command fastfetch) { fastfetch }
