#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python3 make_boot.py
mkdir -p build
exec ${VIVADO:-vivado} -mode batch -source build_sim.tcl \
    -log build/vivado.log -journal build/vivado.jou
