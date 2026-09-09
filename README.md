# windots

Windows dotfiles and setup scripts.

## Install
- Run bootstrap to install apps and link configs:

  `pwsh -ExecutionPolicy Bypass -File .\scripts\Setup.ps1`

- Run it elevated to install machine-scoped winget packages and enable long
  paths. Existing non-link configuration paths are preserved unless `-Force`
  is supplied. Use `-DryRun` to preview the setup without making changes.

- The setup configures PowerToys utilities that complement Komorebi. It leaves
  FancyZones and Workspaces disabled; use `-SkipPowerToys` to leave existing
  PowerToys settings unchanged.

## Dependency
- Requires my common dotfiles repo for shared configs: `aam-at/dotfiles`.
  Clone it locally so `Setup.ps1` can link the common configs.

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
