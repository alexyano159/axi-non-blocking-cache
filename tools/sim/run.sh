#!/usr/bin/env bash
# Compiles every RTL file plus one testbench with Questa and runs it.
#
# Usage: ./tools/sim/run.sh [tb_name]   (default: mshr_tb)
#        e.g. ./tools/sim/run.sh cache_tag_array_tb
#
# Paths are resolved relative to this script's own location, so it can
# be launched from anywhere.
#
# Questa cannot open files or change into directories whose path
# contains non-ASCII characters (e.g. a localized "Documents" folder).
# When the project lives under such a path, the sources and license are
# copied into an ASCII-only staging directory and the simulation runs
# there; otherwise it runs in place, inside tools/sim/. Either way, no
# generated artifact (work/, transcript, *.wlf) lands in the project root.
set -e

TB_NAME="${1:-mshr_tb}"

# Resolve this script's own directory using only bash builtins -- when
# launched directly via bash.exe (e.g. from run.bat) rather than through
# Git Bash's normal login shell, external coreutils like `dirname` are
# not guaranteed to be on PATH yet.
case "${BASH_SOURCE[0]}" in
    */*) SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" ;;
    *)   SCRIPT_DIR="$(pwd)" ;;
esac
# Project root is two levels up: tools/sim -> tools -> root.
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Questa install: first known release found wins.
for QUESTA_BIN in /c/altera_lite/25.1std/questa_fse/win64 \
                  /c/altera_lite/24.1std/questa_fse/win64; do
    [ -x "$QUESTA_BIN/vsim.exe" ] && break
done
if [ ! -x "$QUESTA_BIN/vsim.exe" ]; then
    echo "run.sh: Questa not found under /c/altera_lite/*/questa_fse/win64" >&2
    exit 1
fi
export PATH="$QUESTA_BIN:$PATH"

# License: the machine-locked .dat file kept (untracked) in tools/.
LICENSE_SRC=""
for f in "$PROJECT_ROOT"/tools/*.dat; do
    [ -f "$f" ] && LICENSE_SRC="$f" && break
done
if [ -z "$LICENSE_SRC" ]; then
    echo "run.sh: no license file (*.dat) found in tools/" >&2
    exit 1
fi

# Pick the run directory: in place if the path is pure ASCII, otherwise
# a staging copy under the user's local app-data directory.
if LC_ALL=C bash -c '[[ "$1" == *[![:print:]]* ]]' _ "$PROJECT_ROOT"; then
    RUN_DIR="${LOCALAPPDATA:-$HOME/AppData/Local}"
    RUN_DIR="$(cygpath -u "$RUN_DIR")/axi-non-blocking-cache-sim"
    mkdir -p "$RUN_DIR/rtl" "$RUN_DIR/tb"
    cp "$PROJECT_ROOT"/rtl/*.sv "$RUN_DIR/rtl/"
    cp "$PROJECT_ROOT"/tb/*.sv  "$RUN_DIR/tb/"
    cp "$LICENSE_SRC" "$RUN_DIR/license.dat"
    SRC_ROOT="."
    LICENSE_FILE="$RUN_DIR/license.dat"
    echo "run.sh: non-ASCII project path -- simulating in $RUN_DIR"
else
    RUN_DIR="$SCRIPT_DIR"
    SRC_ROOT="$PROJECT_ROOT"
    LICENSE_FILE="$LICENSE_SRC"
fi

# Newer Questa releases read SALT_LICENSE_SERVER; older ones read
# LM_LICENSE_FILE. Setting both covers either.
export SALT_LICENSE_SERVER="$LICENSE_FILE"
export LM_LICENSE_FILE="$LICENSE_FILE"

cd "$RUN_DIR"

if [ ! -d work ]; then
    vlib work
fi

# axi_if.sv is compiled first: mshr.sv references the interface.
RTL_FILES=("$SRC_ROOT/rtl/axi_if.sv")
for f in "$SRC_ROOT"/rtl/*.sv; do
    [ "${f##*/}" = "axi_if.sv" ] || RTL_FILES+=("$f")
done

vlog -sv -svinputport=var "${RTL_FILES[@]}" "$SRC_ROOT/tb/$TB_NAME.sv"

vsim -c "work.$TB_NAME" -do "run -all; quit -f"
