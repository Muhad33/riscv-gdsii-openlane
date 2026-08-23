# Gate-level simulation of the final netlist

**Netlist:** `final/netlist/riscv_core.nl.v` (post-route, from run `p20`), simulated with Icarus Verilog
and the sky130_fd_sc_hd Verilog cell models from the PDK (`primitives.v` + `sky130_fd_sc_hd.v`,
defines `FUNCTIONAL`, `UNIT_DELAY=#1`). Testbench: `tb/tb_core_with_mem.v` compiled with `GATE_LEVEL`.
Internal register names don't exist on the netlist, so the testbench rebuilds the register file from the
core's retire port. Each program is checked against the Python golden model on:

- the full sequence of register writes (rd, value)
- the final register file
- the final data memory
- the retired-instruction count

Commands: `bash scripts/ll.sh bash scripts/gate_sim.sh` (fibonacci + hazard_test); the full run below
used `scripts/run_tests.py --gate … --random 50`.

| Programs | Result |
|---|---|
| fibonacci, hazard_test (requested) | PASS, PASS; cycles identical to RTL (188, 95) |
| all 7 directed programs + 50 random programs | **57 / 57 PASS**; cycles identical to RTL for every program (`results/gate_level_sim.txt`) |

**Negative control.** Three single-gate faults were injected into copies of the netlist (one `and2` cell
changed to `or2`, three different cells, one at a time):

| Fault | Directed programs failing |
|---|---|
| fault 1 | 3 of 7 |
| fault 2 | 0 of 7 (not detected) |
| fault 3 | 1 of 7 |

The check does detect netlist errors. It is not a complete test: one of the three faults sits in logic the
7 programs never exercise.

**Scope.** This is a functional check of the synthesized, placed and routed netlist; zero-delay cell
models are used. Timing is verified separately by static timing analysis in 9 corners (`results/ppa_summary.md`),
not by this simulation; no SDF back-annotated simulation was run.
