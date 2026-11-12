# update-tools

Bash scripts that keep three kinds of downloaded software up to date:

- **AppImages**, each with a desktop entry and icon extracted from the AppImage itself
- **Archipelago custom worlds** (`.apworld` files), including worlds shipped inside a mod's release zip
- **ISOs on a Ventoy drive**, every download checksum-verified before it replaces anything

Each item is described by a small JSON config file that says where its new versions come from: a GitHub or GitLab release, a fixed download URL, a JSON feed, a web server's folder listing, or a dated file name. One command, `update-tools`, checks the items and installs what changed: on a terminal it opens a menu to pick what to check and which updates to download, and `-m` runs one kind (or all three) without it.

> [!IMPORTANT]
> **This project was written with AI.** Almost all of the code and documentation was written by AI assistants (Claude by Anthropic, and Grok by xAI), following the author's design, requests and review. The author tested it on their own Linux system, with their own AppImages, Archipelago worlds and Ventoy drive, but it has not been reviewed or tested by anyone else. Read the scripts before running them, try `-c` (check only) first, and keep backups of anything you point it at. It comes with no warranty. `CHANGELOG.md` and the git history credit each change to the user, Claude or Grok.

On Windows, a PowerShell port of the worlds and ISO modes is in [`windows/`](windows/README.md).

## Requirements

- bash 4.3 or newer, and the usual tools (`awk`, `sed`, `find`, `df`)
- `curl` for every mode
- `jq` (every mode reads its config files with it)
- `unzip` for worlds (and for AppImages released as zips; `tar` for `.tar.*` ones)
- `sha256sum` and `sha512sum` for ISOs
- `fzf`, optional, for the menu

Each command checks for what it needs and says what's missing.

## Install

```sh
git clone https://github.com/Nykorin/update-tools.git
mkdir -p ~/.local/bin
for c in update-tools make-update-cfg; do
    ln -s "$PWD/update-tools/$c" ~/.local/bin/"$c"
done
```

Both commands find their `lib/` folder through the symlink, so they can be linked from anywhere on your `PATH`.

### Settings

Each mode works in one folder, set in `~/.config/update-tools/update-tools.cfg` (or under `$XDG_CONFIG_HOME`), which also says how often an item is checked:

```ini
app_dir=~/AppImages
apw_dir=~/Games/Archipelago/custom_worlds
iso_dir=/run/media/me/Ventoy
# skip items checked in the last skip_hours hours (168: weekly); off: check every item every run
skip_checked=on
skip_hours=24
```

The file is read as `key=value` data, never run as shell code (comments go on their own lines); a leading `~` or `$HOME` is expanded. AppImages default to `~/AppImages`. Worlds and ISOs have no default: until their key is set, their mode stops with a message naming it. `-m MODE -r DIR` overrides a mode's folder for one run, and `-h` lists the folders in use.

## Usage

```sh
update-tools                 # the menu (on a terminal, with fzf)
update-tools -m apw          # update the worlds
update-tools -m iso -c       # only check the ISOs, download nothing
update-tools -m iso -r /run/media/me/Ventoy
update-tools -m all          # all three in turn, no menu
```

