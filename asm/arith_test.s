# arith_test.s - every RV32I ALU instruction, with edge cases.
# Each result is stored to the data RAM; expected values are checked by run_tests.py
# ("EXPECT_MEM: address = value" and "EXPECT: register = value" comments).

        .text
        li    s0, 0x10000         # result area
        li    a0, 0x7fffffff      # INT_MAX
        li    a1, 0x80000000      # INT_MIN
        li    a2, -1              # 0xffffffff
        li    a3, 1
        li    a4, 5
        li    a5, -7              # 0xfffffff9

# ---- add / sub / addi, including signed overflow (wraps, no trap in RISC-V)
        add   t0, a0, a3          # INT_MAX + 1 -> INT_MIN
        sw    t0, 0(s0)           # EXPECT_MEM: 0x10000 = 0x80000000
        sub   t0, a1, a3          # INT_MIN - 1 -> INT_MAX
        sw    t0, 4(s0)           # EXPECT_MEM: 0x10004 = 0x7fffffff
        sub   t0, a4, a5          # 5 - (-7) = 12
        sw    t0, 8(s0)           # EXPECT_MEM: 0x10008 = 0x0000000c
        addi  t0, a2, -2048       # -1 - 2048 = -2049 (most negative 12-bit immediate)
        sw    t0, 12(s0)          # EXPECT_MEM: 0x1000c = 0xfffff7ff
        addi  t0, a0, 2047        # INT_MAX + 2047 wraps
        sw    t0, 16(s0)          # EXPECT_MEM: 0x10010 = 0x800007fe

# ---- logic
        li    t1, 0x0ff00ff0
        li    t2, 0x00ffff00
        and   t0, t1, t2
        sw    t0, 20(s0)          # EXPECT_MEM: 0x10014 = 0x00f00f00
        or    t0, t1, t2
        sw    t0, 24(s0)          # EXPECT_MEM: 0x10018 = 0x0ffffff0
        xor   t0, t1, t2
        sw    t0, 28(s0)          # EXPECT_MEM: 0x1001c = 0x0f0ff0f0
        andi  t0, t1, -16         # immediate is sign-extended to 0xfffffff0
        sw    t0, 32(s0)          # EXPECT_MEM: 0x10020 = 0x0ff00ff0
        ori   t0, t1, 0x00f
        sw    t0, 36(s0)          # EXPECT_MEM: 0x10024 = 0x0ff00fff
        xori  t0, t1, -1          # bitwise NOT
        sw    t0, 40(s0)          # EXPECT_MEM: 0x10028 = 0xf00ff00f

# ---- signed vs unsigned compares
        slt   t0, a1, a0          # INT_MIN < INT_MAX (signed)       -> 1
        sw    t0, 44(s0)          # EXPECT_MEM: 0x1002c = 1
        sltu  t0, a1, a0          # 0x80000000 < 0x7fffffff (unsigned) -> 0
        sw    t0, 48(s0)          # EXPECT_MEM: 0x10030 = 0
        slt   t0, a5, a4          # -7 < 5                          -> 1
        sw    t0, 52(s0)          # EXPECT_MEM: 0x10034 = 1
        sltu  t0, a5, a4          # 0xfffffff9 < 5 (unsigned)       -> 0
        sw    t0, 56(s0)          # EXPECT_MEM: 0x10038 = 0
        slti  t0, a5, -6          # -7 < -6                         -> 1
        sw    t0, 60(s0)          # EXPECT_MEM: 0x1003c = 1
        sltiu t0, a3, -1          # 1 < 0xffffffff (imm sign-extended, compared unsigned) -> 1
        sw    t0, 64(s0)          # EXPECT_MEM: 0x10040 = 1
        sltiu t0, a2, 5           # 0xffffffff < 5                  -> 0
        sw    t0, 68(s0)          # EXPECT_MEM: 0x10044 = 0
        slt   t0, a4, a4          # equal                           -> 0
        sw    t0, 72(s0)          # EXPECT_MEM: 0x10048 = 0

# ---- register shifts (only the low 5 bits of rs2 count)
        li    t1, 0x80000001
        sll   t0, t1, x0          # shift by 0
        sw    t0, 76(s0)          # EXPECT_MEM: 0x1004c = 0x80000001
        li    t2, 31
        sll   t0, t1, t2
        sw    t0, 80(s0)          # EXPECT_MEM: 0x10050 = 0x80000000
        srl   t0, t1, t2
        sw    t0, 84(s0)          # EXPECT_MEM: 0x10054 = 0x00000001
        sra   t0, t1, t2
        sw    t0, 88(s0)          # EXPECT_MEM: 0x10058 = 0xffffffff
        li    t2, 33              # 33 & 31 = 1
        srl   t0, t1, t2
        sw    t0, 92(s0)          # EXPECT_MEM: 0x1005c = 0x40000000
        sra   t0, t1, t2
        sw    t0, 96(s0)          # EXPECT_MEM: 0x10060 = 0xc0000000

# ---- immediate shifts
        slli  t0, t1, 0
        sw    t0, 100(s0)         # EXPECT_MEM: 0x10064 = 0x80000001
        slli  t0, t1, 31
        sw    t0, 104(s0)         # EXPECT_MEM: 0x10068 = 0x80000000
        srli  t0, t1, 31
        sw    t0, 108(s0)         # EXPECT_MEM: 0x1006c = 0x00000001
        srai  t0, t1, 31
        sw    t0, 112(s0)         # EXPECT_MEM: 0x10070 = 0xffffffff
        srai  t0, a0, 31          # positive number: fills with 0
        sw    t0, 116(s0)         # EXPECT_MEM: 0x10074 = 0
        srli  t0, a1, 4
        sw    t0, 120(s0)         # EXPECT_MEM: 0x10078 = 0x08000000
        srai  t0, a1, 4
        sw    t0, 124(s0)         # EXPECT_MEM: 0x1007c = 0xf8000000

# ---- upper immediates
        lui   t0, 0xabcde
        sw    t0, 128(s0)         # EXPECT_MEM: 0x10080 = 0xabcde000
here:   auipc t0, 0               # t0 = address of this instruction
        la    t1, here
        sub   t0, t0, t1          # 0 if AUIPC used the right PC
        sw    t0, 132(s0)         # EXPECT_MEM: 0x10084 = 0
        auipc t0, 1               # PC + 0x1000
        sub   t0, t0, t1          # (here + 20) + 0x1000 - here
        sw    t0, 136(s0)         # EXPECT_MEM: 0x10088 = 0x00001014

# ---- x0 stays zero; pseudo-instructions
        addi  x0, x0, 123
        add   t0, x0, x0
        sw    t0, 140(s0)         # EXPECT_MEM: 0x1008c = 0
        neg   t0, a4
        sw    t0, 144(s0)         # EXPECT_MEM: 0x10090 = 0xfffffffb
        not   t0, x0
        sw    t0, 148(s0)         # EXPECT_MEM: 0x10094 = 0xffffffff
        seqz  t0, x0
        sw    t0, 152(s0)         # EXPECT_MEM: 0x10098 = 1
        snez  t0, a5
        sw    t0, 156(s0)         # EXPECT_MEM: 0x1009c = 1

# final register values
# EXPECT: a0 = 0x7fffffff
# EXPECT: a1 = 0x80000000
# EXPECT: a5 = 0xfffffff9
# EXPECT: zero = 0
        ecall
