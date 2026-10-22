# update-tools: portable-home experiment

> [!WARNING]
> **This branch is a dead end, kept for history.** It isn't maintained or meant to be used. The real project is on the `main` branch.

> [!IMPORTANT]
> **This project was written with AI.** Almost all of the code was written by AI assistants (Claude by Anthropic, and Grok by xAI), following the author's design and requests. Read anything here before running it.

On 2026-10-04 the AppImage updater was tried with isolated homes: each AppImage would run with its own home folder, while still looking like the rest of the desktop. The idea was dropped the same day (the author's decision), and `main` continued from the flat layout of 2026-09-29, where every AppImage runs with your normal home.

## How this version works

- **Layout:** one folder per app, `~/AppImages/NAME/`, holding the AppImage and `NAME.appimage.json` (where its updates come from), plus `~/AppImages/.shared-home/`.
- **Shared home:** symlinks to a list of theme and desktop settings in your real home (KDE and Qt, GTK, Kvantum, PulseAudio, …), so every app picks up the desktop's look.
- **Wrapper:** the script writes `NAME.appimage.sh` into each app's folder. When run, the wrapper mounts the app's home with **fuse-overlayfs**: the shared home as the lower layer, `NAME.appimage.home/` as the app's own writable layer. It points `HOME` and the XDG folders at the merged view, runs the AppImage, and unmounts when it exits.
- **Desktop entry:** built from the AppImage's own `.desktop`, with the icon it contains, and set to run the wrapper.
- **Updates:** github, gitlab, jsonfeed and static managers, read from the JSON metadata. Archived releases are unpacked, and the previous AppImage is kept as a `.bak`.

## Requirements

bash, `curl`, `jq`, `python3` (for GitLab), `fuse-overlayfs` and `fusermount`, plus `tar`/`unzip` for archived releases.

## History

1. A shared home alongside per-app portable homes.
2. Always-on portable homes through a separate `wrapper-script.appimage.sh`.
3. This version: the shared home mounted with fuse-overlayfs, and the wrapper built into the script.

The branch starts from the 2026-09-18 version on `main`. See `main`'s `CHANGELOG.md` (2026-10-04) for the same entries.