Without `-m`, on a terminal, `update-tools` opens a menu ([fzf](https://github.com/junegunn/fzf)):

1. **What to update:** the kinds whose folder is there (Tab marks several, Enter takes them, Esc quits). Kinds that can't run are named above the list, with the reason.
2. **For each kind:** the first line, *check all for updates*, checks every item without downloading anything; or mark single items to update just those. Esc goes back.
3. **After the check:** the screen is cleared and a list of the updates found opens, all marked, with each kind's summary above it. Unmark what you don't want and press Enter to download the rest, or Esc to download nothing. The check's full output is in `~/.cache/update-tools/check.log` (or under `$XDG_CACHE_HOME`), kept until the next check. With `-c`, the run stops after the check and its output stays on screen.

Without a terminal (cron, a pipe) or without fzf, it runs all three, as `-m all` does. Several kinds run in order, each under a heading. One that can't run (its folder missing, or a command it needs) prints why and the others still run; the run then ends with a list of what was skipped.

| Option | Meaning |
|---|---|
| `-m`, `--mode MODE` | `app`, `apw`, `iso` or `all`; skips the menu |
| `-c`, `--check` | look up and compare, then report what would be updated; downloads and writes nothing |
| `-f`, `--force` | check items checked within `skip_hours` too; for AppImages, also rebuild each desktop entry and icon |
| `-r`, `--root DIR` | use DIR instead of the folder set in the settings (only with `-m app`, `apw` or `iso`) |
| `-d`, `--debug` | explain each decision and time each item (or `DEBUG=1`) |
| `-h`, `--help` | show the help |

Each item is checked at most once per `skip_hours` (24 by default) unless `-f` is given or `skip_checked=off`. On a terminal the output is a live two-line status block with an overall progress bar; redirected output is plain text without escape codes. Each run ends with a summary per kind: how many items were updated, installed, up to date or checked recently, and by name the ones with an update available (`-c`) and the ones skipped or failed, so a problem in a long run can't hide in the scrollback. When GitHub requests were made, the last line shows how many of the hourly request budget are left.

## Adding an item

### With make-update-cfg

```sh
make-update-cfg -m app https://github.com/TwilitRealm/dusklight
make-update-cfg -m apw -p https://github.com/OrcThrowman/7-Days-to-Die-AP
make-update-cfg -m iso -u https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso archlinux
```

`-m` is `app`, `apw` or `iso`; the link comes next or after `-u`, then an optional name for the cfg. It reads the link, writes the cfg, and checks it with the same lookup the updaters use before saving it. The next `update-tools` run for that kind installs the item.

- **GitHub or GitLab projects:** it takes the latest stable release with something installable (`-l`, the default), or with `-p` the newest release, pre-releases included; the cfg then keeps to that choice (`"allow_prereleases": "false"` or `"true"`). It ignores builds for other systems and architectures, and turns the file name into a pattern that matches later versions. If several files are left, it lists them; pass the link of the one you want instead.
- **Any other link:** it becomes a fixed download.
- **ISOs:** it also looks for a checksum file next to the ISO. Set `"folder"` to the ISO's folder on the drive afterwards.

It never overwrites an existing cfg.

### By hand

Each mode's folder holds the scripts' own hidden folder (hidden, so Archipelago and Ventoy pass it over):

```
.update-tools/
├── db/      the cfgs (NAME.json), and your own desktop entries (NAME.desktop, AppImages)
├── icons/   AppImages only: the extracted icons; link ~/.icons to it for icons your theme lacks
└── tmp/     staged downloads, and the old version during an install (for ISOs, only then)
```

Each item has a cfg in its mode's folder, as `.update-tools/db/NAME.json`: a JSON object whose values are text. The scripts read only the keys below (any other is reported and ignored), and keep what they write themselves under `"state"`. JSON has no comments, so a cfg can hold a `"comment"`, which the scripts ignore; `make-update-cfg` puts the link there.

```jsonc
// ~/AppImages/.update-tools/db/dusklight.json
{
  "manager": "github",
  "repo": "TwilitRealm/dusklight",
  "repo_filename": "Dusklight-*-linux-x86_64.AppImage"
}
```

```jsonc
// custom_worlds/.update-tools/db/7dtd_world.json
{
  "manager": "github",
  "repo": "OrcThrowman/7-Days-to-Die-AP",
  "repo_filename": "*.apworld"
}
```

```jsonc
// .update-tools/db/archlinux.json in the ISO folder
{
  "folder": "Linux/ArchLinux",
  "manager": "static",
  "url": "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso",
  "checksum": "sha256sums.txt"
}
```

(The `//` lines only say where each file goes; they can't be in the file.) In JSON a `\` or `"` inside a value needs a backslash: `"repo_regex": "SoH-.*(\\.appimage|-Linux\\.zip)"`.

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

AppImages can set:

| Key | Meaning |
|---|---|
| `icon_name` | the icon name the desktop entry uses, for an icon theme that names the app differently |
| `install_name` | install the AppImage under this name instead of its upstream one (`{name}` is the cfg's name; `.AppImage` is added if missing). An app already installed under another name is renamed on its next run |

An AppImage's desktop entry is built from the `.desktop` file inside it. To use your own instead, put it next to the cfg as `.update-tools/db/NAME.desktop`; `{appimage}` in it stands for the installed AppImage's path (`Exec=env DESKTOPINTEGRATION=1 {appimage} %u`). It's written whenever it changes, on the next run.

The scripts add their own keys under `"state"` after each check (`current_version`, `installed_file`, `last_checked`, ETags, digests, `iso_hash`). Leave those alone; a cfg without `installed_file` means "not installed yet", so the item is installed on the next run.

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
update-tools        updates AppImages, worlds and ISOs (-m, or the menu)
make-update-cfg     writes a new item's cfg from a link
lib/load.sh         loads the shared libraries
lib/main.sh         the command, the mode loop and the one process_item every mode shares
lib/menu.sh         the fzf menu
lib/managers.sh     github, gitlab, static, jsonfeed, dirlist, dateprobe
lib/appimages.sh    AppImage hooks: archives, desktop entries, icons
lib/apworlds.sh     world hooks: zip checks, release zips with several worlds
lib/isos.sh         ISO hooks: checksums, free space, "folder"
lib/…               config files, network, progress display, files, flags
windows/            the PowerShell port for worlds and ISOs
```

`CHANGELOG.md` lists every change, and the git history follows the same format back to the first version.

## Credits

Design and direction by Nykorin. The scripts were written with Claude (Anthropic), with modularization and later refactoring by Grok (xAI).

## License

MIT, see [LICENSE](LICENSE).
