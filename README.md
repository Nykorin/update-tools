# update-tools

Bash scripts that keep three kinds of downloaded software up to date:

- **AppImages**, each with a desktop entry and icon extracted from the AppImage itself
- **Archipelago custom worlds** (`.apworld` files), including worlds shipped inside a mod's release zip
- **ISOs on a Ventoy drive**, every download checksum-verified before it replaces anything

Each item is described by a small JSON config file that says where its new versions come from: a GitHub or GitLab release, a fixed download URL, a JSON feed, a web server's folder listing, or a dated file name. One command, `update-tools`, checks the items and installs what changed: on a terminal it opens a menu to pick what to check and which updates to download, and `-m` runs one kind (or all three) without it.

> [!IMPORTANT]
> **This project was written with AI.** Almost all of the code and documentation was written by AI assistants (Claude by Anthropic, and Grok by xAI), following the author's design, requests and review. The author tested it on their own Linux system, with their own AppImages, Archipelago worlds and Ventoy drive, but it has not been reviewed or tested by anyone else. Read the scripts before running them, try `-c` (check only) first, and keep backups of anything you point it at. It comes with no warranty. `CHANGELOG.md` and the git history credit each change to the user, Claude or Grok.

On Windows, a PowerShell port of the worlds and ISO modes is on the [`windows`](https://github.com/Nykorin/update-tools/tree/windows/windows) branch, in its `windows/` folder.

## Quick start

Needs bash 4.3+, `curl` and `jq`; `unzip` for worlds, `sha256sum`/`sha512sum` for ISOs, and `fzf` for the menu ([full list](https://github.com/Nykorin/update-tools/wiki/Installation#requirements)).

```sh
git clone https://github.com/Nykorin/update-tools.git
mkdir -p ~/.local/bin
ln -s "$PWD/update-tools/update-tools" ~/.local/bin/update-tools
```

Set each kind's folder in `~/.config/update-tools/update-tools.cfg` (AppImages default to `~/AppImages`):

```ini
app_dir=~/AppImages
apw_dir=~/Games/Archipelago/custom_worlds
iso_dir=/run/media/me/Ventoy
```

Then add items and run it:

```sh
update-tools make -m app https://github.com/TwilitRealm/dusklight   # write a cfg from a link
update-tools -m app -c       # check, download nothing
update-tools                 # the menu
update-tools -h              # the help, and its topics
```

## Documentation

The [wiki](https://github.com/Nykorin/update-tools/wiki) has the rest:

- [Installation](https://github.com/Nykorin/update-tools/wiki/Installation): requirements, the settings file, a GitHub token
- [Usage](https://github.com/Nykorin/update-tools/wiki/Usage): the menu, the options, the output and the session log
- [Adding items](https://github.com/Nykorin/update-tools/wiki/Adding-items): `update-tools make`
- [Cfg reference](https://github.com/Nykorin/update-tools/wiki/Cfg-reference): the cfg format, the managers and every key
- [Removing AppImages](https://github.com/Nykorin/update-tools/wiki/Removing-AppImages): `update-tools remove`
- [Safety](https://github.com/Nykorin/update-tools/wiki/Safety): how downloads are checked and installed
- [Windows](https://github.com/Nykorin/update-tools/wiki/Windows): the PowerShell port
- [Development](https://github.com/Nykorin/update-tools/wiki/Development): the source layout and the changelog

## Credits

Design and direction by Nykorin. The scripts were written with Claude (Anthropic), with modularization and later refactoring by Grok (xAI).

## License

MIT, see [LICENSE](LICENSE).
