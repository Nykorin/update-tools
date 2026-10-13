# Changelog

All notable changes to the update-tools scripts. Dates are local time.

Contributors: user (design & direction), Claude (original scripts), Grok (modularization & later refactoring)

Each bullet starts with the file it touches. "both updaters" means `update-appimages.sh` and `update-apworlds.sh`.

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
