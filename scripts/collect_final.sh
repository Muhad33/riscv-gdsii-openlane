#!/bin/bash
# Copy the signoff views and reports of the chosen run into final/ (tracked in git).
# Large text views are gzipped (KLayout opens .gds.gz directly; `gunzip -k` for the rest).
#   bash scripts/collect_final.sh [flow/runs/p20]
set -eu
cd "$(dirname "$0")/.."
RUN="${1:-flow/runs/p20}"
D=riscv_core
F="$RUN/final"
step() { ls -d "$RUN"/*-"$1" 2>/dev/null | tail -1; }

rm -rf final
mkdir -p final/{gds,lef,lib,netlist,sdc,spef,def,reports/sta}

gzip -c9 "$F/gds/$D.gds"              > final/gds/$D.gds.gz
cp "$F/lef/$D.lef"                       final/lef/
for c in nom_tt_025C_1v80 nom_ss_100C_1v60 nom_ff_n40C_1v95; do
  cp "$F/lib/$c/${D}__$c.lib"            final/lib/
done
cp "$F/nl/$D.nl.v"                       final/netlist/
gzip -c9 "$F/pnl/$D.pnl.v"             > final/netlist/$D.pnl.v.gz
cp "$F/sdc/$D.sdc"                       final/sdc/
gzip -c9 "$F/spef/nom/$D.nom.spef"     > final/spef/$D.nom.spef.gz
gzip -c9 "$F/def/$D.def"               > final/def/$D.def.gz

R=final/reports
cp "$F/metrics.json" "$F/metrics.csv"    $R/
cp "$RUN/resolved.json"                  $R/resolved_config.json
cp "$(step yosys-synthesis)/reports/stat.rpt"            $R/synthesis_stat.rpt
cp "$(step magic-drc)/reports/drc.magic.rpt"             $R/drc_magic.rpt
cp "$(step klayout-drc)/reports/drc.klayout.json"        $R/drc_klayout.json
cp "$(step netgen-lvs)/reports/lvs.netgen.rpt"           $R/lvs_netgen.rpt
cp "$(step checkantennas-1)/reports/antenna_summary.rpt" $R/antenna_summary.rpt
cp "$(step reportmanufacturability)/manufacturability.rpt" $R/manufacturability.rpt
cp "$(step irdropreport)/irdrop.rpt"                     $R/irdrop.rpt

STA="$(step stapostpnr)"
for cdir in "$STA"/*_*_*/; do
  c=$(basename "$cdir")
  mkdir -p $R/sta/$c
  for f in checks.rpt clock.rpt power.rpt skew.max.rpt skew.min.rpt wns.max.rpt wns.min.rpt \
           tns.max.rpt tns.min.rpt ws.max.rpt ws.min.rpt violator_list.rpt; do
    [ -f "$cdir/$f" ] && cp "$cdir/$f" $R/sta/$c/
  done
  # worst setup / hold path only (the full path reports are several MB each)
  awk '/^Startpoint:/{n++} n==1' "$cdir/max.rpt" | sed '/^Startpoint:/,$!d' > $R/sta/$c/worst_setup_path.rpt
  awk '/^Startpoint:/{n++} n==1' "$cdir/min.rpt" | sed '/^Startpoint:/,$!d' > $R/sta/$c/worst_hold_path.rpt
done
du -sh final
find final -type f | sort
