"""Collect LibreLane metrics from the clock-sweep runs and pick the final design.

Reads flow/runs/<tag>/final/metrics.json for every run tag given (default: all
runs named p<period>), writes results/clock_sweep.md, results/clock_sweep.csv and
results/clock_sweep.png, and prints the chosen run: the shortest clock period
whose run has setup and hold met in all signoff corners, zero DRC (Magic,
KLayout, router), zero LVS errors and zero antenna violations.

Usage:
    python scripts/sweep_report.py                 # all flow/runs/p*
    python scripts/sweep_report.py p25 p20 p15     # selected runs
"""
from __future__ import annotations

import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNS = ROOT / "flow" / "runs"
RESULTS = ROOT / "results"


def period_of(run: Path) -> float:
    cfg = json.loads((run / "resolved.json").read_text(encoding="utf-8"))
    return float(cfg["CLOCK_PERIOD"])


def row_for(run: Path) -> dict | None:
    mfile = run / "final" / "metrics.json"
    if not mfile.exists():
        return {"run": run.name, "period_ns": period_of(run), "status": "flow did not finish"}
    m = json.loads(mfile.read_text(encoding="utf-8"))
    g = lambda k, d=None: m.get(k, d)  # noqa: E731
    r = {
        "run": run.name,
        "period_ns": period_of(run),
        "setup_wns_ns": g("timing__setup__ws"),         # worst slack over all corners
        "setup_tns_ns": g("timing__setup__tns"),
        "setup_wns_tt_ns": g("timing__setup__ws__corner:nom_tt_025C_1v80"),  # typical corner only
        "setup_vio": g("timing__setup_vio__count"),
        "hold_wns_ns": g("timing__hold__ws"),
        "hold_tns_ns": g("timing__hold__tns"),
        "hold_vio": g("timing__hold_vio__count"),
        "stdcells": g("design__instance__count__stdcell"),
        "all_instances": g("design__instance__count"),
        "stdcell_area_um2": g("design__instance__area__stdcell"),
        "die_area_um2": g("design__die__area"),
        "core_area_um2": g("design__core__area"),
        "utilization_pct": 100 * g("design__instance__utilization", 0),
        "power_mw": 1000 * g("power__total", 0),
        "magic_drc": g("magic__drc_error__count"),
        "klayout_drc": g("klayout__drc_error__count"),
        "route_drc": g("route__drc_errors"),
        "lvs_errors": g("design__lvs_error__count"),
        "antenna_nets": g("antenna__violating__nets"),
        "slew_vio": g("design__max_slew_violation__count"),
        "cap_vio": g("design__max_cap_violation__count"),
        "fanout_vio": g("design__max_fanout_violation__count"),
    }
    r["timing_met"] = (r["setup_vio"] == 0 and r["hold_vio"] == 0
                       and r["setup_wns_ns"] >= 0 and r["hold_wns_ns"] >= 0)
    r["drc_clean"] = r["magic_drc"] == 0 and r["klayout_drc"] == 0 and r["route_drc"] == 0
    r["lvs_clean"] = r["lvs_errors"] == 0
    r["antenna_clean"] = r["antenna_nets"] == 0
    r["signoff_clean"] = r["timing_met"] and r["drc_clean"] and r["lvs_clean"] and r["antenna_clean"]
    r["status"] = "clean" if r["signoff_clean"] else "fails: " + ", ".join(
        n for n, ok in [("timing", r["timing_met"]), ("DRC", r["drc_clean"]),
                        ("LVS", r["lvs_clean"]), ("antenna", r["antenna_clean"])] if not ok)
    return r


