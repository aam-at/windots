# windots

Windows dotfiles and setup scripts.

## Install
- Run this once, from a regular PowerShell prompt:

  `irm https://raw.githubusercontent.com/aam-at/windots/master/setup/Bootstrap.ps1 | iex`

  This installs Scoop, reopens a shell so it's on PATH, installs Git, clones
  this repo to `~/windots` and `aam-at/dotfiles` to `~/dotfiles`, and runs
  `Setup.ps1`. Safe to re-run.

- `Setup.ps1` expects Scoop, Git, and `~/dotfiles` already in place
  (Bootstrap.ps1 handles that) and does the rest: winget/scoop packages,
  config links, Emacs distributions, PowerToys settings, and fonts. Once
  bootstrapped, you can re-run it directly: `pwsh -ExecutionPolicy Bypass -File .\setup\Setup.ps1`

- Run it as a regular user; no need to launch it elevated. It prompts for UAC
  approval only for the one step that needs admin rights (Sudo, Developer
  Mode, long paths, the agent power plan) and continues without it if you
  decline.
  Existing non-link configuration paths are preserved unless `-Force` is
  supplied. Use `-DryRun` to preview the setup without making changes.

- The setup enables PowerToys FancyZones and Workspaces. Use
  `-SkipPowerToys` to leave existing PowerToys settings unchanged.

## Desktop modes

The laptop display is too small for a useful multi-column tiling layout, while
an external monitor benefits from it. `shells` contains the two explicit
desktop options; automatic monitor detection is intentionally not used.

- **Laptop / native Windows:**
  `pwsh -File .\shells\native\Use-Desktop.ps1`

  Stops Komorebi, enables the native Windows virtual-desktop workflow with
  PowerToys Workspaces and FancyZones, and hides the bottom taskbar.
  In this mode, `Alt+1` through `Alt+9` jump to numbered virtual desktops;
  add Shift to move the focused window to that desktop. Caps Lock taps as
  Escape (or holds as Left Ctrl), while Escape is Caps Lock.
  Native mode uses the Scoop-installed Windows Virtual Desktop Helper for
  numbered desktop jumps.

- **External monitor / Komorebi:**
  `pwsh -File .\shells\komorebi\Use-Desktop.ps1`

  Stops the native desktop bindings, restores Komorebi's startup shortcuts,
  starts its external-monitor tiling configuration, and launches its
  AutoHotkey keybindings and YASB top bar.

Both scripts accept `-DryRun` to show their actions without changing the current
desktop mode.

- **Keybindings:** both modes' full keybinding lists are registered as
  PowerToys Shortcut Guide manifests (`shells\native\windots-native.yaml`,
  `shells\komorebi\windots-komorebi.yaml`). Press `Win+Shift+/` to look them
  up live instead of keeping a separate written list in sync by hand.

## Dependency
- Uses my common dotfiles repo for shared configs: `aam-at/dotfiles`.
  `Bootstrap.ps1` clones it to `~/dotfiles` if it's missing.

## PowerShell Profile
- This repo includes `Profile.ps1`, used as the default PowerShell profile.
  `Setup.ps1` links it into place.

## SSH key at sign-in

`Setup.ps1` enables the built-in Windows `ssh-agent` service, then asks once
for the passphrase of `~/.ssh/id_ed25519`. The service stores the key in the
signed-in Windows account context, making it available at future sign-ins
without putting the passphrase in a script or Startup shortcut. To add a
different key later, run `pwsh -File .\setup\Configure-SshAgent.ps1 -KeyPath
<path-to-key>`.

## Emacs profiles
- `scripts\Emacs-Daemon.ps1` manages named Doom and Spacemacs daemons. For
  example: `pwsh -File .\scripts\Emacs-Daemon.ps1 switch doom` starts Doom,
  stops the other managed profiles, and makes Doom start at sign-in.
- `scripts\Doom-Profile.ps1` runs Doom commands with the isolated Doom paths;
  for example: `pwsh -File .\scripts\Doom-Profile.ps1 sync`.
- Setup installs Emacs, Doom, and Spacemacs from Scoop and their upstream
  repositories, then links the shared profiles from `~/dotfiles/emacs`.
  Spacemacs completes package installation the first time a profile opens;
  use `-SkipEmacs` to skip this setup phase.
