# update-tools

Bash scripts that keep three kinds of downloaded software up to date:

- **AppImages**, each with a desktop entry and icon extracted from the AppImage itself
- **Archipelago custom worlds** (`.apworld` files), including worlds shipped inside a mod's release zip
- **ISOs on a Ventoy drive**, every download checksum-verified before it replaces anything

Each item is described by a small `key=value` config file that says where its new versions come from: a GitHub or GitLab release, a fixed download URL, a JSON feed, a web server's folder listing, or a dated file name. One command checks them all and installs what changed.

## Requirements

- bash 4.3 or newer, and the usual tools (`awk`, `sed`, `find`, `df`)
- `curl` for every mode
- `jq` for AppImages and worlds
- `unzip` for worlds (and for AppImages released as zips; `tar` for `.tar.*` ones)
- `sha256sum` and `sha512sum` for ISOs

The command checks for what its mode needs and says what's missing.

## Install

```sh
git clone https://github.com/Nykorin/update-tools.git
mkdir -p ~/.local/bin
ln -s "$PWD/update-tools/update-tools" ~/.local/bin/update-tools
ln -s "$PWD/update-tools/make-update-cfg" ~/.local/bin/make-update-cfg
```

Both commands find their `lib/` folder through the symlink, so they can be linked from anywhere on your `PATH`.

### Folders

Each mode works in one folder, set in `~/.config/update-tools/update-paths.cfg` (or under `$XDG_CONFIG_HOME`):

```ini
app_dir=~/AppImages
apw_dir=~/Games/Archipelago/custom_worlds
iso_dir=/run/media/me/Ventoy
```

The file is read as `key=value` data, never run as shell code; a leading `~` or `$HOME` is expanded. AppImages default to `~/AppImages`. Worlds and ISOs have no default: until their key is set, their mode stops with a message naming it. `-r DIR` overrides the folder for one run, and `update-tools -h` lists the folders in use.

## Usage

```sh
update-tools -m app          # update the AppImages
update-tools -m apw -c       # only check the worlds, download nothing
update-tools -m iso -r /run/media/me/Ventoy
update-tools -m all          # all three in turn
```

| Option | Meaning |
|---|---|
| `-m`, `--mode MODE` | what to update: `app` (`appimages`), `apw` (`apworlds`), `iso` (`isos`) or `all` |
| `-c`, `--check` | look up and compare, then report what would be updated; downloads and writes nothing |
| `-f`, `--force` | check items already checked today; for AppImages, also rebuild each desktop entry and icon |
| `-r`, `--root DIR` | use DIR instead of the mode's folder (not with `-m all`) |
| `-d`, `--debug` | explain each decision and time each item (or `DEBUG=1`) |
| `-h`, `--help` | show the help |

Each item is checked at most once a day unless `-f` is given. On a terminal the output is a live two-line status block with an overall progress bar; redirected output is plain text without escape codes. When GitHub requests were made, the last line shows how many of the hourly request budget are left.

## Adding an item

### With make-update-cfg

```sh
make-update-cfg app https://github.com/TwilitRealm/dusklight
make-update-cfg apw https://github.com/OrcThrowman/7-Days-to-Die-AP
make-update-cfg iso https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso archlinux
```

It reads the link, writes the cfg, and checks it with the same lookup `update-tools` uses before saving it. The next `update-tools` run installs the item.

- **GitHub or GitLab projects:** it takes the newest release with something installable, ignores builds for other systems and architectures, and turns the file name into a pattern that matches later versions. If several files are left, it lists them; pass the link of the one you want instead.
- **Any other link:** it becomes a fixed download.
- **ISOs:** it also looks for a checksum file next to the ISO. Set `folder=` to the ISO's folder on the drive afterwards.

It never overwrites an existing cfg.

### By hand

Each item has a cfg in its mode's `.cfg/` folder: `NAME.appimage.cfg`, `NAME.apworld.cfg` or `NAME.iso.cfg`. Lines are `key=value`; lines starting with `#` are comments. A cfg is read as data, never run as shell code, and only known keys are accepted.

