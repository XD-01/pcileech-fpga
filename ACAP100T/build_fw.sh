#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VIVADO_BIN="${VIVADO_BIN:-vivado}"
PART="${PART:-xc7a100tfgg484-2}"
JOBS="${JOBS:-8}"

"$VIVADO_BIN" -mode batch -source "$ROOT/scripts/build.tcl" \
    -tclargs -part "$PART" -jobs "$JOBS" -outdir "$ROOT/output"

echo
echo "Build complete:"
echo "  $ROOT/output/acap100t.bit"
echo "  $ROOT/output/acap100t.bin"
echo "  $ROOT/output/acap100t_flash.bin"
echo "  $ROOT/output/acap100t.mcs"
