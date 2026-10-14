# shellcheck shell=bash
# load.sh: loads every library the updaters use, in order. All of them are
# required: a missing one stops the updater with bash's "No such file" error.
# LIB_DIR follows symlinks, so an updater can be linked on its own (no lib/ link
# needed next to it).
LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# shellcheck source=lib/progress.sh
source "$LIB_DIR/progress.sh" || exit 1
# shellcheck source=lib/log.sh
source "$LIB_DIR/log.sh" || exit 1
# shellcheck source=lib/cli.sh
source "$LIB_DIR/cli.sh" || exit 1
# shellcheck source=lib/net.sh
source "$LIB_DIR/net.sh" || exit 1
# shellcheck source=lib/cfg.sh
source "$LIB_DIR/cfg.sh" || exit 1
# shellcheck source=lib/files.sh
source "$LIB_DIR/files.sh" || exit 1
# shellcheck source=lib/managers.sh
source "$LIB_DIR/managers.sh" || exit 1
# shellcheck source=lib/run.sh
source "$LIB_DIR/run.sh" || exit 1
# shellcheck source=lib/update-tools
source "$LIB_DIR/update-tools" || exit 1
