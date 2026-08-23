# PPA summary — riscv_core (final design)

Run: `flow/runs/p20` · sky130A / sky130_fd_sc_hd · LibreLane 3.0.17 Classic flow · numbers taken from the flow's signoff reports (the run's `final/metrics.json`, copied to `final/reports/metrics.json`).

## Headline

| Metric | Value |
|---|---|
| Clock period / frequency | **20 ns / 50.0 MHz** |
| Setup slack (WNS), worst of 9 corners | +0.066 ns (TNS 0.000 ns) |
| Hold slack (WNS), worst of 9 corners | +0.099 ns (TNS 0.000 ns) |
| Timing met in all corners | yes |
| Die size | 485.36 µm × 496.08 µm |
| Die area | 240,777 µm² = 0.2408 mm² |
| Core area | 224,458 µm² = 0.2245 mm² |
| Standard-cell area (logic, excl. fill/decap/taps) | 128,135 µm² = 0.1281 mm² |
| Core utilization | 57.1 % |
| Standard cells (logic) | 15,606 |
| All instances incl. fill/decap/taps | 44,443 |
| I/O pins | 210 |
| Total power (estimate) | 8.29 mW |
| ↳ internal / switching / leakage | 5.45 mW / 2.84 mW / 0.249 µW |
| Worst IR drop (VPWR) | 0.80 mV |
| Total routed wire length | 553,934 µm |

Power is OpenSTA's estimate at the typical corner (25 °C, 1.80 V) with default switching activity, not a measurement or a simulation-based activity analysis.

## Signoff checks

| Check | Result |
|---|---|
| DRC — Magic | 0 errors |
| DRC — KLayout | 0 errors |
| DRC — detailed router | 0 errors |
| LVS (Netgen) | 0 errors (unmatched devices 0, nets 0, pins 0) |
| Antenna | 0 violating nets, 0 pins (88 diodes inserted) |
| GDS XOR (Magic vs KLayout stream-out) | 0 differences |
| Max slew violations (flow limit 0.75 ns) | 803 (worst corner; tt: 0) |
| Max capacitance violations (flow limit 0.2 pF) | 1 |
| Max fanout violations (flow limit 10) | 25 |

Slew / cap / fanout are the flow's own design-rule targets (tighter than the library limits); the remaining ones are in the slow corners and on the clock tree, see `docs/iteration_log.md`.

## Timing per corner

| Corner | Setup WNS (ns) | Setup TNS (ns) | Hold WNS (ns) | Hold TNS (ns) |
|---|---:|---:|---:|---:|
| nom_tt_025C_1v80 | +9.732 | 0.000 | +0.325 | 0.000 |
| min_tt_025C_1v80 | +10.055 | 0.000 | +0.320 | 0.000 |
| max_tt_025C_1v80 | +9.350 | 0.000 | +0.330 | 0.000 |
| nom_ss_100C_1v60 | +0.786 | 0.000 | +0.870 | 0.000 |
| min_ss_100C_1v60 | +1.455 | 0.000 | +0.860 | 0.000 |
| max_ss_100C_1v60 | +0.066 | 0.000 | +0.880 | 0.000 |
| nom_ff_n40C_1v95 | +12.016 | 0.000 | +0.109 | 0.000 |
| min_ff_n40C_1v95 | +12.210 | 0.000 | +0.110 | 0.000 |
| max_ff_n40C_1v95 | +11.844 | 0.000 | +0.099 | 0.000 |

Corner names: parasitics (nom/min/max RC) _ process (tt typical, ss slow, ff fast) _ temperature _ supply.

## Cell-type breakdown

| Category | Cells | Area (µm²) | Share of logic area |
|---|---:|---:|---:|
| Physical only: fill / decap / well taps | 32,005 | 100,286 | – |
| Other combinational logic | 4,999 | 50,033 | 40.3 % |
| Flip-flops | 1,442 | 30,679 | 24.7 % |
| Buffers (fanout / slew / I/O) | 3,770 | 17,352 | 14.0 % |
| Hold-fix delay cells | 1,152 | 11,531 | 9.3 % |
| Multiplexers | 576 | 9,842 | 7.9 % |
| Clock tree buffers | 292 | 4,115 | 3.3 % |
| Antenna diodes | 126 | 315 | 0.3 % |
| Inverters | 81 | 304 | 0.2 % |

Areas from the cell LEF sizes. 'Physical only' cells carry no logic.

### Most used logic cells

| Cell | Count | Area (µm²) |
|---|---:|---:|
| clkbuf_2 | 2,177 | 10,895 |
| dfxtp_2 | 1,439 | 30,608 |
| dlygate4sd3_1 | 1,152 | 11,531 |
| buf_1 | 991 | 3,720 |
| a32o_2 | 597 | 6,723 |
| a22o_2 | 549 | 5,495 |
| clkbuf_1 | 346 | 1,299 |
| o211a_2 | 338 | 3,383 |
| mux4_2 | 298 | 6,711 |
| nand2_2 | 295 | 1,846 |
| mux2_1 | 276 | 3,108 |
| clkbuf_8 | 219 | 3,014 |
| buf_2 | 203 | 1,016 |
| o21ai_2 | 201 | 1,760 |
| a21oi_2 | 199 | 1,743 |
