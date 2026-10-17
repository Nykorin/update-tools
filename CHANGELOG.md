# Changelog

All notable changes to the update-tools scripts. Dates are local time.

Contributors: user (design & direction), Claude (original scripts), Grok (modularization & later refactoring)

Each bullet starts with the file it touches. "both updaters" means `update-appimages.sh` and `update-apworlds.sh`.

## [2026-10-16]

### Added
- **lib/managers.sh, lib/cfg.sh:** A `repo_regex` cfg key (github and gitlab), used instead of `repo_filename` when a glob can't say it, like `SoH-.*(\.appimage|-Linux\.zip)` for a project that ships either a bare AppImage or a Linux zip. It's anchored to the whole asset name; a cfg must set exactly one of the two, and a regex that doesn't compile skips the item before any request. Within a release the first matching asset in GitHub's order wins *(Claude, directed by user)*
- **lib/managers.sh:** `repo_filename` takes alternatives separated by `|` (github and gitlab), like `SoH-*.appimage|SoH-*-Linux.zip` for a project that has shipped both a bare AppImage and a zip. The newest release with any match wins, and within a release the first alternative that matches; a single glob works as before. Without this, a release in the other format was skipped and the item kept reporting "up to date" on the last release in the old format *(Claude, directed by user)*

### Changed
- **lib/\*.sh:** Comments cleaned up: stale references to the old commands and "every updater" fixed (and one wrong one: `run.sh` said ISOs never contact GitHub), banners that repeated the file header removed, `-f` comments that meant curl's `-f` say so, and every comment wrapped at 80 columns. Code is unchanged *(Claude, directed by user)*
- **CLAUDE.md:** "Known open items" lists the bugs found in a full check on 2026-10-16 (static check ignoring the file name, two files after an interrupted rename, CRLF cfgs, `--root=`, the empty-cfg message, stale ISO `.part` files, stale docs), not fixed yet *(Claude, directed by user)*
- **lib/main.sh, lib/cli.sh:** `-f` also rebuilds an up-to-date AppImage's desktop entry and re-extracts its icon, as an update does (not with `-c`); without `-f` only a missing entry is recreated. The "up to date" line now comes after that work, as "updated to" does *(Claude, directed by user)*
- **lib/appimages.sh:** Desktop entries name their icon (`Icon=ICON`, from the AppImage's own `.desktop`) instead of pointing at a file, so the active icon theme supplies it when it has the app (DuckStation, Dusklight, ES-DE and LM Studio with the current theme), and a theme switch applies at once. The AppImage's own icons go into `~/.local/share/icons/hicolor/` as the fallback (was `~/AppImages/.icons/`), and every update reinstalls them, so a changed icon is no longer missed. Entries still pointing into `.icons/` are rebuilt on their next run *(Claude, directed by user)*

### Removed
- **lib/files.sh, lib/appimages.sh, lib/apworlds.sh:** `extract_archive` and `extract_member` are one function, `extract ARCHIVE DEST [MEMBER]` (unpack all into folder DEST, or one member to file DEST), with the format `case` once. Same commands and results for zip and the four tar formats; any other extension still returns 1 *(Claude, directed by user)*
- **lib/isos.sh, lib/cli.sh:** Two pass-through functions: `fetch_checksum` is now the ISOs' `item_prepare_check` hook itself (the hook only called it), and `mode_name` is folded into `set_mode`, its one caller. Behavior is unchanged *(Claude, directed by user)*
- **lib/managers.sh:** The `|` alternatives in `repo_filename` from earlier the same day, replaced by `repo_regex` before any cfg used them *(Claude, directed by user)*
- **lib/appimages.sh:** The `~/AppImages/.icons/` folder (no longer created or written; the existing one is left alone) *(Claude, directed by user)*
- **lib/appimages.sh:** The icon-theme lookup above, reverted the same day before any real run used it: desktop entries point at `~/AppImages/.icons/NAME.*` again, extracted once per app as before *(Claude, directed by user)*

### Fixed
- **lib/managers.sh:** A static item whose URL now lands on a different file (an edited `url=`, or a redirect to a new name) was reported up to date when the new file had the same size and date and the server sent no ETag, and the old file stayed installed. The check now also requires the saved version to end in the download's name; versions saved before names were in them are left to the other checks *(Claude)*
- **lib/appimages.sh:** An AppImage's icon was extracted only once, so a release with a new icon kept showing the old one; it's re-extracted on every install and update, replacing the old file even when the extension changes. An AppImage without an icon keeps whatever is in `.icons/` (an icon added by hand) *(Claude, directed by user)*

---

## [2026-10-14]

### Added
- **update-tools:** One command for everything: `-m`/`--mode` picks `app`/`appimages`, `apw`/`apworlds`, `iso`/`isos` or `all` (all three in turn; one that can't run, like an unplugged drive, is skipped with its error, the rest still run, and the run ends with `⚠ skipped: …` and exit 1; `-r` is refused with `all`). Without arguments it prints the help; other flags without `-m` are an error. The help lists every mode's folder *(Claude, directed by user)*
- **CLAUDE.md:** The project is a git repository; diffs and undo go through git, and commits happen only on request *(Claude, directed by user)*
- **CLAUDE.md:** Every change is committed as soon as it's made and checked, without asking (pushing, amending and rewriting history still need asking) *(Claude, directed by user)*
- **lib/update-tools:** One `main` and `run_items` for all three updaters, sourced like `common.sh`; each updater now only sets `ITEM_TYPE`, `ITEM_EXT`, `DEFAULT_DIR` and `NOT_FOUND_HINT` and defines `prepare_dir` (its other folders and leftover cleanup). Output is unchanged *(Claude, directed by user)*

### Changed
- **lib/main.sh:** Under `-m all`, a missing folder's error no longer suggests `-r DIR`, which `-m all` refuses; single modes keep the advice (`NOT_FOUND_HINT` is now just the question, the `-r` sentence is `ROOT_HINT`) *(Claude, directed by user)*
- **lib/main.sh, lib/appimages.sh, lib/apworlds.sh, lib/isos.sh:** One `process_item` for every mode, in `lib/main.sh`; the modules keep only what really differs, as hooks (`item_setup`, `item_prepare_check`, `item_preflight`, `item_stage`, `item_validate`, `item_extras`) with do-nothing defaults, plus `ITEM_LOCALS` for variables their hooks share. Output is unchanged *(Claude, directed by user)*
- **common.sh, all scripts:** `common.sh` is split into `lib/log.sh`, `lib/cli.sh`, `lib/net.sh`, `lib/cfg.sh`, `lib/files.sh`, `lib/managers.sh` and `lib/run.sh`, loaded with `lib/progress.sh` and `lib/update-tools` by a new `lib/load.sh`; every library is required, and a missing one stops the updater. The updaters find `lib/` through symlinks (`readlink -f`), so one can be linked on its own. Output is unchanged *(Claude, directed by user)*
- **all scripts:** One `cleanup` in `common.sh` is the EXIT trap (was `rm -f …; restore_previous; cleanup` calling a `cleanup` in each updater): it removes the GitHub headers file, `curl_run`'s log, `timed`'s files and every staged download or extraction folder, and puts back an old version still set aside. The staged-file globals (`tmp_download`, `tmp_extract_dir`, `DESKTOP_TMP`) moved there too, and the `[[ -n … ]]` guards before `rm` are gone, since `rm -f` ignores an empty name *(Claude, directed by user)*
- **all scripts:** The "up to date" step is the same in all three: nothing newer on the server, or `is_up_to_date`, leads to one shared result, `report_up_to_date` in `lib/update-tools` (the version, the cfg saved unless `-c`, and an AppImage's desktop entry refreshed). ISOs are compared inside `is_up_to_date` (`common.sh`, with `hash_file` moved there), by `iso_hash` against the checksum whatever the manager; update-isos fetches that checksum just before, with `fetch_checksum` (was `find_checksum_url` plus inline code) *(Claude, directed by user)*
- **update-isos.sh:** `iso_hash` is set right after the download verifies and `checksum_file` right after the checksum file is saved, instead of together on the line before `save_update_metadata`; that step is now the same in all three updaters *(Claude, directed by user)*
- **update-isos.sh:** Finding the latest version is the same block as in the other two updaters (the github ETag lines, `resolve_latest_asset`, a stop on a GitHub rate limit) instead of `resolve_iso`: ISOs may use any manager, github and gitlab included, need only `checksum` (each manager checks its own keys; was `url` and `checksum`), and use `asset_name`/`asset_url` and `remote_unchanged` directly (`iso_name`, `iso_url` and `nothing_newer` are gone). The checksum lookup is `find_checksum_url`, in the "up to date" step *(Claude, directed by user)*
- **all scripts:** Choosing the install name is one helper, `pick_name` in `common.sh`, and each updater ends that step with the same `pick_name …` and `target="$dir/$new_name"` lines (update-isos now uses `new_name` too): the upstream name if it ends in the updater's extension, else the installed file's name, else `NAME.AppImage`/`NAME.apworld`/`NAME.iso`, with a `-d` line when it falls back. ISOs gain the check, so a static URL landing on a name like `latest` is installed as an `.iso` Ventoy lists (verification still uses the upstream name) *(Claude, directed by user)*
- **CLAUDE.md:** How to read Archipelago's "Failed World Loads": `No module named 'worlds.NAME'` means the file name doesn't match its module folder, an `ImportError` from Archipelago's code means the world needs a newer Archipelago *(Claude, directed by user)*
- **all scripts:** During an install the old version (and a stray file already using the new name) is renamed into the item root's `.tmp/` as `PATH.previous` (`set_aside` in `common.sh`), deleted once the new one is in place, and renamed back if the install fails or the run is interrupted (the EXIT trap); a run killed outright is repaired at the next start (`recover_previous`). The set-aside and move are now one identical block in all three updaters: `mv -f`, the same comments and failure messages, `installed as …` then `deleted the old version, …` in `-d`, and `target` set at the end of choosing the name. Old ISOs wait in `_ISO/.tmp/` as `.previous`, which Ventoy doesn't list *(Claude, directed by user)*
- **all scripts:** The installed file's mode is one setting, `ITEM_MODE` in `item_settings`: `755` for AppImages (was `chmod +x`, which kept an archive's other mode bits), `644` for worlds, none for ISOs (exFAT) *(Claude, directed by user)*
- **all scripts:** The move into place uses the same names in all three, `new_file` (the file being installed; was `new_appimage` in update-appimages) and `target`, and ends with the same `-d` line, `installed as NAME` (new for worlds and ISOs) *(Claude, directed by user)*
- **update-appimages.sh:** A GitHub rate limit stops the run (`✗ stopping, N more appimage(s) not checked`), like update-apworlds, instead of skipping that app and trying GitHub again for the rest *(Claude, directed by user)*
- **all scripts:** The `-c` report and the "updated to" line come from one helper, `shown_version` in `common.sh`: the version, plus the file name when the version doesn't already contain it (a static version ends in the name, so `static-311-fake.AppImage (fake.AppImage)` is now `static-311-fake.AppImage`; worlds show the installed name instead of the target name, which is the same file) *(Claude, directed by user)*
- **all scripts:** The shared `process_item` steps now use the same lines: the `name` strip uses `ITEM_EXT`; the cfg debug line shows manager, version, installed file and last check everywhere (update-isos prints `folder` on its own line); "already checked today" falls back to the installed file and "up to date" shows the version just looked up; the github ETag block (with its debug lines) is the same in update-appimages and update-apworlds; the rate-limit stop message names the item type (`apworld(s)`, was `world(s)`); worlds' download failure says "Failed to download update for" like the others *(Claude, directed by user)*
- **all scripts:** Each updater's settings (`ITEM_EXT`, `USAGE_ABOUT`, `USAGE_ROOT`, `DEFAULT_DIR`, `NOT_FOUND_HINT`) are one `case` on `ITEM_TYPE` in `item_settings` (`lib/update-tools`); each updater now sets only `ITEM_TYPE`. `USAGE_ITEM` is replaced by `ITEM_EXT`, so the `-f` and `-d` help lines say `appimage`, `apworld` and `iso` (were `app`, `world` and `ISO`) *(Claude, directed by user)*
- **common.sh, update-isos.sh:** The ISO managers moved into `common.sh`: `dirlist` (with `list_dir`, `sort_newest` and `resolve_glob_url`) and `dateprobe` are cases in `resolve_latest_asset`, and static ISOs use the same static manager as AppImages and worlds (`static_head`). Static ISOs now download from where the URL redirected to, the URL whose name the checksum was looked up for, instead of following the redirect again; a relative checksum still sits next to the cfg's `url`. `-d` shows `latest (MANAGER)` and `download URL` for ISOs like the other two *(Claude, directed by user)*
- **common.sh, update-isos.sh:** Static items show their version as `static-SIZE-ETAG-NAME` (was `static-SIZE`, or the ETag without a size, and the file name for ISOs), leaving out what the server didn't send; ISO cfgs now save `current_version` too, and static ones `content_length`, `last_modified` and `etag` *(Claude, directed by user)*
- **all scripts:** `process_item` declares its own script-specific variables (they were `main`'s locals); `APPIMAGE_DIR` and `WORLDS_DIR` are gone, as `dir` holds the folder, and update-isos keeps the root as `ISO_DIR` *(Claude, directed by user)*
- **all scripts:** update-isos' root folder is `ISO_DIR` (was `ISO_ROOT`), and all three updaters copy their folder to `dir` first and check that it exists through `dir` *(Claude, directed by user)*
- **all scripts:** Each updater's required commands are listed in one `case` in `require_cmds` (`common.sh`); `main` passes its type (`app`, `apw`, `iso`) instead of the command names *(Claude, directed by user)*

### Removed
- **update-appimages.sh, update-apworlds.sh, update-isos.sh:** The three separate commands, replaced by `update-tools -m app|apw|iso`; their code is now `lib/appimages.sh`, `lib/apworlds.sh` and `lib/isos.sh`, each loaded only for its mode in its own subshell, and `lib/update-tools` is now `lib/main.sh`. `~/.local/bin/update-tools/` holds just an `update-tools` link (the three command links and the `lib` link are gone) *(Claude, directed by user)*
- **common.sh, progress.sh:** The fallback stubs that let the updaters run without `progress.sh`; it's required now *(Claude, directed by user)*
- **update-apworlds.sh, common.sh:** Renaming worlds after their module folder, the `install_name` override and the module-folder mismatch warning; worlds keep their upstream name like AppImages and ISOs (a name without `.apworld` keeps the installed name, or becomes `NAME.apworld` on a first install). All 124 current worlds already ship under their module name, and Archipelago reports a mismatch under "Failed World Loads" *(Claude, directed by user)*
- **update-appimages.sh, update-apworlds.sh, common.sh:** Archiving to `.old/`: one previous version per app in `.old/NAME/` (`stash_old`, `keep_stash`, `unstash`), and every replaced world in `.old/` (`backup_file`). The existing `.old/` folders are left alone *(Claude, directed by user)*
- **update-appimages.sh:** Re-setting `installed_file` from `installed_path` on an up-to-date check; `installed_path` is built from `installed_file`, so it never changed anything *(Claude, directed by user)*
- **update-isos.sh:** Clearing `tmp_download` after each use, which the other two don't do; the EXIT trap's `rm -f` of a file that's already gone is harmless *(Claude, directed by user)*
- **update-isos.sh:** Reading the root folder from `ISO_ROOT` in the environment, and finding `_ISO` when `-r` names the drive's mount point; `-r` now takes the `_ISO` folder itself *(user)*

### Fixed
- **common.sh:** A dirlist folder that failed to list (a slow or failing mirror) was treated like one with no match, so the lookup fell back to an older release and offered it as an update: Mint 22.2 for an installed 22.3, which a real run would have installed. Now a folder that gives no answer stops the item (`⚠ … could not list FOLDER, skipping`), only a 404/410 moves on to the next candidate, and dirlist never offers a file older than the installed one *(Claude)*
- **common.sh:** `sort_newest` read the `20` in a URL-encoded space as a version number, so SourceForge's `Docs%20Home/` link ranked above every release folder and used up one of the 3 tries; URL escapes are ignored now, and entries without a number rank last *(Claude)*
- **update-isos.sh:** When a checksum glob found nothing, the message showed an empty name (`no checksum file matches , skipping`) *(Claude)*
- **update-appimages.sh, update-apworlds.sh:** An item whose manager found nothing newer than its installed file (dateprobe, now available to all three) but whose file was missing went on to download from an empty URL; it's now skipped with `⚠ … is missing and the server has nothing newer`, like ISOs *(Claude)*
- **common.sh:** `shown_version` treated the file name as already shown whenever the version merely contained it (`static-…-pokemon_emerald.apworld` hid `emerald.apworld`); only a version that is the name or ends in `-NAME` counts now *(Claude)*
- **update-isos.sh:** A failed move into place (a full or read-only drive) went unnoticed: the old ISO was deleted anyway when the names differed, the cfg named the missing new one and the run said `✓ updated`; now the old ISO is kept and the item reports `✗ … could not install …, kept the old one` *(Claude)*
- **update-apworlds.sh:** A failed move into place still saved the cfg and said `✓ updated`, with the old world left in `.old/`; now the backup is moved back and nothing is saved. All three updaters use the same failure message (update-appimages said `could not install the new AppImage`) *(Claude)*
- **common.sh:** Ctrl+C (or a killed run) in `-d` mode left `timed`'s temp files in `/tmp`; the shared EXIT trap now removes them *(Claude)*
- **update-isos.sh:** Static ISOs asked the server for the size a second time before the free-space check; they reuse the size from the lookup *(Claude)*

---

## [2026-10-13]

### Added
- **all scripts:** `-h`/`--help` and a fuller usage text, and `-r`/`--root DIR` for update-appimages (`APPIMAGE_DIR`) and update-apworlds (`WORLDS_DIR`), like update-isos; all flags are parsed once by `parse_flags` in `common.sh`, and a missing item folder is now an error instead of being created *(Claude, directed by user)*
- **update-isos.sh:** New updater for the ISOs on the Ventoy drive (`/mnt/ventoy/_ISO`), sharing `common.sh` and `progress.sh`: one cfg next to each ISO, required checksum verification before anything is replaced, the old ISO deleted only once the new one verifies, staged `.part` downloads that Ventoy can't list, a free-space check, and `-n`/`--check` *(Claude, directed by user)*
- **update-isos.sh:** `dirlist` manager (newest file from the server's folder listings, including SourceForge), `static` (name taken from where the URL lands) and `dateprobe` (for Nobara's unlisted bucket) *(Claude, directed by user)*
- **common.sh:** `load_cfg` clears the ISO cfg keys between items *(Claude, directed by user)*
- **update-isos.sh:** `-r`/`--root DIR` to work on the drive wherever it's mounted; DIR can be the `_ISO` folder or the drive's mount point *(Claude, directed by user)*
- **update-appimages.sh, update-apworlds.sh:** `-c`/`--check`: look up and compare every item, report `⬆ update available: …`, and download or write nothing *(Claude, directed by user)*
- **update-appimages.sh:** First installs: a cfg whose AppImage isn't there yet is downloaded and installed (under its upstream name) instead of being skipped with "no AppImage found" *(Claude, directed by user)*
- **all scripts:** `-d`/`--debug` (or `DEBUG=1`) prints a decision trace: cfg values, each request and its HTTP status, cache hits, the versions or checksums compared, and the download steps *(Claude, directed by user)*
- **all scripts:** In debug mode each item's time and the run's total are shown, measured with bash's `time` keyword *(Claude, directed by user)*

### Changed
- **update-isos.sh:** ISO cfgs live in `_ISO/.cfg/` like the other two updaters' cfgs instead of next to each ISO; a new `folder` key names the ISO's folder relative to the root, and a missing folder is created on first install. The 17 cfgs on the Ventoy drive were moved to match *(Claude, directed by user)*
- **all scripts:** The GitHub headers file, the EXIT trap and the token load are one shared `start_run` in `common.sh`; the trap removes the headers file, then calls the script's own `cleanup` *(Claude, directed by user)*
- **all scripts:** The help text is one shared `usage` in `common.sh`; each updater fills in `USAGE_ABOUT`, `USAGE_ITEM` and `USAGE_ROOT` (the output is unchanged) *(Claude, directed by user)*
- **update-appimages.sh, update-apworlds.sh:** The item folder is `dir` in all three updaters (was `APPIMAGES_DIR` and `WORLDS_DIR`); `WORLDS_DIR` stays as the environment variable that points update-apworlds at another folder *(Claude, directed by user)*
- **update-appimages.sh, update-apworlds.sh:** The item-name variable is `name` in all three updaters (was `app_name` and `world_name`) *(Claude, directed by user)*
- **all scripts:** The staged download is `tmp_download` everywhere, each script's EXIT trap calls a `cleanup` function, and staged files use fixed names: `.tmp/download-ASSET` (plus `archive/` and `desktop/` folders) for AppImages, which renamed `STAGE_DIR` to `TMP_DIR`; `.tmp/download.zip` and `extracted.apworld` for worlds; `.NAME.iso.part` next to the ISO for ISOs, which renamed `PART_FILE` and now also removes `.iso.part` files left by a killed run at start. New AppImages are mode `755` instead of `711` *(Claude, directed by user)*
- **all scripts:** The three `process_item` functions follow the same step order and spacing; `-d` gains matching "installed file" / "not installed yet" and "downloaded to" lines where a script lacked them *(Claude, directed by user)*
- **update-isos.sh:** The check-only flag is now `-c`/`--check` (was `-n`), the same as in the other two *(Claude, directed by user)*
- **all scripts:** `common.sh` and `progress.sh` moved to `lib/`, and the project moved to `~/Libraries/Projects/ClaudeCode/update-tools`; `~/.local/bin/update-tools/` now holds symlinks to the three updaters and `lib/` *(user; symlinks by Claude, directed by user)*
- **update-appimages.sh:** AppImages keep their upstream name and casing (e.g. `PopTracker-0.35.4-x86_64.AppImage`) instead of being renamed after the cfg; `installed_file` tracks the file, older cfgs are found by the old `NAME.appimage` name, and backups go to `.old/NAME/` (one previous version per app, kept intact if an install fails) *(Claude, directed by user)*
- **update-isos.sh:** The ISO cfg key `current_file` is now `installed_file`, the name the other two updaters use; the 17 cfgs on the Ventoy drive were renamed to match *(Claude, directed by user)*
- **all scripts:** Every cfg write goes through `save_update_metadata`, which now walks the script-written keys with a `case` per key and takes each value from the item being handled (`update-isos` used to call `update_cfg` itself); a first-run `iso_hash` is now saved with that run's successful check instead of right after hashing *(Claude, directed by user)*
- **update-appimages.sh, update-isos.sh:** The installed file's path is `installed_path` in all three updaters (was `appimage_file` and `local_path`) *(Claude, directed by user)*
- **all scripts:** The "is the cfg's `installed_file` still there" lookup is one shared helper, `find_installed DIR` in `common.sh`, instead of a copy in each updater *(Claude, directed by user)*
- **all scripts:** Each per-item loop body is now a `process_item` function (called by `run_items`) so it can be timed; output without `-d` is unchanged *(Claude, directed by user)*

### Removed
- **update-apworlds.sh:** Reading `WORLDS_DIR` from the environment; use `-r DIR` *(Claude, directed by user)*
- **update-appimages.sh:** The fallback that found an AppImage named after its cfg (`NAME.appimage`) when the cfg had no `installed_file`; every cfg now has one, and a cfg without it is a first install *(Claude, directed by user)*

### Fixed
- **progress.sh:** Ctrl+C during a download left `curl_run`'s output log in `/tmp`; the shared EXIT trap now removes it *(Claude)*
- **common.sh:** `load_cfg` accepts only known keys and reports others; any `key=value` used to be set as a variable, so `dir=` in an ISO cfg moved where the ISO was installed *(Claude)*
- **common.sh:** A static or jsonfeed cfg missing a required key, or a feed version without a dot, aborted the whole run (`unbound variable`); the item is now skipped with a named message *(Claude)*
- **all scripts:** Network requests had no timeouts, so a server that never answered hung the run forever; requests now time out and downloads give up after 60 s of stalling *(Claude)*
- **common.sh:** Renamed or transferred GitHub repos (HTTP 301) failed; redirects are now followed, and `-d` reports the move *(Claude)*
- **common.sh:** A static item whose HEAD request failed (404, timeout) went on to a doomed download; it's now skipped *(Claude)*
- **update-isos.sh:** A `-r` path containing a hidden folder found no cfgs and printed nothing; hidden folders are skipped only below the root *(Claude)*
- **all scripts:** A run with no cfgs now says so instead of printing nothing *(Claude)*
- **update-isos.sh:** Nobara (`dateprobe`) warned on every run once the installed build was removed from the server; nothing newer now means up to date *(Claude)*
- **update-isos.sh:** An absolute `checksum` URL only counted as absolute if it started with `http` *(Claude)*
- **update-appimages.sh:** Downloads went to RAM-backed `/tmp` and were copied across to `~/AppImages` after the old AppImage was already moved to `.old/`; they're now staged in `~/AppImages/.tmp/`, installed with a rename, and the old one is put back if that fails *(Claude)*
- **update-appimages.sh, update-apworlds.sh:** Ctrl+C left staged downloads behind (in RAM for AppImages, in `.tmp/` for worlds); they're now removed on exit, and stale ones are cleared at start *(Claude)*
- **common.sh:** A GitLab `repo_url` ending in `/` or `.git` gave a 404 *(Claude)*
- **common.sh:** `repo_filename` only treated `*` and `.` specially, so `+ ( ) { } | ^ $` acted as regex; it's now a proper glob (`*`, `?`, `[…]`) *(Claude)*
- **common.sh:** Static items on servers that send no `Content-Length` were never up to date and re-downloaded every run; their `ETag` is now compared too *(Claude)*
- **common.sh:** Debug timings could show a broken digit (`0.:0` for 1.00) because of a rounding bug in bash 5.3's `time` output; the digits are now read by value *(Claude)*
- **update-appimages.sh:** Downloads use `curl -f`; without it an HTTP error page (e.g. a 404) was saved as the AppImage, the working one was moved to `.old/`, and the run reported `✓ updated` *(Claude)*
- **common.sh:** GitHub release lists past the first 100 releases are now fetched page by page, only while no matching asset has been found, so older assets in big repos can be found *(Claude, directed by user)*
- **common.sh:** GitLab assets are named after the release link's `name` instead of the URL's last part, which was often `download` or carried a `?job=…` query string *(Claude)*
- **update-apworlds.sh:** When an `.apworld` has no single module folder, the fallback name is the extracted `.apworld`'s name for bundles (not the outer `.zip`), and `NAME.apworld` when the asset name doesn't end in `.apworld`; a world is never installed without the `.apworld` extension *(Claude)*

---

## [2026-10-12]

### Added
- **all scripts:** Modular layout: `common.sh`, `progress.sh`, `update-appimages.sh`, `update-apworlds.sh` *(Grok)*
- **common.sh:** Created as the shared library for both updaters *(Grok)*
- **common.sh:** Shared GitHub token support (`~/.config/update-tools/github_token` or `$GITHUB_TOKEN`) *(Grok)*
- **common.sh:** GitHub API rate-limit tracking and end-of-run summary *(Grok)*
- **common.sh:** `allow_prereleases=auto|false|true` for GitHub releases (prefer stable, fall back to pre-release) *(Grok; logic originated in apworlds script by Claude)*
- **common.sh:** `resolve_latest_asset` and `is_up_to_date` for all managers *(Grok)*
- **common.sh:** `save_update_metadata` helper to unify post-update config writes *(Grok)*
- **common.sh:** `extract_archive` and `extract_member` helpers (zip + tar variants) *(Grok)*
- **common.sh:** `require_cmds` dependency checker *(Grok)*
- **common.sh:** Generic `backup_file` helper *(Grok)*
- **common.sh:** Fallback stubs for progress UI so scripts work if `progress.sh` is missing *(Grok)*
- **progress.sh:** Optional live two-line progress/status block (`progress.sh`) with graceful fallback if missing *(Grok)*
- **progress.sh:** `say` / `status` / `status_final` / `commit_final` messaging *(Grok)*
- **progress.sh:** curl progress-bar takeover/handback helpers *(Grok)*
- **update-apworlds.sh:** Port of the apworlds updater into the same modular framework *(Grok)*
- **update-apworlds.sh:** `extract_member` used for single-file extraction from zip/tar bundles *(Grok)*
- **both updaters:** Daily skip via `last_checked` + `-f`/`--force` flag on both scripts *(Grok; ported from apworlds)*
- **both updaters:** `main()` entry points so scripts can be run from any working directory *(Grok)*
- **update-appimages.sh:** Optional GitHub token (`$GITHUB_TOKEN` or a token file), sent with `curl -H @-` so it never appears in `ps` output; first built in the monolithic script, later moved into `common.sh` *(Claude, directed by user; moved by Grok)*
- **update-appimages.sh:** GitHub request-limit tracker: reads GitHub's `x-ratelimit-*` response headers (no extra requests) and shows requests left, reset time and requests used on the final line; first built in the monolithic script, later moved into `common.sh` *(Claude, directed by user; moved by Grok)*
- **common.sh:** Each GitHub repo's release list is fetched once per run and shared by every world or app using that repo *(Claude, directed by user)*
- **update-apworlds.sh:** A GitHub rate limit (429, or 403 mentioning "rate limit") stops the run; the AppImage script skips instead *(Claude, directed by user)*
- **common.sh, both updaters:** GitHub conditional requests: each github cfg saves the release list's `etag`, and the next check sends it as `If-None-Match`; an unchanged list comes back as 304, which GitHub doesn't count against the limit when a token is used. `-f`, and worlds that still need installing, always fetch the full list *(Claude, directed by user)*

### Changed
- **update-appimages.sh:** Rewritten as a thin script sourcing `common.sh` + optional `progress.sh` *(Grok)*
- **update-appimages.sh:** GitHub asset selection searches the full releases list (no longer limited to `/latest`) *(Grok)*
- **update-apworlds.sh:** Uses shared `resolve_latest_asset`, `is_up_to_date`, `save_update_metadata`, etc. *(Grok)*
- **update-apworlds.sh:** Retains domain-specific logic: `unbundle_apworld`, `install_name`, module-folder validation *(Claude original; kept by Grok)*
- **common.sh:** Single shared token path for both scripts *(Grok, per user direction)*

### Removed
- **both updaters:** Per-script GitHub token paths *(Grok)*

### Fixed
- **update-appimages.sh:** Icon-theme icons are picked by version sort (`scalable` first, else the largest size) instead of whichever `find` returned first, which could be a 16x16 *(Claude)*
- **update-appimages.sh:** A missing `.desktop` entry is now recreated even on an “already checked today” run *(Claude)*
- **update-appimages.sh:** Restored the 󰴚 desktop-entry status wording (“desktop entry built from embedded metadata”) *(Claude)*
- **update-appimages.sh, common.sh:** Warning and error lines name the app again; the ones raised in the shared `resolve_latest_asset` use the progress label, so both updaters benefit *(Claude)*
- **update-apworlds.sh:** Warning and error lines name the world *(Claude, directed by user)*
- **update-apworlds.sh:** Bundle zips were never extracted, because the staged download had no `.zip` extension *(Claude)*
- **common.sh:** Static downloads failed when the URL redirected to a signed link, because its query string ended up in the file name *(Claude)*
- **common.sh:** GitHub lookups only saw a repo's 30 newest releases, so worlds in repos hosting several games (Zelda 2) could never be found; now 100 *(Claude, directed by user)*
- **common.sh:** GitHub 404s, other HTTP errors and no-response are reported as such instead of "could not resolve download URL" *(Claude)*
- **update-apworlds.sh:** The file list for a bundle with several `.apworld` files was printed into the live status block on a terminal, overwriting part of it; it now goes through `say` *(Claude)*
- **progress.sh, both updaters:** A failed download no longer leaves a stray `NAME ⬆ updating` / `⬇ installing` line above curl's error; downloads run through the new `curl_run`, which counts the rows curl used (wrapped errors, trailing blank lines) so `curl_abandon` can delete that line *(Claude)*
- **update-appimages.sh:** `generate_desktop_entry` creates `~/.local/share/applications` when it is missing, instead of failing with a raw bash error on a fresh HOME *(Claude)*
- **common.sh:** GitLab API errors are reported (404, other HTTP errors, no response) instead of "could not resolve download URL"; a 429 skips the remaining GitLab items without further requests, while other managers carry on *(Claude)*
- **common.sh, both updaters:** Rolling GitHub releases (`latest`, `continuous`, e.g. DuckStation) never updated, because only the tag was compared; the asset's sha256 digest is now saved as `asset_digest` and compared too. Cfgs without it are checked once against the installed file's sha256 *(Claude, directed by user)*
- **all scripts:** shellcheck is clean (`shellcheck` on each file exits 0): the updaters' `source` directives point at `common.sh` and `progress.sh`, a new `.shellcheckrc` lets shellcheck follow them, and `common.sh` documents the cfg keys it can't see *(Claude, directed by user)*

---

## [2026-10-08]

### Added
- **update-apworlds.sh:** Adapted from the AppImage script for Archipelago `.apworld` files *(Claude, directed by user)*
- **update-apworlds.sh:** Bundle-zip handling (`unbundle_apworld`) *(Claude, directed by user)*
- **update-apworlds.sh:** `install_name` override and module-folder validation *(Claude, directed by user)*
- **update-apworlds.sh:** Per-URL JSON caching and early exit on rate-limit responses *(Claude, directed by user)*
- **update-apworlds.sh:** Daily `last_checked` skip logic *(Claude, directed by user; later ported to AppImages by Grok)*
- **update-apworlds.sh:** `-f`/`--force` flag to ignore the daily `last_checked` skip *(Claude, directed by user)*
- **update-apworlds.sh:** `allow_prereleases=auto|false|true`, with each world matched against the newest release that contains its asset so several worlds can share one repo *(Claude, directed by user)*
- **update-apworlds.sh:** Downloads staged in a same-filesystem `.tmp/` folder and checked as valid zips before the installed world is replaced *(Claude, directed by user)*
- **make-apworld-cfgs.sh:** Helper that creates an empty `.cfg` for every installed `.apworld` *(Claude, directed by user)*
- **update-appimages.sh:** Two-line live status block redrawn in place with ANSI cursor codes (app name + status above an overall `[####....] N% (n/N)` bar); curl's own progress bar takes over the bar line during a download; first built in the monolithic script, later split out as `progress.sh` *(Claude, directed by user; moved by Grok)*

### Fixed
- **update-apworlds.sh:** Static manager response headers were joined onto one line, so `content_length` read the redirect's status code *(Claude)*
- **update-apworlds.sh:** `update_cfg` no longer glues a new key onto a `.cfg` whose last line lacks a trailing newline *(Claude)*

---

## [2026-10-07]

### Added
- **update-appimages.sh:** Safe config loader (`load_cfg`) — never executes `.cfg` files as shell code *(Claude)*
- **update-appimages.sh:** Overall progress bar, one step per app (single line, status messages printed above it) *(Claude, directed by user)*

### Changed
- **update-appimages.sh:** Local metadata moved from JSON (`.appimage.json`) to plain `key=value` `.cfg` files *(Grok, per user direction)*
- **update-appimages.sh:** AppImages layout flattened: binaries in `~/AppImages/`, configs in `.cfg/`, icons in `.icons/`, backups in `.old/` *(Grok, per user direction)* — built up in steps: flat layout and `.icons/` 2026-09-29, `.json/` 2026-10-04, `.old/` 2026-10-06, `.cfg/` 2026-10-07
- **update-appimages.sh:** Desktop entries only created when missing on “up to date” runs; always regenerated after a real update *(Grok)*
- **update-appimages.sh:** Iterative simplification: unified “up to date” handling, `ensure_desktop_entry` *(Grok / Claude, directed by user)*
- **update-appimages.sh:** Icon search simplified into an ordered tier list (root level, icon-theme folder, anywhere) that stops at the first hit *(Claude, directed by user)*

### Removed
- **update-appimages.sh:** `python3` dependency — URL-encoding done in pure bash/sed *(Grok)*
- **update-appimages.sh:** Local `jq` dependency for config files (still used for remote API responses) *(Grok)*

### Fixed
- **update-appimages.sh:** Values containing spaces (e.g. `last_modified`) properly quoted in `.cfg` files *(Grok)*
- **update-appimages.sh:** `sed` replacement escaping for `\`, `&`, and `|` *(Claude)*
- **update-appimages.sh:** Redundant subshells and pipes cleaned up (`find -print -quit`, `${var##*/}`, etc.) *(Grok)*
- **update-appimages.sh:** Static manager headers were rebuilt with `${curl_out[*]}`, which joined them onto one line, so `content_length` read the redirect's status code and the app re-downloaded on every run *(Claude)*

---

## [2026-10-06]

### Fixed
- **update-appimages.sh:** Static manager redirect handling (resolves final URL before naming the asset) *(Grok / Claude)* — merged into a single curl call 2026-10-07

---

## [2026-10-04]

### Removed
- **update-appimages.sh:** Per-app portable HOME / `.shared-home` / fuse-overlayfs support *(user decision; removed by Grok)* — the `.shared-home` / fuse-overlayfs variant only existed on this day
- **update-appimages.sh:** Wrapper script generation *(user decision; removed by Grok)*

---

## [2026-09-29]

### Removed
- **update-appimages.sh:** Removal of unused portable-home logic *(user decision)*

---

## Earlier (on or before 2026-09-18)

### Added
- **update-appimages.sh:** Original monolithic script with per-app subdirectories and JSON metadata *(Claude, directed by user)*
- **update-appimages.sh:** github / gitlab / jsonfeed / static managers *(Claude, directed by user)*
- **update-appimages.sh:** Desktop entry + icon extraction from AppImage contents *(Claude, directed by user)*
- **update-appimages.sh:** Archive downloads (tar/zip containing an AppImage) *(Claude, directed by user)*