```ini
# ~/AppImages/.cfg/dusklight.appimage.cfg
manager=github
repo=TwilitRealm/dusklight
repo_filename=Dusklight-*-linux-x86_64.AppImage
```

```ini
# custom_worlds/.cfg/7dtd_world.apworld.cfg
manager=github
repo=OrcThrowman/7-Days-to-Die-AP
repo_filename=*.apworld
```

```ini
# .cfg/archlinux.iso.cfg in the ISO folder
folder=Linux/ArchLinux
manager=static
url=https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
checksum=sha256sums.txt
```

Managers and their keys:

| Manager | Required | Optional |
|---|---|---|
| `github` | `repo` (owner/name), and `repo_filename` (a glob) or `repo_regex` (a regex matched against the whole file name) | `allow_prereleases` (`auto`, the default, takes a stable release first; `false`; `true`) |
| `gitlab` | `repo_url` (the project's gitlab.com address), and `repo_filename` or `repo_regex` | |
| `static` | `url` (a fixed download; redirects are followed) | |
| `jsonfeed` | `feed_url`, `channel`, `arch_key`, `download_base` (with `{minor_version}` and `{filename}`) | |
| `dirlist` | `url` with `*` or `[…]` in folder and file parts, resolved from the server's folder listings | `download_suffix` (SourceForge: `/download`) |
| `dateprobe` | `url` with `{date}`, for releases with no listing | `probe_days` (how far back to look, default 90) |

ISO cfgs also need:

| Key | Meaning |
|---|---|
| `folder` | the ISO's folder, relative to the ISO folder (`iso_dir`) |
| `checksum` | the checksum file: a name or glob next to the ISO, or a URL; `{iso}` stands for the ISO's file name |
| `checksum_save` | optional: the local name for the saved checksum file |

Worlds can set `apworld_filename` (a glob) to pick one `.apworld` out of a release zip that holds several.

The scripts add their own keys after each check (`current_version`, `installed_file`, `last_checked`, ETags, digests, `iso_hash`). Leave those alone; a cfg without `installed_file` means "not installed yet", so the item is installed on the next run.

## GitHub token

Without a token GitHub allows 60 API requests an hour, which a long list of items can use up. With one it's 5000, and unchanged release lists cost nothing (the scripts send each list's ETag back).

Put a token (no scopes needed) in `$GITHUB_TOKEN`, or on the first line of `~/.config/update-tools/github_token` with `chmod 600`. It's sent to api.github.com only, on curl's standard input, so it never shows up in the process list.

## Safety

- Downloads are staged next to the installed file, on the same disk, so installing is a rename and a half-written file is never visible. Ctrl+C removes the staged download.
- An HTTP error page is never installed: downloads fail on any HTTP error.
- Worlds must be valid zips, archives must contain an AppImage, and ISOs must match their upstream checksum before anything is replaced.
- The old version is set aside only once the new one has passed those checks, and is put back if the install fails or is interrupted. An interrupted run leaves either the old or the new version, never both and never neither.
- Ventoy lists every `.iso` on the drive, so staged and set-aside ISOs never end in `.iso`. Free space is checked before an ISO download.
- `-c` writes nothing at all, not even the date of the check.

## Layout

```
update-tools        the command
make-update-cfg     writes a new item's cfg from a link
lib/load.sh         loads the shared libraries
lib/main.sh         the mode loop and the one process_item every mode shares
lib/managers.sh     github, gitlab, static, jsonfeed, dirlist, dateprobe
lib/appimages.sh    AppImage hooks: archives, desktop entries, icons
lib/apworlds.sh     world hooks: zip checks, release zips with several worlds
lib/isos.sh         ISO hooks: checksums, free space, folder=
lib/…               config files, network, progress display, files, flags
```

`CHANGELOG.md` lists every change, and the git history follows the same format back to the first version.

## Credits

Design and direction by Nykorin. The scripts were written with Claude (Anthropic), with modularization and later refactoring by Grok (xAI).
