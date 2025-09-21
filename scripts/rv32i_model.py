"""RV32I instruction-set simulator (golden model) for checking the RTL.

Runs the same hex files as the RTL (instruction ROM at 0x0, data RAM at 0x10000) and
produces the final register file, data memory, retired-instruction count and a trace
of register writes (pc, rd, value). It uses the same conventions as the RTL:
ECALL/EBREAK halt (and count as retired), FENCE and CSR instructions are NOPs, and
writes to x0 are discarded.

Usage:
    python scripts/rv32i_model.py hex/fibonacci.hex [--data hex/fibonacci_data.hex] [--trace]
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path

IMEM_WORDS = 1024
DMEM_BASE = 0x0001_0000
DMEM_WORDS = 1024
MASK = 0xFFFFFFFF


class ModelError(Exception):
    pass


def sext(v: int, bits: int) -> int:
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def signed(v: int) -> int:
    return sext(v, 32)


def read_hex(path: Path | None) -> list[int]:
    if path is None or not Path(path).exists():
        return []
    return [int(t, 16) for t in Path(path).read_text().split() if t and not t.startswith("//")]


@dataclass
class Result:
    regs: list[int]
    dmem: list[int]                 # words
    instret: int
    halted: bool
    trace: list[tuple[int, int, int]] = field(default_factory=list)  # (pc, rd, value) of register writes


class RV32I:
    def __init__(self, imem: list[int], dmem: list[int] | None = None) -> None:
        self.imem = (imem + [0x00000013] * IMEM_WORDS)[:IMEM_WORDS]
        self.dmem = bytearray(4 * DMEM_WORDS)
        for i, w in enumerate((dmem or [])[:DMEM_WORDS]):
            self.dmem[4 * i:4 * i + 4] = (w & MASK).to_bytes(4, "little")
        self.x = [0] * 32
        self.pc = 0
        self.trace: list[tuple[int, int, int]] = []
        self.instret = 0

    # --------------------------------------------------------------- memory
    def _addr(self, addr: int, size: int) -> int:
        off = addr - DMEM_BASE
        if not 0 <= off <= len(self.dmem) - size:
            raise ModelError(f"data access 0x{addr:08x} outside data RAM (pc 0x{self.pc:08x})")
        if addr % size:
            raise ModelError(f"misaligned {size}-byte access at 0x{addr:08x} (pc 0x{self.pc:08x})")
        return off

    def load(self, addr: int, size: int, is_signed: bool) -> int:
        off = self._addr(addr, size)
        v = int.from_bytes(self.dmem[off:off + size], "little")
        return sext(v, 8 * size) & MASK if is_signed else v

    def store(self, addr: int, size: int, value: int) -> None:
        off = self._addr(addr, size)
        self.dmem[off:off + size] = (value & ((1 << (8 * size)) - 1)).to_bytes(size, "little")

    def write(self, rd: int, value: int) -> None:
        if rd != 0:
            self.x[rd] = value & MASK
            self.trace.append((self.pc, rd, value & MASK))

    # --------------------------------------------------------------- execution
    def step(self) -> bool:
        """Execute one instruction; returns False when the program halts."""
        if self.pc % 4 or not 0 <= self.pc < 4 * IMEM_WORDS:
            raise ModelError(f"PC 0x{self.pc:08x} outside instruction ROM or misaligned")
        ins = self.imem[self.pc >> 2]
        op, rd, f3 = ins & 0x7F, (ins >> 7) & 0x1F, (ins >> 12) & 7
        rs1, rs2, f7 = (ins >> 15) & 0x1F, (ins >> 20) & 0x1F, ins >> 25
        a, b = self.x[rs1], self.x[rs2]
        imm_i = sext(ins >> 20, 12)
        imm_s = sext(((ins >> 25) << 5) | ((ins >> 7) & 0x1F), 12)
        imm_b = sext((((ins >> 31) & 1) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 0x3F) << 5)
                     | (((ins >> 8) & 0xF) << 1), 13)
        imm_u = ins & 0xFFFFF000
        imm_j = sext((((ins >> 31) & 1) << 20) | (((ins >> 12) & 0xFF) << 12) | (((ins >> 20) & 1) << 11)
                     | (((ins >> 21) & 0x3FF) << 1), 21)
        next_pc = (self.pc + 4) & MASK
        self.instret += 1

        if op == 0x37:                                  # LUI
            self.write(rd, imm_u)
        elif op == 0x17:                                # AUIPC
            self.write(rd, self.pc + imm_u)
        elif op == 0x6F:                                # JAL
            self.write(rd, self.pc + 4)
            next_pc = (self.pc + imm_j) & MASK
        elif op == 0x67:                                # JALR (target uses the old rs1)
            target = (a + imm_i) & MASK & ~1
            self.write(rd, self.pc + 4)
            next_pc = target
        elif op == 0x63:                                # branches
            taken = {0: a == b, 1: a != b, 4: signed(a) < signed(b), 5: signed(a) >= signed(b),
                     6: a < b, 7: a >= b}.get(f3, False)
            if taken:
                next_pc = (self.pc + imm_b) & MASK
        elif op == 0x03:                                # loads
            addr = (a + imm_i) & MASK
            size, sgn = {0: (1, True), 1: (2, True), 2: (4, False), 4: (1, False), 5: (2, False)}[f3]
            self.write(rd, self.load(addr, size, sgn))
        elif op == 0x23:                                # stores
            self.store((a + imm_s) & MASK, {0: 1, 1: 2, 2: 4}[f3], b)
        elif op in (0x13, 0x33):                        # OP-IMM / OP
            y = imm_i & MASK if op == 0x13 else b
            sh = y & 0x1F
            alt = (f7 >> 5) & 1
            if f3 == 0:
                r = a - y if (op == 0x33 and alt) else a + y
            elif f3 == 1:
                r = a << sh
            elif f3 == 2:
                r = int(signed(a) < signed(y))
            elif f3 == 3:
                r = int(a < (y & MASK))
            elif f3 == 4:
                r = a ^ y
            elif f3 == 5:
                r = (signed(a) >> sh) if alt else (a >> sh)
            elif f3 == 6:
                r = a | y
            else:
                r = a & y
            self.write(rd, r)
        elif op == 0x73 and f3 == 0:                    # ECALL / EBREAK -> halt
            return False
        # FENCE (0x0F), CSR (0x73, f3 != 0) and unknown opcodes: NOP
        self.pc = next_pc
        return True

    def run(self, max_steps: int = 2_000_000) -> Result:
        for _ in range(max_steps):
            if not self.step():
                words = [int.from_bytes(self.dmem[i:i + 4], "little") for i in range(0, len(self.dmem), 4)]
                return Result(list(self.x), words, self.instret, True, self.trace)
        raise ModelError(f"no halt after {max_steps} instructions")


def run_files(hex_path: Path, data_path: Path | None = None, max_steps: int = 2_000_000) -> Result:
    return RV32I(read_hex(hex_path), read_hex(data_path)).run(max_steps)


def main() -> int:
    p = argparse.ArgumentParser(description="RV32I golden model")
    p.add_argument("hex", type=Path)
    p.add_argument("--data", type=Path, default=None)
    p.add_argument("--trace", action="store_true", help="print the register-write trace")
    a = p.parse_args()
    data = a.data or a.hex.with_name(a.hex.stem + "_data.hex")
    try:
        r = run_files(a.hex, data)
    except ModelError as e:
        print(f"model error: {e}", file=sys.stderr)
        return 1
    if a.trace:
        for pc, rd, v in r.trace:
            print(f"{pc:08x} x{rd:<2d} <= {v:08x}")
    for i in range(0, 32, 4):
        print("  ".join(f"x{j:<2d}={r.regs[j]:08x}" for j in range(i, i + 4)))
    print(f"instructions retired: {r.instret}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
