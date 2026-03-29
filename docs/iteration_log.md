# Iteration log

Every failure hit while bringing up the flow, what caused it, and the fix.

## Environment (Phase 0)

| # | Symptom | Cause | Fix |
|---|---------|-------|-----|
| E1 | OpenLane 2 repo shows a "development has moved" banner; last tag `3.0.0.dev21` (Feb 2025) | OpenLane 2 is succeeded by **LibreLane** (same config format, same tools) | Use LibreLane **3.0.17** via Nix (official WSL2 guide). Pinned in `scripts/setup_wsl.sh`. |
| E2 | `librelane --smoke-test` fails with `httpx.ReadTimeout` while downloading the PDK | Ciel (PDK downloader) uses httpx's default 5 s read timeout; too short for a slow link | `scripts/fetch_pdk.py`: same `ciel.fetch()` call LibreLane makes (open_pdks rev `8afc8346…`, same library set), with a 600 s timeout and retries. Smoke test then passed. |

## Counter example (Phase 1)

| # | Symptom | Cause | Fix |
|---|---------|-------|-----|
| C1 | `Verilator.Lint` fails: `Can't resolve module reference 'sky130_fd_sc_hd__udp_pwrgood_pp$PG'` | Project path contains a space (`github projects`); Yosys script commands split the path at the space | Run from a space-free path. A symlink was **not** enough (LibreLane resolves it back to the real path); a **bind mount** works: `scripts/wsl_mount.sh` mounts the project at `/root/rgo`. |
| C2 | 11 max-slew violations (0.760 ns vs 0.750 ns limit), only in corner `max_ss_100C_1v60`, all on one fanout net | Resizer's default 20 % slew margin was not enough for the worst-case (slow process, 100 °C, 1.60 V, max parasitics) corner | `DESIGN_REPAIR_MAX_SLEW_PCT` and `GRT_DESIGN_REPAIR_MAX_SLEW_PCT` = 30 → 0 violations. |
| C3 | (preventive, not an observed failure) default PDN pitch is larger than a 100 µm die | LibreLane no longer auto-scales PDN pitch for small designs | `PDN_VPITCH`/`PDN_HPITCH` = 25 µm, offsets 5 µm. |

## Core ASIC preparation (Phase 2)

| # | Change | Why | Check |
|---|--------|-----|-------|
| P1 | New `rtl/riscv_core.v`: instruction / data memories moved out of the core, reached through ports (`imem_*`, `dmem_*` with byte enables). Register file stays inside. | 2 × 4 KiB as flip-flops would be ~65k flops (huge); real chips use SRAM macros or off-chip memory. | All programs + random tests pass; cycle counts identical to the reference. |
| P2 | Store lane placement / byte enables and load byte/half select + sign extension moved from `data_mem.v` into the core's MEM stage. | Memory becomes a plain word-wide RAM with byte enables (the usual SRAM interface). | Mutation test: 3 deliberate bugs in this logic were all caught (28–55 of 57 tests fail). |
| P3 | `cycle_count` / `instret_count` counters and the trace-only `ex_mem_pc` / `mem_wb_pc` registers removed from the core; testbench counts cycles and retirements via the new retire port. | They only served the simulation; ~128 flip-flops of silicon for no function. | Testbench counts match the reference's hardware counters exactly. |
| P4 | Retire / trace port (`retire_valid/we/rd/wdata`) added. | Zero-cost (existing WB signals); lets the testbench check every register write on the gate-level netlist, where internal names are gone. | Testbench cross-checks the regfile against a shadow copy rebuilt from this port (RTL mode). |
| P5 | Original `cpu_top.v`, `instr_mem.v`, `data_mem.v`, `tb_cpu.v` kept unchanged in `ref/` (not synthesized). | A/B reference: `make sim-ref`. | |
| P6 | Lint: removed unused `stall` connection, waived "unused instr bits" in the decoder. | Verilator `-Wall` clean. | `results/lint_report.txt`: 0 latches, 0 async flops, 0 combinational loops, Yosys `check` 0 problems. |
| P7 | X-propagation check in the testbench: any X on any core output after reset = test failure. | All core flops are reset synchronously; this proves it. | Removing one register's reset makes the test fail immediately. |

