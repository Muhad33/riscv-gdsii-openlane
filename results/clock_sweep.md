# Clock period sweep

riscv_core, sky130A / sky130_fd_sc_hd, LibreLane 3.0.17 Classic flow. Same config (`flow/config.json`) for every run; only `CLOCK_PERIOD` changes (`-c CLOCK_PERIOD=<ns>`).
Slack values are the worst over all 9 signoff STA corners (tt/ss/ff × nom/min/max parasitics). Power is the OpenROAD STA estimate (default switching activity), not a measurement.

| Period (ns) | Freq (MHz) | Setup WNS (ns) | Setup TNS (ns) | Setup WNS, typical corner (ns) | Hold WNS (ns) | Hold TNS (ns) | Std cells | Std-cell area (µm²) | Die area (µm²) | Util (%) | Power (mW) | DRC | LVS | Antenna | Slew / cap / fanout viol. | Result |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---:|---|
| 25 | 40.0 | 5.066 | 0.000 | 13.946 | 0.099 | 0.000 | 15606 | 128135 | 240777 | 57.1 | 6.63 | pass | pass | pass | 803 / 1 / 25 | clean |
| 20 | 50.0 | 0.066 | 0.000 | 9.732 | 0.099 | 0.000 | 15606 | 128135 | 240777 | 57.1 | 8.29 | pass | pass | pass | 803 / 1 / 25 | clean ← **final** |
| 17.5 | 57.1 | -2.434 | -83.090 | 7.232 | 0.099 | 0.000 | 15606 | 128135 | 240777 | 57.1 | 9.47 | pass | pass | pass | 803 / 1 / 25 | fails: timing |
| 15 | 66.7 | -2.804 | -179.452 | 5.791 | 0.107 | 0.000 | 15611 | 128178 | 240777 | 57.1 | 11.05 | pass | pass | pass | 804 / 1 / 26 | fails: timing |
| 12.5 | 80.0 | -2.806 | -349.747 | 3.885 | 0.112 | 0.000 | 15611 | 128651 | 240777 | 57.3 | 13.28 | pass | pass | pass | 892 / 1 / 25 | fails: timing |
| 10 | 100.0 | -2.931 | -657.748 | 2.526 | 0.036 | 0.000 | 15850 | 134259 | 240777 | 59.8 | 16.88 | pass | pass | pass | 850 / 1 / 24 | fails: timing |

DRC = Magic + KLayout + detailed-router DRC all zero. Std cells = logic cells placed by the flow (excludes fill, decap, tap cells).
Slew / cap / fanout = pins over the flow's design-rule constraints (max transition 0.75 ns, max capacitance 0.2 pF, max fanout 10), worst corner. These limits are tighter than the library's own characterization limits (1.5 ns max transition); they are reported but are not part of the pass/fail rule (timing + DRC + LVS + antenna).

**Final design: p20 — 20 ns (50.0 MHz)**, the shortest period with timing met in all corners and clean DRC / LVS / antenna.

## Notes

- **Reproducibility:** the 25 ns and 20 ns runs reproduce the earlier exploration runs with the same
  configuration (`p25_try11…`, `p20_try11…`) to the last digit: the flow is deterministic.
- **Why the final is 20 ns:** below 20 ns the slow (ss, 100 °C, 1.60 V) corners fail setup. The typical
  corner still passes even at 10 ns (+2.53 ns). In this LibreLane / OpenROAD version the timing-repair
  steps optimize against a single corner (`max_tt_025C_1v80`, the first one defined): at 17.5 ns
  `repair_timing` reported "No setup violations found" while signoff STA shows −2.43 ns in max_ss.
  So 20 ns is the limit of this flow setup, not necessarily of the core; getting below it would need
  slow-corner-driven timing repair (see `docs/iteration_log.md`).
- **Same netlist at 25 / 20 / 17.5 ns:** no setup repair was triggered there (see above), so these three
  runs share one layout and only the timing constraint differs. The die size is fixed by
  `FP_CORE_UTIL` = 40 % of the synthesized area, which does not depend on the clock period here.
- **Runtime:** the 17.5 ns run took 5.7 h of wall-clock time but only 6.6 min of router CPU time
  (`46-openroad-detailedrouting`, cpu vs elapsed): the host was asleep. The result is identical to the
  20 ns layout (same wire length, 553,934 µm).
