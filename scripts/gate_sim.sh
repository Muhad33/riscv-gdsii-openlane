#!/bin/bash
# Gate-level simulation of the post-layout netlist against the golden model.
# Run inside the LibreLane nix-shell (provides iverilog + python3):
#   bash scripts/ll.sh bash scripts/gate_sim.sh                      # fibonacci + hazard_test
#   PROGRAMS="fibonacci gcd" bash scripts/ll.sh bash scripts/gate_sim.sh
#   NETLIST=flow/runs/p20/final/nl/riscv_core.nl.v ...   # default: final/netlist/riscv_core.nl.v
# Uses the sky130_fd_sc_hd functional Verilog models (FUNCTIONAL, UNIT_DELAY=#1:
# zero-delay logic with a 1 ps unit delay per cell, i.e. a functional check of the
# synthesized + placed + routed netlist; timing is covered by STA, not by this sim).
set -eu
cd "$(dirname "$0")/.."
NETLIST="${NETLIST:-final/netlist/riscv_core.nl.v}"
PROGRAMS="${PROGRAMS:-fibonacci hazard_test}"
MODELS="${MODELS:-$(ls -d "${PDK_ROOT:-$HOME/.ciel}"/ciel/sky130/versions/*/sky130A/libs.ref/sky130_fd_sc_hd/verilog | head -1)}"
echo "netlist: $NETLIST"
echo "models : $MODELS"
fail=0
for p in $PROGRAMS; do
  python3 scripts/run_tests.py --gate "$NETLIST" \
      --cells "$MODELS/primitives.v" "$MODELS/sky130_fd_sc_hd.v" --name "$p" | tail -3 || fail=1
done
exit $fail