## riscv_core flow (Phase 3)

Signoff standard used here (stricter than LibreLane's default): setup **and** hold met in **all 9**
STA corners (tt/ss/ff × nom/min/max parasitics), zero Magic/KLayout/router DRC, zero LVS errors,
zero antenna violations. LibreLane itself only fails a run on `*tt*` corner timing by default
(`TIMING_VIOLATION_CORNERS`), so slow-corner violations are checked by `scripts/sweep_report.py`.

| # | Run | Symptom | Cause | Fix |
|---|-----|---------|-------|-----|
| F1 | `p25_try1` (25 ns, first config) | DRC/LVS/antenna clean, but setup WNS −4.99 ns (TNS −328 ns) in the ss corners (tt: +9.3 ns); 4051 max-slew and 75 max-cap violations; 1120 `clkdlybuf4s25_1` + a few `dlymetal6s*` in the netlist | The resizer is allowed to pick **delay cells** as ordinary fanout/repair buffers (nothing excludes them); each adds ~1 ns in ss and has very slow output edges. Synthesis uses the default `AREA 0` strategy. | `EXTRA_EXCLUDED_CELLS` = `clkdlybuf4s*`, `dlymetal6s*` (hold fixing still uses `dlygate4sd*`, the intended hold-delay cells). Tried with and without `SYNTH_STRATEGY "DELAY 1"` (F2). |
| F2 | `p25_try2_excl` | ss setup WNS −2.25 ns (was −4.99), still 3940 slew / 116 cap violations | Delay cells gone, but design repair (slew/fanout) only runs after global placement; CTS, 1148 hold buffers and real routing come later and nothing re-repairs | `RUN_POST_GRT_DESIGN_REPAIR` and `RUN_POST_GRT_RESIZER_TIMING` = true |
| F3 | `p25_try4_postgrt` | ss setup WNS −1.54 ns, slew 2657, cap 4 | Area-oriented synthesis (`AREA 0`) builds slow, deep logic | `SYNTH_STRATEGY` = `"DELAY 1"` (note: passing it with `-c` on the command line failed to parse; set in the config file instead) |
| F4 | `p25_try5_postgrt_delay1` | **Setup and hold met in all 9 corners** (ss WNS +0.307 ns), DRC/LVS/antenna clean; but max-slew violations remain (3000 in max_ss, 215 in nom_tt) | Repair buffers are `clkbuf_1` / `buf_1` (weakest drivers), sized on estimated wires; after detailed routing their nets are slower than estimated | Next: exclude `buf_1`/`clkbuf_1`, cap wire length at 400 µm (F6) |
| F5 | RTL v2 (`rtl/riscv_core.v`) | Critical path in every run: EX forwarding → branch compare → `redirect` → `id_ex_flush` → **reset mux of ~200 ID/EX data flops** (endpoint `id_ex_imm[24]`) | A flush cleared *all* pipeline-register bits, so the branch decision had to fan out to ~200 flops through long buffer chains | Pipeline registers split into control bits (cleared by flush/bubble) and data bits (cleared only by `rst`); all uses of data bits are already gated by control bits. Architecturally identical: 59/59 + 300 new random programs pass, cycle counts identical to `ref/`, lint clean, X-check clean. |
| F6 | `p25_try6_rtlv2` (RTL v2 + F1–F3 config) | Setup/hold met in all corners with much more margin: **ss WNS +2.82 ns** (v1: +0.31 ns), DRC/LVS/antenna clean. Max-slew still 3094 (max_ss) / 148 (nom_tt), max-cap 9 | — | RTL v2 kept. |
| F7 | `p25_try7_rtlv2_strongbuf` | Excluding `buf_1`/`clkbuf_1` + 400 µm max wire length: slew 1768 / 17, but **setup fails** (ss WNS −3.36 ns) | Wire-length buffering puts extra buffers on the critical paths | Rejected. |
| F8 | analysis of try6 | Mid-flow STA right after post-GRT design repair: nom_tt 22 slew violations, **nom_ss 8166** | Design repair (slew/cap/fanout) runs only on `PNR_CORNERS`, which defaults to just `DEFAULT_CORNER` = `nom_tt_025C_1v80`; slow corners are never repaired | `PNR_CORNERS` = `nom_tt_025C_1v80`, `max_ss_100C_1v60` (try8); try9 = same + no `buf_1`/`clkbuf_1` |
| F9 | `p25_try8_pnrcorners` | Result **bit-identical** to try6 | `PNR_CORNERS` is not used by the resizer steps: they take `RSZ_CORNERS`, falling back to all 9 `STA_CORNERS`. All corners are loaded, but OpenROAD `repair_design` evaluates slew/cap limits on the first corner (`nom_tt` in the default order) | Reverted. Next: `RSZ_CORNERS` with `max_ss_100C_1v60` first, then the other 8 (hold repair still sees every corner) (try10). |
| F10 | `p25_try9_pnrcorners_nobuf1` | slew 2263 / 56, setup fails (ss WNS −2.41 ns) | Same as F7: removing the small buffers alone makes the repair insert bigger, slower trees on critical nets | Rejected. |
| F11 | `p25_try10_rszss` (+ `p15_try10_rszss`) | Again **bit-identical** to try6. At 15 ns: ss WNS −3.62 ns, tt WNS +5.02 ns (≈ 10 ns tt critical path, ≈ 1.85× slower in ss) | LibreLane defines corners with `define_corners {*}[array name corner]` (Tcl array = hash order), so list order in `RSZ_CORNERS` has no effect | Reverted. Work with the corner that is repaired instead: over-repair with a bigger margin (F12). |
| F12 | `p25_try11_margin50`, `p20_try11_margin50` | Slew margin 30 % → **50 %** (repair to 0.375 ns in the repaired corner), cap margin 30 %: nom_tt slew 3094 → **0**, max_ss slew → 803 (117 nets, median 0.85 ns, all < the library's 1.5 ns limit), cap 9 → 1; faster edges also improve timing: ss WNS +5.07 ns @ 25 ns and **+0.066 ns @ 20 ns** (all 9 corners met, DRC/LVS/antenna clean) | Remaining: slow-corner slew on `clkbuf_1/2` fanout buffers; 25 max-fanout + 1 max-cap violations, all on the **clock tree** (root buffer drives 16 branches = 0.26 pF vs the flow's 0.20 pF `MAX_CAPACITANCE_CONSTRAINT`; leaf buffers drive 11–16 sinks vs `MAX_FANOUT_CONSTRAINT` 10), which design repair does not touch | Margins kept. Next: margin 65 %, CTS sink clusters ≤ 10, `CTS_MAX_CAP` 0.2 (try12); + max fanout 8 and 100 µm CTS buffer distance (try13) |
| F13 | `p20_try12…`, `p20_try13…` (parallel) | Both runs killed during the first `repair_design`; `dmesg`: **out of memory**, OpenROAD at 3.5 GB RSS (WSL VM has 7.7 GB) | With a 65 % slew margin the repair is much heavier; two at once do not fit | Heavy runs one at a time (try12 rerun alone, peak memory logged). WSL memory left at its default (no system config changes). |
| F14 | `p20_try12_m65_cts` rerun alone | Died again in the first `repair_design` (≈ 1 min into the step); the out-of-memory event takes down the whole WSL distro (all processes, `/tmp`) | A 65 % margin asks `repair_design` for a 0.26 ns slew target that many drivers cannot reach; it keeps buffering and runs out of memory | 65 % abandoned; slew margin stays at 50 %. Clock-tree-only fixes tried on top: `CTS_SINK_CLUSTERING_SIZE` 10, `CTS_MAX_CAP` 0.2 pF (try14). |
| F15 | `p20_try14_m50_cts` (environment, not the design) | Run stopped after ~1 min with only ~0.7 GB in use (no OOM); afterwards every `wsl.exe` call fails with `Catastrophic failure, Error code: Wsl/Service/E_UNEXPECTED` | WSL service fault on the Windows host (the WSL VM had been recreated at 23:49; Windows had only ~6 GB of 15.3 GB RAM free). When the `wsl.exe` client dies, WSL terminates the distro and the flow with it | Needs `wsl --shutdown` (restart of the WSL VM) before continuing; heavy runs one at a time afterwards. try14 to be rerun. |
| F16 | `p20_try14_m50_cts` (after `wsl --shutdown`) | CTS sink clusters ≤ 10 + `CTS_MAX_CAP` 0.2: clock-tree fanout violations 25 → 3, but the root-buffer cap violation stays, and the deeper clock tree costs latency: **setup fails by 16 ps** at 20 ns (−0.016 ns, ss). Peak memory 2.6 GB (single run). | Trade-off between clock-tree design-rule limits and clock latency | Rejected (timing first). **Final configuration = try11** (`flow/config.json`). |

### Final configuration and what is still not clean

`flow/config.json` = try11. With it the design meets setup and hold in all 9 corners at 20 ns, with zero
DRC / LVS / antenna errors. Not clean, and reported in every table:

- max-slew violations **only in the 3 ss corners** (about 800 pins / 117 nets in `max_ss_100C_1v60`, worst ≈ 1.46 ns,
  median ≈ 0.85 ns) against the flow's 0.75 ns limit (the library's own limit is 1.5 ns, and STA uses the
  real slews when it computes delays, so the timing numbers include their effect);
