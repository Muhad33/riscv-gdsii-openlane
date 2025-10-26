#!/bin/bash
# ASIC-readiness checks for rtl/riscv_core.v (run inside the LibreLane nix-shell,
# e.g. scripts/ll.sh bash scripts/lint.sh). Writes results/lint_report.txt.
#   1. Verilator --lint-only -Wall          (width, unused, latch, multi-driven ...)
#   2. Yosys: latches, async/odd flip-flops, combinational loops, undriven nets
set -u
cd "$(dirname "$0")/.."
mkdir -p results
OUT=results/lint_report.txt
RTL="rtl/alu.v rtl/control_unit.v rtl/forwarding_unit.v rtl/hazard_unit.v rtl/imm_gen.v rtl/regfile.v rtl/riscv_core.v"
{
echo "== Verilator lint (-Wall) =="
verilator --version
verilator --lint-only -Wall -Wno-DECLFILENAME --top-module riscv_core $RTL 2>&1
echo "verilator exit code: $?"
echo
echo "== Yosys structural checks =="
yosys -q -p "
  read_verilog $RTL;
  hierarchy -check -top riscv_core;
  proc; opt_clean;
  tee -o /dev/stdout check -noinit;
  flatten; memory -nomap; opt_clean;
  tee -o /dev/stdout log latches_and_sr_cells:; tee -o /dev/stdout select -count t:\$dlatch t:\$adlatch t:\$dlatchsr t:\$sr;
  tee -o /dev/stdout log async_reset_or_set_ffs:; tee -o /dev/stdout select -count t:\$adff t:\$adffe t:\$dffsr t:\$dffsre t:\$aldff t:\$aldffe;
  tee -o /dev/stdout log sync_ff_cells_(word-level):; tee -o /dev/stdout select -count t:\$dff t:\$dffe t:\$sdff t:\$sdffe t:\$sdffce;
  tee -o /dev/stdout log memories_(regfile_expected):; tee -o /dev/stdout select -count t:\$mem t:\$mem_v2;
  tee -o /dev/stdout log combinational_loop_cells:; scc -select; tee -o /dev/stdout select -count %;
" 2>&1
echo "yosys exit code: $?"
} | tee $OUT
