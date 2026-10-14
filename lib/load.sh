# shellcheck shell=bash
# load.sh: loads every shared library, in order; main.sh loads the mode's own
# module (appimages.sh, apworlds.sh, isos.sh) later. All of them are required: a
# missing one stops update-tools with bash's "No such file" error. LIB_DIR
# follows symlinks, so update-tools can be linked on its own.
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
# shellcheck source=lib/main.sh
source "$LIB_DIR/main.sh" || exit 1
