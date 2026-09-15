# windots

Windows dotfiles and setup scripts.

## Install
- Run this once, from a regular PowerShell prompt:

  `irm https://raw.githubusercontent.com/aam-at/windots/master/scripts/Bootstrap.ps1 | iex`

  This installs Scoop, reopens a shell so it's on PATH, installs Git, clones
  this repo to `~/windots`, and runs `Setup.ps1`. Safe to re-run.

- `Setup.ps1` expects Scoop and Git already on PATH (Bootstrap.ps1 handles
  that) and does the rest: winget/scoop packages, config links, Emacs
  distributions, PowerToys settings, and fonts. Once bootstrapped, you can
  re-run it directly: `pwsh -ExecutionPolicy Bypass -File .\scripts\Setup.ps1`

- Run it as a regular user; no need to launch it elevated. It prompts for UAC
  approval only for the one step that needs admin rights (Developer Mode,
  long paths, the agent power plan) and continues without it if you decline.
  Existing non-link configuration paths are preserved unless `-Force` is
  supplied. Use `-DryRun` to preview the setup without making changes.

- The setup enables PowerToys FancyZones and Workspaces. Use
  `-SkipPowerToys` to leave existing PowerToys settings unchanged.

## Desktop modes

The laptop display is too small for a useful multi-column tiling layout, while
an external monitor benefits from it. The scripts below switch explicitly
between those two working environments; automatic monitor detection is
intentionally not used.

- **Laptop / native Windows:**
  `pwsh -File .\scripts\Use-Native-Desktop.ps1`

  Stops Komorebi, enables the native Windows virtual-desktop workflow with
  PowerToys Workspaces and FancyZones, hides the bottom taskbar, and starts
  the compact translucent YASB top bar.

- **External monitor / Komorebi:**
  `pwsh -File .\scripts\Use-Komorebi-Desktop.ps1`

  Stops the native desktop bindings, restores Komorebi's startup shortcuts,
  starts its external-monitor tiling configuration, and launches its
  AutoHotkey keybindings.

Both scripts accept `-DryRun` to show their actions without changing the
current desktop mode.

## Dependency
- Uses my common dotfiles repo for shared configs: `aam-at/dotfiles`.
  `Setup.ps1` clones it to `~/dotfiles` automatically if it's missing.

## PowerShell Profile
- This repo includes `Profile.ps1`, used as the default PowerShell profile.
  `Setup.ps1` links it into place.

## Emacs profiles
- `scripts\emacs-daemon.ps1` manages named Doom and Spacemacs daemons. For
  example: `pwsh -File .\scripts\emacs-daemon.ps1 switch doom` starts Doom,
  stops the other managed profiles, and makes Doom start at sign-in.
- `scripts\doom-profile.ps1` runs Doom commands with the isolated Doom paths;
  for example: `pwsh -File .\scripts\doom-profile.ps1 sync`.
- Setup installs Emacs, Doom, and Spacemacs from Scoop and their upstream
  repositories, then links the shared profiles from `~/dotfiles/emacs`.
  Spacemacs completes package installation the first time a profile opens;
  use `-SkipEmacs` to skip this setup phase.
