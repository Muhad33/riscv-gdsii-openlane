"""Generate random but valid, hazard-heavy RV32I programs for RTL vs golden-model testing.

Guarantees:
  * every load/store uses base register t6 (x31) = 0x10000 with an aligned offset in
    a 256-byte scratch area, so there are no illegal or misaligned accesses
  * control flow only goes forward, except counted loops (t5 = x30, 1..4 iterations),
    so every program terminates and ends with ECALL
  * t4 (x29), t5 and t6 are reserved; all other registers (including x0 as a
    destination) are fair game
Hazards are provoked on purpose: sources are biased towards the most recently written
registers, loads are often followed immediately by a use, and branches/jumps follow
dependent instructions.

Usage:
    python scripts/random_program_gen.py --seed 7 -o sim/random/r7.s
"""

from __future__ import annotations

import argparse
import random
from pathlib import Path

POOL = list(range(1, 21))  # x1..x20
R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT_I = ["slli", "srli", "srai"]
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = {"lw": 4, "lh": 2, "lhu": 2, "lb": 1, "lbu": 1}
STORES = {"sw": 4, "sh": 2, "sb": 1}


class Gen:
    def __init__(self, seed: int) -> None:
        self.r = random.Random(seed)
        self.lines: list[str] = []
        self.recent: list[int] = []
        self.label = 0

    def new_label(self) -> str:
        self.label += 1
        return f"L{self.label}"

    def dst(self) -> int:
        rd = 0 if self.r.random() < 0.04 else self.r.choice(POOL)  # occasional write to x0
        self.recent = ([rd] + self.recent)[:3]
        return rd

    def src(self) -> int:
        if self.recent and self.r.random() < 0.65:
            return self.r.choice(self.recent)  # depend on a very recent result
        return self.r.choice(POOL + [0])

    def emit(self, s: str) -> None:
        self.lines.append("        " + s)

    # ------------------------------------------------------------ building blocks
    def alu(self) -> None:
        k = self.r.random()
        if k < 0.45:
            a, b = self.src(), self.src()
            self.emit(f"{self.r.choice(R_OPS)} x{self.dst()}, x{a}, x{b}")
        elif k < 0.80:
            a = self.src()
            self.emit(f"{self.r.choice(I_OPS)} x{self.dst()}, x{a}, {self.r.randint(-2048, 2047)}")
        elif k < 0.93:
            a = self.src()
            self.emit(f"{self.r.choice(SHIFT_I)} x{self.dst()}, x{a}, {self.r.choice([0, 1, 31, self.r.randint(0, 31)])}")
        else:
            op = self.r.choice(["lui", "auipc"])
            self.emit(f"{op} x{self.dst()}, {self.r.randint(0, 0xFFFFF)}")

    def store(self) -> None:
        op = self.r.choice(list(STORES))
        size = STORES[op]
        self.emit(f"{op} x{self.src()}, {self.r.randrange(0, 256, size)}(t6)")

    def load(self) -> None:
        op = self.r.choice(list(LOADS))
        size = LOADS[op]
        self.emit(f"{op} x{self.dst()}, {self.r.randrange(0, 256, size)}(t6)")
        if self.r.random() < 0.6:  # immediate use -> load-use stall
            self.alu()

    def branch(self) -> None:
        lab = self.new_label()
        a, b = self.src(), self.src()
        self.emit(f"{self.r.choice(BRANCHES)} x{a}, x{b}, {lab}")
        for _ in range(self.r.randint(1, 3)):
            self.alu()
        self.lines.append(f"{lab}:")

    def jump(self) -> None:
        lab = self.new_label()
        if self.r.random() < 0.5:
            self.emit(f"jal x{self.dst()}, {lab}")
        else:
            self.emit(f"la t4, {lab}")
            self.emit(f"jalr x{self.dst()}, 0(t4)")
        for _ in range(self.r.randint(1, 2)):
            self.alu()
        self.lines.append(f"{lab}:")

    def loop(self) -> None:
        lab = self.new_label()
        self.emit(f"li t5, {self.r.randint(1, 4)}")
        self.lines.append(f"{lab}:")
        for _ in range(self.r.randint(1, 4)):
            self.r.choice([self.alu, self.alu, self.load, self.store])()
        self.emit("addi t5, t5, -1")
        self.emit(f"bnez t5, {lab}")

    def program(self, n_blocks: int = 60) -> str:
        self.lines.append("# random hazard-heavy RV32I program (generated)")
        self.lines.append("        .text")
        self.emit("li t6, 0x10000")
        for r in POOL:
            self.emit(f"li x{r}, {self.r.choice([0, 1, -1, 0x7FFFFFFF, -0x80000000, self.r.randint(-2**31, 2**31 - 1)])}")
        blocks = [self.alu] * 6 + [self.load] * 3 + [self.store] * 3 + [self.branch] * 2 + [self.jump, self.loop]
        for _ in range(n_blocks):
            self.r.choice(blocks)()
        self.emit("ecall")
        return "\n".join(self.lines) + "\n"


def generate(seed: int, n_blocks: int = 60) -> str:
    return Gen(seed).program(n_blocks)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--blocks", type=int, default=60)
    p.add_argument("-o", "--out", type=Path, default=None)
    a = p.parse_args()
    text = generate(a.seed, a.blocks)
    if a.out:
        a.out.parent.mkdir(parents=True, exist_ok=True)
        a.out.write_text(text)
        print(f"wrote {a.out}")
    else:
        print(text)


if __name__ == "__main__":
    main()
