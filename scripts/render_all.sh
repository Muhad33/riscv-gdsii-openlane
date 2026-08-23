#!/bin/bash
# Render the final layout and the flow-stage views of a run to results/*.png (KLayout, batch mode).
# Run inside the LibreLane nix-shell:  bash scripts/ll.sh bash scripts/render_all.sh [flow/runs/p20]
set -eu
cd "$(dirname "$0")/.."
R="${1:-flow/runs/p20}"
P="$(ls -d "${PDK_ROOT:-$HOME/.ciel}"/ciel/sky130/versions/*/sky130A | head -1)"
HIDE="areaid,boundary,nwell,pwell,psdm,nsdm,hvtp,npc,.pin,.label,text,tap.drawing"
step() { ls -d "$R"/*-"$1" | tail -1; }
k() { QT_QPA_PLATFORM=offscreen klayout -b -r scripts/render_layout.py -rd pdk="$P" -rd hide="$HIDE" "$@"; }
mkdir -p results
k -rd in="$R/final/gds/riscv_core.gds" -rd out=results/layout.png -rd width=2400
k -rd in="$R/final/gds/riscv_core.gds" -rd out=results/layout_zoom.png -rd width=1600 -rd box=200,200,260,240
k -rd in="$(step openroad-floorplan)/riscv_core.def"          -rd out=results/stage_1_floorplan.png -rd width=1400
k -rd in="$(step openroad-detailedplacement)/riscv_core.def"  -rd out=results/stage_2_placement.png -rd width=1400
k -rd in="$(step openroad-cts)/riscv_core.def"                -rd out=results/stage_3_cts.png       -rd width=1400
k -rd in="$(step openroad-detailedrouting)/riscv_core.def"    -rd out=results/stage_4_routing.png   -rd width=1400
