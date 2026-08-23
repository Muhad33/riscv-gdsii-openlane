"""Write results/ppa_summary.md for the final LibreLane run.

Reads <run>/final/metrics.json, <run>/final/nl/<design>.nl.v and the
sky130_fd_sc_hd cell LEF (for cell areas), and summarizes performance, power,
area, signoff status and a cell-type breakdown.

Usage (inside the LibreLane nix-shell, so the PDK path resolves):
    python3 scripts/ppa_summary.py [flow/runs/p20]
"""
from __future__ import annotations

import collections
import glob
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUN = (Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "flow" / "runs" / "p20").resolve()
OUT = ROOT / "results" / "ppa_summary.md"
CORNERS = [f"{rc}_{pvt}" for pvt in ("tt_025C_1v80", "ss_100C_1v60", "ff_n40C_1v95") for rc in ("nom", "min", "max")]


def lef_areas() -> dict[str, float]:
    pdk = os.environ.get("PDK_ROOT", os.path.expanduser("~/.ciel"))
    lefs = glob.glob(f"{pdk}/ciel/sky130/versions/*/sky130A/libs.ref/sky130_fd_sc_hd/lef/sky130_*_sc_hd.lef")
    areas = {}
    for lef in lefs:
        text = Path(lef).read_text()
        for m in re.finditer(r"MACRO\s+(\S+)(.*?)END\s+\1", text, re.S):
            size = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", m.group(2))
            if size:
                areas[m.group(1)] = float(size.group(1)) * float(size.group(2))
    return areas


def category(cell: str, inst: str) -> str:
    c = cell.replace("sky130_fd_sc_hd__", "").replace("sky130_ef_sc_hd__", "")
    if re.match(r"(fill|decap|tapvpwrvgnd)", c):
        return "Physical only: fill / decap / well taps"
    if c.startswith("diode"):
        return "Antenna diodes"
    if re.match(r"(dfxtp|dfrtp|dfstp|dfbbp|edfxtp|sdf|dlxtp|dlrtp)", c):
        return "Flip-flops"
    if inst.startswith("clkbuf_") or inst.startswith("clkload"):
        return "Clock tree buffers"
    if c.startswith("dlygate") or inst.startswith("hold"):
        return "Hold-fix delay cells"
    if re.match(r"(buf|clkbuf)", c):
        return "Buffers (fanout / slew / I/O)"
    if c.startswith("conb"):
        return "Tie cells"
    if re.match(r"(inv|clkinv)", c):
        return "Inverters"
    if re.match(r"mux", c):
        return "Multiplexers"
    return "Other combinational logic"