- 1 max-capacitance violation (clock root buffer, 0.26 pF vs the flow's 0.2 pF) and 25 max-fanout violations
  (clock-tree buffers with 11–16 sinks vs 10), all on the clock tree.

Clock sweep: `scripts/sweep.sh` (one run at a time, same config, `-c CLOCK_PERIOD=<ns>`), results in
`results/clock_sweep.md`.

### Clock sweep (final configuration)

| Period | Setup WNS worst / typical | Hold WNS | DRC / LVS / antenna | Result |
|---:|---:|---:|---|---|
| 25 ns | +5.066 / +13.946 ns | +0.099 ns | clean | met |
| **20 ns** | **+0.066 / +9.732 ns** | **+0.099 ns** | **clean** | **met → final** |
| 17.5 ns | −2.434 / +7.232 ns | +0.099 ns | clean | setup fails (ss) |
| 15 ns | −2.804 / +5.791 ns | +0.107 ns | clean | setup fails (ss) |
| 12.5 ns | −2.806 / +3.885 ns | +0.112 ns | clean | setup fails (ss) |
| 10 ns | −2.931 / +2.531 ns | +0.036 ns | clean | setup fails (ss) |

| # | Observation | Cause | Consequence |
|---|-------------|-------|-------------|
| F17 | At 17.5 ns the netlist is identical to 20 ns; `repair_timing` (post-CTS and post-GRT) prints "No setup violations found" although signoff STA shows −2.43 ns in max_ss; below that the typical corner keeps improving but ss stays at ≈ −2.8 ns | The resizer's timing view covers a single corner, `max_tt_025C_1v80` (first in LibreLane's hash-ordered corner list), the same limitation as the slew repair in F8–F11 | 20 ns is the limit of this flow setup, not necessarily of the core. A follow-up could force slow-corner repair (e.g. `RSZ_CORNERS` = slow corner only, then check ff hold in signoff). |
| F18 | `p17_5` took 5.7 h | Detailed routing: 6.6 min CPU vs 5 h 11 min elapsed: the host was asleep overnight | None (result identical to the 20 ns layout). |