def ok(v: bool) -> str:
    return "pass" if v else "**FAIL**"


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    tags = sys.argv[1:]
    runs = [RUNS / t for t in tags] if tags else [p for p in RUNS.iterdir() if re.fullmatch(r"p[\d_]+", p.name)]
    rows = sorted((row_for(r) for r in runs), key=lambda r: -r["period_ns"])
    done = [r for r in rows if "setup_wns_ns" in r]
    clean = [r for r in done if r["signoff_clean"]]
    final = min(clean, key=lambda r: r["period_ns"]) if clean else None

    RESULTS.mkdir(exist_ok=True)
    with open(RESULTS / "clock_sweep.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(done[0].keys()) if done else ["run"])
        w.writeheader()
        w.writerows(done)

    md = ["# Clock period sweep", "",
          "riscv_core, sky130A / sky130_fd_sc_hd, LibreLane 3.0.17 Classic flow. Same config "
          "(`flow/config.json`) for every run; only `CLOCK_PERIOD` changes (`-c CLOCK_PERIOD=<ns>`).",
          "Slack values are the worst over all 9 signoff STA corners (tt/ss/ff × nom/min/max parasitics). "
          "Power is the OpenROAD STA estimate (default switching activity), not a measurement.", "",
          "| Period (ns) | Freq (MHz) | Setup WNS (ns) | Setup TNS (ns) | Setup WNS, typical corner (ns) | Hold WNS (ns) | Hold TNS (ns) "
          "| Std cells | Std-cell area (µm²) | Die area (µm²) | Util (%) | Power (mW) | DRC | LVS | Antenna "
          "| Slew / cap / fanout viol. | Result |",
          "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---:|---|"]
    for r in rows:
        if "setup_wns_ns" not in r:
            md.append(f"| {r['period_ns']:g} | {1000 / r['period_ns']:.1f} | – | – | – | – | – | – | – | – | – | – | – | – | – | – | {r['status']} |")
            continue
        mark = " ← **final**" if final and r is final else ""
        md.append(
            f"| {r['period_ns']:g} | {1000 / r['period_ns']:.1f} | {r['setup_wns_ns']:.3f} | {r['setup_tns_ns']:.3f} "
            f"| {r['setup_wns_tt_ns']:.3f} "
            f"| {r['hold_wns_ns']:.3f} | {r['hold_tns_ns']:.3f} | {r['stdcells']} | {r['stdcell_area_um2']:.0f} "
            f"| {r['die_area_um2']:.0f} | {r['utilization_pct']:.1f} | {r['power_mw']:.2f} "
            f"| {ok(r['drc_clean'])} | {ok(r['lvs_clean'])} | {ok(r['antenna_clean'])} "
            f"| {r['slew_vio']} / {r['cap_vio']} / {r['fanout_vio']} | {r['status']}{mark} |")
    md += ["", "DRC = Magic + KLayout + detailed-router DRC all zero. "
           "Std cells = logic cells placed by the flow (excludes fill, decap, tap cells).",
           "Slew / cap / fanout = pins over the flow's design-rule constraints (max transition 0.75 ns, "
           "max capacitance 0.2 pF, max fanout 10), worst corner. These limits are tighter than the library's "
           "own characterization limits (1.5 ns max transition); they are reported but are not part of the "
           "pass/fail rule (timing + DRC + LVS + antenna).", ""]
    if final:
        md.append(f"**Final design: {final['run']} — {final['period_ns']:g} ns "
                  f"({1000 / final['period_ns']:.1f} MHz)**, the shortest period with timing met in all corners "
                  "and clean DRC / LVS / antenna.")
    else:
        md.append("**No run is signoff-clean.**")
    (RESULTS / "clock_sweep.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md))

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed: skipping results/clock_sweep.png")
        return 0
    if not done:
        return 0
    per = [r["period_ns"] for r in done]
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4.2))
    a1.plot(per, [r["setup_wns_ns"] for r in done], "o-", color="#2f6db5", label="setup WNS (worst corner)")
    a1.plot(per, [r["setup_wns_tt_ns"] for r in done], "o--", color="#7fa7d9", label="setup WNS (typical corner only)")
    a1.plot(per, [r["hold_wns_ns"] for r in done], "s-", color="#d9822b", label="hold WNS (worst corner)")
    a1.axhline(0, color="#888", lw=1, ls="--")
    for r in done:
        if not r["timing_met"]:
            a1.plot(r["period_ns"], r["setup_wns_ns"], "x", color="#c0392b", ms=11, mew=2)
    if final:
        a1.axvline(final["period_ns"], color="#2e9e5b", lw=1, ls=":", label=f"final: {final['period_ns']:g} ns")
    a1.set_xlabel("clock period (ns)")
    a1.set_ylabel("slack (ns)")
    a1.set_title("Period vs worst slack")
    a1.invert_xaxis()
    a1.grid(alpha=0.3)
    a1.legend(fontsize=8)
    a2.plot(per, [r["stdcell_area_um2"] for r in done], "o-", color="#2f6db5", label="std-cell area")
    a2.plot(per, [r["die_area_um2"] for r in done], "s--", color="#7f8c8d", label="die area")
    if final:
        a2.axvline(final["period_ns"], color="#2e9e5b", lw=1, ls=":", label=f"final: {final['period_ns']:g} ns")
    a2.set_xlabel("clock period (ns)")
    a2.set_ylabel("area (µm²)")
    a2.set_title("Period vs area")
    a2.invert_xaxis()
    a2.grid(alpha=0.3)
    a2.legend(fontsize=8)
    fig.suptitle("riscv_core on sky130 — clock period sweep (red x = timing violated)", fontsize=11)
    fig.tight_layout()
    fig.savefig(RESULTS / "clock_sweep.png", dpi=150)
    print(f"wrote {RESULTS / 'clock_sweep.png'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
