# update-tools for Windows

A PowerShell port of [update-tools](../README.md) for two of its three modes:

- **Archipelago custom worlds** (`.apworld` files), including worlds shipped inside a mod's release zip
- **ISOs on a Ventoy drive**, every download checksum-verified before it replaces anything

AppImages are Linux-only, so that mode isn't here. `make-update-cfg.ps1` writes new cfgs, as on Linux.

> [!IMPORTANT]
> **This port was written with AI** (Claude by Anthropic), like the rest of the project. It was tested with PowerShell 7 on Linux, against the same cases as the bash version and with identical results, but **not yet on Windows itself** or in Windows PowerShell 5.1. Read it before running it, start with `-c` (check only), and keep backups of anything you point it at. It comes with no warranty.

It uses the same cfg files and keys as the bash version, so a cfg works in either. Everything else, from the managers to the rules for when an item is up to date, also matches it; see the main [README](../README.md) for the cfg format and the managers.

## Requirements

Windows PowerShell 5.1 (part of Windows 10 and 11) or PowerShell 7. Nothing else: downloads, JSON, zip files and checksums are all built in.

## Setup

1. Put the `windows` folder anywhere, for example `C:\Tools\update-tools`.
2. Windows doesn't run downloaded scripts by default. Either allow your own scripts once:

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   Get-ChildItem C:\Tools\update-tools -Recurse -Filter *.ps1 | Unblock-File
   ```

   or start it each time with `powershell -ExecutionPolicy Bypass -File C:\Tools\update-tools\update-tools.ps1 …`.
3. Set the folders in `%APPDATA%\update-tools\update-tools.cfg`, and optionally how often items are checked:

   ```ini
   apw_dir=C:\ProgramData\Archipelago\custom_worlds
   iso_dir=E:\
   skip_checked=on
   skip_hours=24
   ```

   A leading `~` and Windows variables like `%USERPROFILE%` are expanded. Without its key, a mode stops with a message naming it; `-Root DIR` overrides the folder for one run.

## Usage

```powershell
.\update-tools.ps1 -m apw          # update the worlds
.\update-tools.ps1 -m iso -c       # only check the ISOs, download nothing
.\update-tools.ps1 -m iso -r F:\   # the Ventoy drive on another letter
.\update-tools.ps1 -m all          # both in turn
```

| Option | Meaning |
|---|---|
| `-m`, `-Mode MODE` | `apw` (`apworlds`), `iso` (`isos`) or `all` |
| `-c`, `-Check` | look up and compare, then report what would be updated; downloads and writes nothing |
| `-f`, `-Force` | check items checked within `skip_hours` too |
| `-r`, `-Root DIR` | use DIR instead of the mode's folder (not with `-m all`) |
| `-d`, `-Debug` | explain each decision and time each item |
| `-h`, `-Help` | show the help, with the folders in use |

## Adding an item

```powershell
.\make-update-cfg.ps1 apw https://github.com/OrcThrowman/7-Days-to-Die-AP
.\make-update-cfg.ps1 iso https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso archlinux
```

`make-update-cfg.ps1 TYPE LINK [NAME]` (TYPE `apw` or `iso`; `-r DIR`, `-d`) works like the bash version: a GitHub or GitLab project becomes a cfg that follows its releases, any other link a fixed download, and an ISO also gets the checksum file found next to it. It checks the cfg with the same lookup `update-tools.ps1` uses before writing it, and never overwrites one. The one difference: here builds for Linux, Mac and ARM are left out, not Windows ones. Cfgs can also be written by hand, as described in the main README.

A GitHub token goes in `$env:GITHUB_TOKEN` or on the first line of `%APPDATA%\update-tools\github_token`. It's only ever sent to api.github.com.

Emoji in the output need a console that shows them, such as Windows Terminal.

## License

MIT, see [LICENSE](../LICENSE).
