"""Assemble, simulate and check every test program against the golden model.

DUT options:
  default      rtl/riscv_core.v (memories outside the core) in tb/tb_core_with_mem.v
  --ref        the original design (ref/cpu_top.v with on-chip memories, ref/tb_cpu.v)
  --gate NL    a gate-level netlist of riscv_core in tb/tb_core_with_mem.v
               (with --cells for the standard-cell Verilog models)

For each program: assemble -> simulate (iverilog/vvp) -> run rv32i_model.py, then
compare final registers, data memory, the register-write trace and the retired
instruction count. EXPECT / EXPECT_MEM comments in the source are checked too.
Prints a PASS/FAIL table, writes results/cpi_table.md and exits non-zero on any failure.

Usage:
    python scripts/run_tests.py                     # all asm/*.s
    python scripts/run_tests.py --name fibonacci    # one program
    python scripts/run_tests.py --random 50         # plus 50 random programs (seed 1)
    python scripts/run_tests.py --units             # also run tb_alu and tb_regfile
    python scripts/run_tests.py --ref               # original reference design
    python scripts/run_tests.py --gate final/nl/riscv_core.nl.v --cells <models.v ...> --name fibonacci
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from assemble import AsmError, assemble_file, reg  # noqa: E402
from random_program_gen import generate  # noqa: E402
from rv32i_model import DMEM_BASE, ModelError, run_files  # noqa: E402

SIM = ROOT / "sim"
HEX = ROOT / "hex"
RTL = sorted((ROOT / "rtl").glob("*.v"))
SUBMODULES = [f for f in RTL if f.stem != "riscv_core"]
NUM = r"(-?(?:0x[0-9a-fA-F]+|\d+))"
ORDER = ["arith_test", "mem_test", "branch_test", "hazard_test", "fibonacci", "bubble_sort", "gcd"]


@dataclass
class Outcome:
    name: str
    ok: bool
    cycles: int = 0
    instret: int = 0
    note: str = ""

    @property
    def cpi(self) -> float:
        return self.cycles / self.instret if self.instret else float("nan")


def tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        sys.exit(f"error: '{name}' not found on PATH (install Icarus Verilog: "
                 "Windows 'choco install iverilog', Ubuntu 'sudo apt install iverilog', macOS 'brew install icarus-verilog')")
    return path


def compile_tb(top: str, sources: list[Path], out: Path, defines: tuple[str, ...] = (), warn: bool = True) -> None:
    cmd = [tool("iverilog"), "-g2005", *(["-Wall"] if warn else []), *[f"-D{d}" for d in defines],
           "-s", top, "-o", str(out), *map(str, sources)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.exit(f"iverilog failed for {top}:\n{proc.stdout}{proc.stderr}")
    if proc.stderr.strip():
        print(proc.stderr.strip())


def expectations(src: Path) -> list[tuple[str, int, int]]:
    """('reg'|'mem', reg index or address, value) from EXPECT comments."""
    out = []
    for line in src.read_text().splitlines():
        for m in re.finditer(r"EXPECT:\s*(\w+)\s*=\s*" + NUM, line):
            out.append(("reg", reg(m.group(1)), int(m.group(2), 0) & 0xFFFFFFFF))
        for m in re.finditer(r"EXPECT_MEM:\s*" + NUM + r"\s*=\s*" + NUM, line):
            out.append(("mem", int(m.group(1), 0), int(m.group(2), 0) & 0xFFFFFFFF))
    return out


def read_words(path: Path) -> list[int]:
    return [int(t, 16) for t in path.read_text().split()]


def run_program(name: str, src: Path, vvp: Path, sim: Path, gate: bool = False, vcd: bool = False) -> Outcome:
    try:
        hex_path, data_path, _ = assemble_file(src, HEX / f"{name}.hex")
    except AsmError as e:
        return Outcome(name, False, note=f"assembler: {e}")
    prefix = sim / name
    cmd = [tool("vvp"), "-n", str(vvp), f"+HEX={hex_path}", f"+DHEX={data_path}", f"+OUT={prefix}"]
    if vcd and not name.startswith("random"):
        cmd += ["+VCD"]
    elif not vcd:
        cmd += ["+NOVCD"]  # the reference testbench writes a VCD unless told not to
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    if "HALTED" not in proc.stdout:
        return Outcome(name, False, note="sim: " + (proc.stdout.strip().splitlines() or ["no output"])[-1])
    if "ERROR" in proc.stdout:
        return Outcome(name, False, note="sim: " + next(l for l in proc.stdout.splitlines() if "ERROR" in l))
    stats = dict(line.split() for line in (Path(f"{prefix}_stats.txt")).read_text().splitlines())
    cycles, instret = int(stats["cycles"]), int(stats["instret"])
    try:
        model = run_files(hex_path, data_path)
    except ModelError as e:
        return Outcome(name, False, cycles, instret, f"model: {e}")

    problems = []
    regs = read_words(Path(f"{prefix}_regs.txt"))
    mem = read_words(Path(f"{prefix}_mem.txt"))
    for i in range(32):
        if regs[i] != model.regs[i]:
            problems.append(f"x{i}: RTL {regs[i]:08x} model {model.regs[i]:08x}")
    for i, (a, b) in enumerate(zip(mem, model.dmem)):
        if a != b:
            problems.append(f"mem[{DMEM_BASE + 4 * i:#x}]: RTL {a:08x} model {b:08x}")
    trace = [tuple(int(t, 16) if k != 1 else int(t) for k, t in enumerate(l.split()))
             for l in Path(f"{prefix}_commit.txt").read_text().splitlines() if l.strip()]
    expected = [tuple(t) for t in model.trace]
    if gate:  # no PC visible on the netlist: compare (rd, value) only
        trace = [t[1:] for t in trace]
        expected = [t[1:] for t in expected]
    if trace != expected:
        first = next((i for i, (a, b) in enumerate(zip(trace, expected)) if a != b), min(len(trace), len(expected)))
        problems.append(f"register-write trace differs at entry {first} (RTL {len(trace)} writes, model {len(model.trace)})")
    if instret != model.instret:
        problems.append(f"instret: RTL {instret} model {model.instret}")
    for kind, key, value in expectations(src):
        got = regs[key] if kind == "reg" else mem[(key - DMEM_BASE) // 4]
        if got != value:
            where = f"x{key}" if kind == "reg" else f"mem[{key:#x}]"
            problems.append(f"EXPECT {where} = {value:08x}, got {got:08x}")
    note = "; ".join(problems[:3]) + (f" (+{len(problems) - 3} more)" if len(problems) > 3 else "")
    return Outcome(name, not problems, cycles, instret, note)


def run_unit(top: str, sources: list[Path]) -> Outcome:
    vvp = SIM / f"{top}.vvp"
    SIM.mkdir(exist_ok=True)
    compile_tb(top, sources, vvp)
    proc = subprocess.run([tool("vvp"), "-n", str(vvp)], capture_output=True, text=True, cwd=ROOT)
    lines = proc.stdout.strip().splitlines()
    last = next((l for l in reversed(lines) if l.startswith(("PASS", "FAIL"))), "no PASS/FAIL line")
    return Outcome(top, last.startswith("PASS") and "ERROR" not in proc.stdout, note=last)


def main() -> int:
    p = argparse.ArgumentParser(description="RTL vs golden-model regression")
    p.add_argument("--name", help="run only this program (asm/<name>.s)")
    p.add_argument("--random", type=int, default=0, metavar="N", help="also run N random programs")
    p.add_argument("--seed", type=int, default=1, help="seed for the random programs")
    p.add_argument("--units", action="store_true", help="also run the tb_alu / tb_regfile unit tests")
    p.add_argument("--ref", action="store_true", help="simulate the original design (ref/) instead of riscv_core")
    p.add_argument("--gate", type=Path, metavar="NETLIST", help="simulate a gate-level netlist of riscv_core")
    p.add_argument("--cells", type=Path, nargs="*", default=[], help="standard-cell Verilog models for --gate")
    p.add_argument("--vcd", action="store_true", help="write VCD waveforms for the directed programs")
    a = p.parse_args()
    mode = "gate" if a.gate else "ref" if a.ref else "core"
    sim = SIM / mode
    sim.mkdir(parents=True, exist_ok=True)
    HEX.mkdir(exist_ok=True)

    results: list[Outcome] = []
    if a.units:
        results.append(run_unit("tb_alu", [ROOT / "rtl/alu.v", ROOT / "tb/tb_alu.v"]))
        results.append(run_unit("tb_regfile", [ROOT / "rtl/regfile.v", ROOT / "tb/tb_regfile.v"]))

    vvp = sim / "tb.vvp"
    if mode == "ref":
        compile_tb("tb_cpu", SUBMODULES + sorted((ROOT / "ref").glob("*.v")), vvp)
    elif mode == "gate":
        compile_tb("tb_core_with_mem", [*a.cells, a.gate, ROOT / "tb/tb_core_with_mem.v"], vvp,
                   defines=("GATE_LEVEL", "FUNCTIONAL", "UNIT_DELAY=#1"), warn=False)
    else:
        compile_tb("tb_core_with_mem", RTL + [ROOT / "tb/tb_core_with_mem.v"], vvp)
    if a.name == "__none__":  # random programs only (make random)
        names = []
    elif a.name:
        if not (ROOT / "asm" / f"{a.name}.s").exists():
            sys.exit(f"error: asm/{a.name}.s not found")
        names = [a.name]
    else:
        found = sorted(f.stem for f in (ROOT / "asm").glob("*.s"))
        names = [n for n in ORDER if n in found] + [n for n in found if n not in ORDER]
    programs = [(n, ROOT / "asm" / f"{n}.s") for n in names]
    if a.random:
        rnd_dir = SIM / "random"
        rnd_dir.mkdir(exist_ok=True)
        for i in range(a.random):
            path = rnd_dir / f"random_{i:03d}.s"
            path.write_text(generate(a.seed * 100_003 + i))
            programs.append((f"random_{i:03d}", path))

    for name, src in programs:
        results.append(run_program(name, src, vvp, sim, gate=mode == "gate", vcd=a.vcd))

    # ---------------------------------------------------------------- report
    w = max(len(r.name) for r in results)
    lines = [f"{'test':<{w}}  {'result':6}  {'cycles':>7}  {'instr':>6}  {'CPI':>6}  notes",
             "-" * (w + 45)]
    for r in results:
        if r.instret:
            lines.append(f"{r.name:<{w}}  {'PASS' if r.ok else 'FAIL':6}  {r.cycles:7d}  {r.instret:6d}  {r.cpi:6.3f}  {r.note}")
        else:
            lines.append(f"{r.name:<{w}}  {'PASS' if r.ok else 'FAIL':6}  {'':7}  {'':6}  {'':6}  {r.note}")
    n_fail = sum(not r.ok for r in results)
    rnd = [r for r in results if r.name.startswith("random")]
    lines.append("-" * (w + 45))
    if rnd:
        lines.append(f"random programs: {sum(r.ok for r in rnd)}/{len(rnd)} passed, "
                     f"mean CPI {sum(r.cpi for r in rnd) / len(rnd):.3f}")
    lines.append(f"TOTAL: {len(results) - n_fail}/{len(results)} passed" + (" -- ALL TESTS PASSED" if n_fail == 0 else ""))
    print(f"DUT: {mode}" + (f" ({a.gate})" if a.gate else ""))
    print("\n".join(lines))

    directed = [r for r in results if r.instret and not r.name.startswith("random")]
    if directed and not a.name and mode == "core":
        md = ["# CPI per program", "", "| Program | Cycles | Instructions | CPI | Result |", "|---|---:|---:|---:|---|"]
        md += [f"| {r.name} | {r.cycles} | {r.instret} | {r.cpi:.3f} | {'PASS' if r.ok else 'FAIL'} |" for r in directed]
        if rnd:
            md.append(f"| {len(rnd)} random programs (mean) | {sum(r.cycles for r in rnd) // len(rnd)} | "
                      f"{sum(r.instret for r in rnd) // len(rnd)} | {sum(r.cpi for r in rnd) / len(rnd):.3f} | "
                      f"{sum(r.ok for r in rnd)}/{len(rnd)} PASS |")
        md += ["", "Cycles are counted from reset release to the halt, including the 4-cycle pipeline fill.", ""]
        (ROOT / "results").mkdir(exist_ok=True)
        (ROOT / "results" / "cpi_table.md").write_text("\n".join(md))
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