def main() -> int:
    m = json.loads((RUN / "final" / "metrics.json").read_text())
    cfg = json.loads((RUN / "resolved.json").read_text())
    design = cfg["DESIGN_NAME"]
    period = float(cfg["CLOCK_PERIOD"])
    nl = (RUN / "final" / "nl" / f"{design}.nl.v").read_text()
    insts = re.findall(r"^\s*(sky130_\w+)\s+(\S+)\s*\(", nl, re.M)
    areas = lef_areas()

    cats = collections.Counter()
    cat_area = collections.Counter()
    types = collections.Counter()
    type_area = collections.Counter()
    for cell, inst in insts:
        cat = category(cell, inst)
        a = areas.get(cell, 0.0)
        cats[cat] += 1
        cat_area[cat] += a
        if not cat.startswith("Physical"):
            types[cell] += 1
            type_area[cell] += a
    logic_area = sum(v for k, v in cat_area.items() if not k.startswith("Physical"))

    g = m.get
    die = g("design__die__area")
    core = g("design__core__area")
    bbox = [float(v) for v in g("design__die__bbox").split()]
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    met = g("timing__setup_vio__count") == 0 and g("timing__hold_vio__count") == 0 \
        and g("timing__setup__ws") >= 0 and g("timing__hold__ws") >= 0

    L = [f"# PPA summary — {design} (final design)", "",
         f"Run: `{RUN.relative_to(ROOT).as_posix()}` · sky130A / sky130_fd_sc_hd · LibreLane 3.0.17 Classic flow · "
         "numbers taken from the flow's signoff reports (the run's `final/metrics.json`, copied to `final/reports/metrics.json`).", "",
         "## Headline", "",
         "| Metric | Value |", "|---|---|",
         f"| Clock period / frequency | **{period:g} ns / {1000 / period:.1f} MHz** |",
         f"| Setup slack (WNS), worst of 9 corners | {g('timing__setup__ws'):+.3f} ns (TNS {g('timing__setup__tns'):.3f} ns) |",
         f"| Hold slack (WNS), worst of 9 corners | {g('timing__hold__ws'):+.3f} ns (TNS {g('timing__hold__tns'):.3f} ns) |",
         f"| Timing met in all corners | {'yes' if met else '**no**'} |",
         f"| Die size | {w:.2f} µm × {h:.2f} µm |",
         f"| Die area | {die:,.0f} µm² = {die / 1e6:.4f} mm² |",
         f"| Core area | {core:,.0f} µm² = {core / 1e6:.4f} mm² |",
         f"| Standard-cell area (logic, excl. fill/decap/taps) | {g('design__instance__area__stdcell'):,.0f} µm² = "
         f"{g('design__instance__area__stdcell') / 1e6:.4f} mm² |",
         f"| Core utilization | {100 * g('design__instance__utilization'):.1f} % |",
         f"| Standard cells (logic) | {g('design__instance__count__stdcell'):,} |",
         f"| All instances incl. fill/decap/taps | {g('design__instance__count'):,} |",
         f"| I/O pins | {g('design__io')} |",
         f"| Total power (estimate) | {1000 * g('power__total'):.2f} mW |",
         f"| ↳ internal / switching / leakage | {1000 * g('power__internal__total'):.2f} mW / "
         f"{1000 * g('power__switching__total'):.2f} mW / {1e6 * g('power__leakage__total'):.3f} µW |",
         f"| Worst IR drop (VPWR) | {1000 * g('design_powergrid__drop__worst', 0):.2f} mV |",
         f"| Total routed wire length | {g('route__wirelength'):,} µm |",
         "",
         "Power is OpenSTA's estimate at the typical corner (25 °C, 1.80 V) with default switching activity, "
         "not a measurement or a simulation-based activity analysis.", "",
         "## Signoff checks", "",
         "| Check | Result |", "|---|---|",
         f"| DRC — Magic | {g('magic__drc_error__count')} errors |",
         f"| DRC — KLayout | {g('klayout__drc_error__count')} errors |",
         f"| DRC — detailed router | {g('route__drc_errors')} errors |",
         f"| LVS (Netgen) | {g('design__lvs_error__count')} errors "
         f"(unmatched devices {g('design__lvs_unmatched_device__count')}, nets {g('design__lvs_unmatched_net__count')}, "
         f"pins {g('design__lvs_unmatched_pin__count')}) |",
         f"| Antenna | {g('antenna__violating__nets')} violating nets, {g('antenna__violating__pins')} pins "
         f"({g('antenna_diodes_count', 0)} diodes inserted) |",
         f"| GDS XOR (Magic vs KLayout stream-out) | {g('design__xor_difference__count')} differences |",
         f"| Max slew violations (flow limit 0.75 ns) | {g('design__max_slew_violation__count')} (worst corner; "
         f"tt: {g('design__max_slew_violation__count__corner:nom_tt_025C_1v80')}) |",
         f"| Max capacitance violations (flow limit 0.2 pF) | {g('design__max_cap_violation__count')} |",
         f"| Max fanout violations (flow limit 10) | {g('design__max_fanout_violation__count')} |",
         "",
         "Slew / cap / fanout are the flow's own design-rule targets (tighter than the library limits); "
         "the remaining ones are in the slow corners and on the clock tree, see `docs/iteration_log.md`.", "",
         "## Timing per corner", "",
         "| Corner | Setup WNS (ns) | Setup TNS (ns) | Hold WNS (ns) | Hold TNS (ns) |",
         "|---|---:|---:|---:|---:|"]
    for c in CORNERS:
        L.append(f"| {c} | {g('timing__setup__ws__corner:' + c):+.3f} | {g('timing__setup__tns__corner:' + c):.3f} "
                 f"| {g('timing__hold__ws__corner:' + c):+.3f} | {g('timing__hold__tns__corner:' + c):.3f} |")
    L += ["", "Corner names: parasitics (nom/min/max RC) _ process (tt typical, ss slow, ff fast) _ temperature _ supply.", "",
          "## Cell-type breakdown", "",
          "| Category | Cells | Area (µm²) | Share of logic area |", "|---|---:|---:|---:|"]
    for cat, n in sorted(cats.items(), key=lambda kv: -cat_area[kv[0]]):
        share = "–" if cat.startswith("Physical") else f"{100 * cat_area[cat] / logic_area:.1f} %"
        L.append(f"| {cat} | {n:,} | {cat_area[cat]:,.0f} | {share} |")
    L += ["", "Areas from the cell LEF sizes. 'Physical only' cells carry no logic.", "",
          "### Most used logic cells", "", "| Cell | Count | Area (µm²) |", "|---|---:|---:|"]
    for cell, n in types.most_common(15):
        L.append(f"| {cell.replace('sky130_fd_sc_hd__', '')} | {n:,} | {type_area[cell]:,.0f} |")
    OUT.write_text("\n".join(L) + "\n", encoding="utf-8")
    print("\n".join(L))
    return 0


if __name__ == "__main__":
    sys.exit(main())
