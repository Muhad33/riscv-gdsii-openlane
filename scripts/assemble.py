"""Small two-pass RV32I assembler: asm/*.s -> hex files for $readmemh.

Usage:
    python scripts/assemble.py asm/fibonacci.s                 # writes hex/fibonacci.hex (+ _data.hex)
    python scripts/assemble.py asm/fibonacci.s --list          # also print a listing
    python scripts/assemble.py asm/fibonacci.s -o out/prog.hex

Supported:
  * all RV32I instructions (lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw lbu lhu
    sb sh sw addi slti sltiu xori ori andi slli srli srai add sub sll slt sltu xor srl sra
    or and fence ecall ebreak)
  * pseudo-instructions: nop li la mv not neg seqz snez j jr jal(label) jalr(rs) ret call
    beqz bnez blez bgez bltz bgtz bgt ble bgtu bleu
  * labels, comments (# ;), registers x0-x31 and ABI names (zero ra sp gp tp t0-6 s0-11 a0-7 fp)
  * directives: .text .data .word .half .byte .space .align .globl/.global (ignored) .equ NAME, value
  * immediates: decimal, hex (0x), binary (0b), char ('a'), labels, label+/-number, %hi(x) %lo(x)

Memory map: .text at 0x0000_0000 (instruction ROM), .data at 0x0001_0000 (data RAM).
Outputs one 32-bit hex word per line. The .data section goes to <name>_data.hex.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

TEXT_BASE = 0x0000_0000
DATA_BASE = 0x0001_0000

ABI = {"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4, "t0": 5, "t1": 6, "t2": 7, "s0": 8, "fp": 8, "s1": 9,
       **{f"a{i}": 10 + i for i in range(8)}, **{f"s{i}": 16 + i for i in range(2, 12)},
       **{f"t{i}": 25 + i for i in range(3, 7)}}

R_TYPE = {  # name: (funct7, funct3)
    "add": (0x00, 0), "sub": (0x20, 0), "sll": (0x00, 1), "slt": (0x00, 2), "sltu": (0x00, 3),
    "xor": (0x00, 4), "srl": (0x00, 5), "sra": (0x20, 5), "or": (0x00, 6), "and": (0x00, 7),
}
I_ALU = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
I_SHIFT = {"slli": (0x00, 1), "srli": (0x00, 5), "srai": (0x20, 5)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}


class AsmError(Exception):
    pass


@dataclass
class Line:
    lineno: int
    text: str        # original source text
    mnemonic: str
    args: list[str]
    addr: int = 0
    size: int = 0    # bytes in the output
    section: str = "text"


@dataclass
class Program:
    text: dict[int, int] = field(default_factory=dict)    # addr -> word
    data: dict[int, int] = field(default_factory=dict)    # addr -> byte
    listing: list[tuple[int, list[int], str]] = field(default_factory=list)
    symbols: dict[str, int] = field(default_factory=dict)


# ----------------------------------------------------------------------------- helpers


def reg(tok: str) -> int:
    t = tok.strip().lower()
    if t in ABI:
        return ABI[t]
    m = re.fullmatch(r"x(\d+)", t)
    if m and int(m.group(1)) < 32:
        return int(m.group(1))
    raise AsmError(f"bad register '{tok}'")


def split_args(s: str) -> list[str]:
    return [a.strip() for a in s.split(",")] if s.strip() else []


def fits_signed(v: int, bits: int) -> bool:
    return -(1 << (bits - 1)) <= v < (1 << (bits - 1))


def hi_lo(value: int) -> tuple[int, int]:
    """Split a 32-bit value for lui + addi (the addi immediate is sign-extended)."""
    value &= 0xFFFFFFFF
    lo = value & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
    hi = ((value - lo) >> 12) & 0xFFFFF
    return hi, lo


class Assembler:
    def __init__(self) -> None:
        self.symbols: dict[str, int] = {}
        self.lines: list[Line] = []

    # ------------------------------------------------------------- expressions
    def value(self, tok: str, required: bool = True) -> int | None:
        """Evaluate an immediate: number, char, symbol, symbol+/-number, %hi(), %lo()."""
        t = tok.strip()
        m = re.fullmatch(r"%(hi|lo)\((.+)\)", t)
        if m:
            v = self.value(m.group(2), required)
            if v is None:
                return None
            hi, lo = hi_lo(v)
            return hi if m.group(1) == "hi" else lo
        m = re.fullmatch(r"'(.)'", t)
        if m:
            return ord(m.group(1))
        m = re.fullmatch(r"([A-Za-z_.$][\w.$]*)\s*([+-])\s*(.+)", t)
        if m and not re.fullmatch(r"[+-]?(0x[0-9a-fA-F]+|0b[01]+|\d+)", t):
            base = self.value(m.group(1), required)
            off = self.value(m.group(3), required)
            if base is None or off is None:
                return None
            return base + off if m.group(2) == "+" else base - off
        try:
            return int(t, 0)
        except ValueError:
            pass
        if re.fullmatch(r"[A-Za-z_.$][\w.$]*", t):
            if t in self.symbols:
                return self.symbols[t]
            if required:
                raise AsmError(f"undefined symbol '{t}'")
            return None
        raise AsmError(f"bad immediate '{tok}'")

    # ------------------------------------------------------------- sizes (pass 1)
    def size_of(self, ln: Line) -> int:
        m, a = ln.mnemonic, ln.args
        if m == ".word":
            return 4 * len(a)
        if m == ".half":
            return 2 * len(a)
        if m == ".byte":
            return len(a)
        if m == ".space":
            return self.value(a[0])
        if m == "la":
            return 8
        if m == "li":
            v = self.value(a[1], required=False)
            if v is None:
                return 8
            v = v & 0xFFFFFFFF
            sv = v - (1 << 32) if v & 0x80000000 else v
            if fits_signed(sv, 12):
                return 4
            return 4 if hi_lo(v)[1] == 0 else 8
        return 4

    # ------------------------------------------------------------- parsing
    def parse(self, source: str) -> None:
        section = "text"
        pc = {"text": TEXT_BASE, "data": DATA_BASE}
        for n, raw in enumerate(source.splitlines(), 1):
            text = re.split(r"[#;]", raw, maxsplit=1)[0].strip()
            try:
                while True:  # labels (possibly several on one line)
                    m = re.match(r"([A-Za-z_.$][\w.$]*)\s*:\s*(.*)", text)
                    if not m:
                        break
                    if m.group(1) in self.symbols:
                        raise AsmError(f"duplicate label '{m.group(1)}'")
                    self.symbols[m.group(1)] = pc[section]
                    text = m.group(2)
                if not text:
                    continue
                parts = text.split(None, 1)
                mnem = parts[0].lower()
                args = split_args(parts[1]) if len(parts) > 1 else []
                if mnem in (".text", ".data"):
                    section = mnem[1:]
                    continue
                if mnem in (".globl", ".global", ".section", ".type", ".size"):
                    continue
                if mnem == ".equ" or mnem == ".set":
                    self.symbols[args[0]] = self.value(args[1])
                    continue
                if mnem == ".align":
                    align = 1 << self.value(args[0])
                    pc[section] = (pc[section] + align - 1) // align * align
                    continue
                if section == "text" and mnem in (".half", ".byte"):
                    raise AsmError(".half/.byte are only allowed in .data (instruction memory is word-based)")
                ln = Line(n, raw.strip(), mnem, args, pc[section], 0, section)
                ln.size = self.size_of(ln)
                if section == "text" and ln.size % 4:
                    raise AsmError("text section items must be multiples of 4 bytes")
                pc[section] += ln.size
                self.lines.append(ln)
            except AsmError as e:
                raise AsmError(f"line {n}: {e}  [{raw.strip()}]") from None

    # ------------------------------------------------------------- encoders
    @staticmethod
    def enc_r(f7: int, rs2: int, rs1: int, f3: int, rd: int, op: int) -> int:
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    @staticmethod
    def enc_i(imm: int, rs1: int, f3: int, rd: int, op: int) -> int:
        if not fits_signed(imm, 12):
            raise AsmError(f"I-immediate {imm} out of range (-2048..2047)")
        return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

    @staticmethod
    def enc_s(imm: int, rs2: int, rs1: int, f3: int) -> int:
        if not fits_signed(imm, 12):
            raise AsmError(f"S-immediate {imm} out of range (-2048..2047)")
        imm &= 0xFFF
        return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | 0x23

    @staticmethod
    def enc_b(off: int, rs2: int, rs1: int, f3: int) -> int:
        if off % 2 or not fits_signed(off, 13):
            raise AsmError(f"branch offset {off} out of range or odd")
        o = off & 0x1FFF
        return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
            (f3 << 12) | (((o >> 1) & 0xF) << 8) | (((o >> 11) & 1) << 7) | 0x63

    @staticmethod
    def enc_u(imm20: int, rd: int, op: int) -> int:
        return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

    @staticmethod
    def enc_j(off: int, rd: int) -> int:
        if off % 2 or not fits_signed(off, 21):
            raise AsmError(f"jump offset {off} out of range or odd")
        o = off & 0x1FFFFF
        return (((o >> 20) & 1) << 31) | (((o >> 1) & 0x3FF) << 21) | (((o >> 11) & 1) << 20) | \
            (((o >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F

    @staticmethod
    def mem_operand(tok: str) -> tuple[str, str]:
        m = re.fullmatch(r"\s*(.*?)\s*\(\s*(\w+)\s*\)\s*", tok)
        if not m:
            raise AsmError(f"expected imm(reg), got '{tok}'")
        return (m.group(1) or "0"), m.group(2)

    def expand(self, ln: Line) -> list[int]:
        """Machine words for one source line (pass 2)."""
        m, a, pc = ln.mnemonic, ln.args, ln.addr
        v = self.value

        def need(n: int) -> None:
            if len(a) != n:
                raise AsmError(f"'{m}' expects {n} operands, got {len(a)}")

        def off(label: str) -> int:
            return v(label) - pc

        # ---- pseudo-instructions
        if m == "nop":
            return [self.enc_i(0, 0, 0, 0, 0x13)]
        if m == "li":
            need(2)
            rd, val = reg(a[0]), v(a[1]) & 0xFFFFFFFF
            hi, lo = hi_lo(val)
            if ln.size == 4:
                if hi_lo(val)[1] == 0 and not fits_signed(val - (1 << 32) if val >> 31 else val, 12):
                    return [self.enc_u(hi, rd, 0x37)]
                sv = val - (1 << 32) if val >> 31 else val
                return [self.enc_i(sv, 0, 0, rd, 0x13)]
            return [self.enc_u(hi, rd, 0x37), self.enc_i(lo, rd, 0, rd, 0x13)]
        if m == "la":
            need(2)
            rd = reg(a[0])
            hi, lo = hi_lo(v(a[1]))
            return [self.enc_u(hi, rd, 0x37), self.enc_i(lo, rd, 0, rd, 0x13)]
        if m == "mv":
            need(2)
            return [self.enc_i(0, reg(a[1]), 0, reg(a[0]), 0x13)]
        if m == "not":
            need(2)
            return [self.enc_i(-1, reg(a[1]), 4, reg(a[0]), 0x13)]
        if m == "neg":
            need(2)
            return [self.enc_r(0x20, reg(a[1]), 0, 0, reg(a[0]), 0x33)]
        if m == "seqz":
            need(2)
            return [self.enc_i(1, reg(a[1]), 3, reg(a[0]), 0x13)]
        if m == "snez":
            need(2)
            return [self.enc_r(0, reg(a[1]), 0, 3, reg(a[0]), 0x33)]
        if m == "j":
            need(1)
            return [self.enc_j(off(a[0]), 0)]
        if m == "jal" and len(a) == 1:
            return [self.enc_j(off(a[0]), 1)]
        if m == "call":
            need(1)
            return [self.enc_j(off(a[0]), 1)]
        if m == "jr":
            need(1)
            return [self.enc_i(0, reg(a[0]), 0, 0, 0x67)]
        if m == "jalr" and len(a) == 1:
            return [self.enc_i(0, reg(a[0]), 0, 1, 0x67)]
        if m == "ret":
            return [self.enc_i(0, 1, 0, 0, 0x67)]
        zero_br = {"beqz": ("beq", False), "bnez": ("bne", False), "bltz": ("blt", False),
                   "bgez": ("bge", False), "blez": ("bge", True), "bgtz": ("blt", True)}
        if m in zero_br:
            need(2)
            base, swap = zero_br[m]
            r = reg(a[0])
            rs1, rs2 = (0, r) if swap else (r, 0)
            return [self.enc_b(off(a[1]), rs2, rs1, BRANCHES[base])]
        swapped = {"bgt": "blt", "ble": "bge", "bgtu": "bltu", "bleu": "bgeu"}
        if m in swapped:
            need(3)
            return [self.enc_b(off(a[2]), reg(a[0]), reg(a[1]), BRANCHES[swapped[m]])]

        # ---- real instructions
        if m in R_TYPE:
            need(3)
            f7, f3 = R_TYPE[m]
            return [self.enc_r(f7, reg(a[2]), reg(a[1]), f3, reg(a[0]), 0x33)]
        if m in I_ALU:
            need(3)
            return [self.enc_i(v(a[2]), reg(a[1]), I_ALU[m], reg(a[0]), 0x13)]
        if m in I_SHIFT:
            need(3)
            f7, f3 = I_SHIFT[m]
            sh = v(a[2])
            if not 0 <= sh < 32:
                raise AsmError(f"shift amount {sh} out of range (0..31)")
            return [self.enc_r(f7, sh, reg(a[1]), f3, reg(a[0]), 0x13)]
        if m in LOADS:
            need(2)
            imm, base = self.mem_operand(a[1])
            return [self.enc_i(v(imm), reg(base), LOADS[m], reg(a[0]), 0x03)]
        if m in STORES:
            need(2)
            imm, base = self.mem_operand(a[1])
            return [self.enc_s(v(imm), reg(a[0]), reg(base), STORES[m])]
        if m in BRANCHES:
            need(3)
            return [self.enc_b(off(a[2]), reg(a[1]), reg(a[0]), BRANCHES[m])]
        if m == "lui":
            need(2)
            return [self.enc_u(v(a[1]), reg(a[0]), 0x37)]
        if m == "auipc":
            need(2)
            return [self.enc_u(v(a[1]), reg(a[0]), 0x17)]
        if m == "jal":
            need(2)
            return [self.enc_j(off(a[1]), reg(a[0]))]
        if m == "jalr":
            if len(a) == 2:  # jalr rd, imm(rs1)
                imm, base = self.mem_operand(a[1])
                return [self.enc_i(v(imm), reg(base), 0, reg(a[0]), 0x67)]
            need(3)          # jalr rd, rs1, imm
            return [self.enc_i(v(a[2]), reg(a[1]), 0, reg(a[0]), 0x67)]
        if m == "fence":
            return [0x0FF0000F]
        if m == "ecall":
            return [0x00000073]
        if m == "ebreak":
            return [0x00100073]
        raise AsmError(f"unknown instruction '{m}'")

    # ------------------------------------------------------------- pass 2
    def assemble(self, source: str) -> Program:
        self.parse(source)
        prog = Program(symbols=dict(self.symbols))
        for ln in self.lines:
            try:
                if ln.mnemonic in (".word", ".half", ".byte", ".space"):
                    size = {".word": 4, ".half": 2, ".byte": 1}.get(ln.mnemonic, 1)
                    vals = [self.value(x) for x in ln.args] if ln.mnemonic != ".space" else [0] * ln.size
                    raw = b"".join((x & ((1 << (8 * size)) - 1)).to_bytes(size, "little") for x in vals)
                    if ln.section == "text":
                        words = [int.from_bytes(raw[i:i + 4], "little") for i in range(0, len(raw), 4)]
                        for i, w in enumerate(words):
                            prog.text[ln.addr + 4 * i] = w
                        prog.listing.append((ln.addr, words, ln.text))
                    else:
                        for i, b in enumerate(raw):
                            prog.data[ln.addr + i] = b
                        prog.listing.append((ln.addr, [], ln.text))
                    continue
                if ln.section != "text":
                    raise AsmError("instructions are only allowed in .text")
                words = self.expand(ln)
                if 4 * len(words) != ln.size:
                    raise AsmError("internal size mismatch (pass 1 vs pass 2)")
                for i, w in enumerate(words):
                    prog.text[ln.addr + 4 * i] = w & 0xFFFFFFFF
                prog.listing.append((ln.addr, words, ln.text))
            except AsmError as e:
                raise AsmError(f"line {ln.lineno}: {e}  [{ln.text}]") from None
        return prog


# ----------------------------------------------------------------------------- output


def words_from(mem: dict[int, int], base: int, word_bytes: bool) -> list[int]:
    """Contiguous word list from base to the highest used address."""
    if not mem:
        return []
    top = max(mem)
    if word_bytes:  # byte map -> words
        n = (top - base) // 4 + 1
        return [sum(mem.get(base + 4 * i + j, 0) << (8 * j) for j in range(4)) for i in range(n)]
    n = (top - base) // 4 + 1
    return [mem.get(base + 4 * i, 0x00000013) for i in range(n)]


def assemble_file(src: Path, out: Path | None = None, listing: bool = False) -> tuple[Path, Path | None, Program]:
    """Assemble src; write <out>.hex and, if there is a .data section, <out>_data.hex."""
    prog = Assembler().assemble(src.read_text())
    out = out or (src.parent.parent / "hex" / (src.stem + ".hex"))
    out.parent.mkdir(parents=True, exist_ok=True)
    text_words = words_from(prog.text, TEXT_BASE, False)
    out.write_text("".join(f"{w:08x}\n" for w in text_words))
    data_path = None
    data_words = words_from(prog.data, DATA_BASE, True)
    data_path = out.with_name(out.stem + "_data.hex")
    data_path.write_text("".join(f"{w:08x}\n" for w in data_words))  # empty file if no .data
    lst = out.with_suffix(".lst")
    lines = []
    for addr, words, text in prog.listing:
        if words:
            for i, w in enumerate(words):
                lines.append(f"{addr + 4 * i:08x}  {w:08x}  {text if i == 0 else '  (cont.)'}")
        else:
            lines.append(f"{addr:08x}            {text}")
    lst.write_text("\n".join(lines) + "\n")
    if listing:
        print("\n".join(lines))
    return out, data_path, prog


def main() -> int:
    p = argparse.ArgumentParser(description="RV32I assembler -> $readmemh hex")
    p.add_argument("source", type=Path)
    p.add_argument("-o", "--out", type=Path, default=None, help="output .hex (default hex/<name>.hex)")
    p.add_argument("--list", action="store_true", help="print a listing (address, machine code, source)")
    a = p.parse_args()
    try:
        out, data, prog = assemble_file(a.source, a.out, a.list)
    except AsmError as e:
        print(f"{a.source}: error: {e}", file=sys.stderr)
        return 1
    print(f"{a.source} -> {out} ({len(prog.text)} words), {data} ({len(prog.data)} data bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
