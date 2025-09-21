# hazard_test.s - data and control hazards the pipeline must handle:
# EX/MEM and MEM/WB forwarding, register-file write-before-read, load-use stalls,
# loads feeding stores / addresses / branches, x0 writes, JAL/JALR with forwarded
# registers. Expected values are in EXPECT comments.

        .text
        li    s0, 0x10000

# 1) back-to-back dependent ALU ops (EX/MEM -> EX forwarding)
        addi  s1, x0, 1
        addi  s1, s1, 2           # 3
        add   s1, s1, s1          # 6
# EXPECT: s1 = 6

# 2) one instruction in between (MEM/WB -> EX forwarding)
        addi  s11, x0, 10
        nop
        addi  s11, s11, 5         # EXPECT: s11 = 15

# 3) two in between (register file write-before-read, WB -> ID)
        addi  gp, x0, 7
        nop
        nop
        addi  gp, gp, 1           # EXPECT: gp = 8

# 4) both operands forwarded, from different stages
        addi  a0, x0, 3
        addi  a1, x0, 4
        add   a2, a0, a1          # a0 from MEM/WB, a1 from EX/MEM
# EXPECT: a2 = 7

# 5) same register written twice in a row: the newest value must win
        addi  a3, x0, 1
        addi  a3, x0, 2
        add   a4, a3, x0          # EXPECT: a4 = 2

# 6) load-use: one-cycle stall, then MEM/WB forwarding
        sw    s1, 0(s0)           # EXPECT_MEM: 0x10000 = 6
        lw    a5, 0(s0)
        addi  a5, a5, 1           # EXPECT: a5 = 7

# 7) load followed by a store of the loaded value
        lw    a6, 0(s0)
        sw    a6, 4(s0)           # EXPECT_MEM: 0x10004 = 6

# 8) load used two instructions later (no stall needed)
        lw    a7, 4(s0)
        nop
        add   s2, a7, a7          # EXPECT: s2 = 12

# 9) load-use on the address of the next load (pointer chasing)
        li    t3, 0x10008
        sw    t3, 8(s0)           # word at 0x10008 points to itself
        lw    t4, 8(s0)
        lw    t5, 0(t4)           # EXPECT: t5 = 0x10008

# 10) branch right after a load that feeds it
        li    s3, 1
        lw    t6, 0(s0)           # 6
        beq   t6, s1, br_ok       # taken (6 == 6)
        li    s3, 0xbad
br_ok:
# EXPECT: s3 = 1

# 11) branch on values just computed (forwarding into the comparator), loop of 5
        addi  s4, x0, 0
        addi  s5, x0, 5
loop:   addi  s4, s4, 1
        bne   s4, s5, loop        # EXPECT: s4 = 5

# 12) writes to x0 are ignored and never forwarded
        addi  x0, x0, 99
        add   s6, x0, x0          # EXPECT: s6 = 0
        lw    x0, 0(s0)
        add   s7, x0, x0          # EXPECT: s7 = 0

# 13) JAL link register used immediately by the callee
        jal   ra, sub1
ret1:   la    t1, ret1
        sub   s9, s8, t1          # EXPECT: s9 = 0

# 14) store data forwarded from EX/MEM and from MEM/WB
        addi  t1, x0, 0x55
        sw    t1, 12(s0)          # EXPECT_MEM: 0x1000c = 0x55
        addi  t2, x0, 0x66
        nop
        sw    t2, 16(s0)          # EXPECT_MEM: 0x10010 = 0x66

# 15) store address forwarded
        addi  t3, s0, 20
        sw    t1, 0(t3)           # EXPECT_MEM: 0x10014 = 0x55

# 16) JALR target register forwarded (la = lui + addi right before the jump)
        la    t1, target
        jalr  x0, 0(t1)
        li    s10, 0xbad          # skipped
target: addi  s10, x0, 16         # EXPECT: s10 = 16

# 17) load -> dependent ALU -> dependent store chain
        lw    t0, 0(s0)           # 6
        addi  t0, t0, 100         # stall, then 106
        sw    t0, 24(s0)          # EXPECT_MEM: 0x10018 = 106
        ecall

sub1:   addi  s8, ra, 0           # ra forwarded from JAL (EX/MEM)
        ret
