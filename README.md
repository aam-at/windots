# windots

Windows dotfiles and setup scripts.

## Install
- Run bootstrap to install apps and link configs:

  `pwsh -ExecutionPolicy Bypass -File .\Setup.ps1`

## Dependency
- Requires my common dotfiles repo for shared configs: `aam-at/dotfiles`.
  Clone it locally so `Setup.ps1` can link the common configs.

## PowerShell Profile
- This repo includes `Profile.ps1`, used as the default PowerShell profile.
  `Setup.ps1` links it into place.

