#!/usr/bin/env bash
# Compiles and runs the mshr testbench with Questa, keeping every
# generated artifact (work/, modelsim.ini, vsim.wlf) inside
# tools/sim/ instead of the project root.
#
# Usage: ./tools/sim/run.sh   (from anywhere -- paths are resolved
#                              relative to this script's own location)
set -e

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

export PATH="/c/altera_lite/24.1std/questa_fse/win64:$PATH"
export LM_LICENSE_FILE="$PROJECT_ROOT/tools/LR-180454_License.dat"

cd "$SCRIPT_DIR"

if [ ! -d work ]; then
    vlib work
fi

vlog -sv -svinputport=var \
    "$PROJECT_ROOT/rtl/axi_if.sv" \
    "$PROJECT_ROOT/rtl/mshr.sv" \
    "$PROJECT_ROOT/tb/mshr_tb.sv"

vsim -c work.mshr_tb -do "run -all; quit -f"
