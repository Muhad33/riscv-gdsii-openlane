# branch_test.s - all six branch types (taken and not taken, signed vs unsigned),
# JAL, JALR (including offset and bit-0 clearing) and loops.
# s1 counts passed checks (12); any wrong branch jumps to 'fail'.

        .text
        li    s1, 0
        li    s11, 0              # becomes 0xbad on failure
        li    a0, 5
        li    a1, -3              # 0xfffffffd: negative signed, huge unsigned
        li    a2, 5

# BEQ
        beq   a0, a2, beq_t       # taken
        j     fail
beq_t:  addi  s1, s1, 1
        beq   a0, a1, fail        # not taken
        addi  s1, s1, 1
# BNE
        bne   a0, a1, bne_t       # taken
        j     fail
bne_t:  addi  s1, s1, 1
        bne   a0, a2, fail        # not taken
        addi  s1, s1, 1
# BLT (signed)
        blt   a1, a0, blt_t       # -3 < 5: taken
        j     fail
blt_t:  addi  s1, s1, 1
        blt   a0, a2, fail        # 5 < 5: not taken
        addi  s1, s1, 1
# BGE (signed)
        bge   a0, a1, bge_t       # 5 >= -3: taken
        j     fail
bge_t:  addi  s1, s1, 1
        bge   a1, a0, fail        # -3 >= 5: not taken
        addi  s1, s1, 1
# BLTU (unsigned)
        bltu  a0, a1, bltu_t      # 5 < 0xfffffffd: taken
        j     fail
bltu_t: addi  s1, s1, 1
        bltu  a1, a0, fail        # not taken
        addi  s1, s1, 1
# BGEU (unsigned)
        bgeu  a1, a0, bgeu_t      # taken
        j     fail
bgeu_t: addi  s1, s1, 1
        bgeu  a0, a1, fail        # not taken
        addi  s1, s1, 1
        bgeu  a0, a2, bgeu_eq     # equal: taken
        j     fail
bgeu_eq:
# EXPECT: s1 = 12

# JAL: call a function and check the link address
        li    s2, 0
        jal   ra, add_ten         # s2 += 10
ret1:   jal   add_ten             # pseudo form (rd = ra): s2 += 10
        la    t0, ret1
        sub   s3, s4, t0          # s4 = last ra seen by add_ten; must equal ret1 + 4
# EXPECT: s2 = 20
# EXPECT: s3 = 4

# JALR: computed jump, offset, link register and bit-0 clearing
        la    t0, jt
        jalr  s5, 8(t0)           # at jt - 8: jump to jt + 8, s5 = jt - 4
        addi  s11, x0, 1          # skipped (failure marker)
jt:     addi  s11, x0, 2          # jt + 0: skipped
        addi  s11, x0, 3          # jt + 4: skipped
        la    t1, jt              # jt + 8: lands here
        sub   s9, t1, s5          # jt - (jt - 4)
        la    t0, jt20
        addi  t0, t0, 1           # odd address: JALR clears bit 0
        jalr  x0, 0(t0)
        addi  s11, x0, 4          # skipped
jt20:   addi  s6, x0, 1           # must land here
# EXPECT: s9 = 4
# EXPECT: s6 = 1

# loops: sum 1..10 and a nested 4 x 5 loop
        li    t0, 0
        li    t1, 1
        li    t2, 11
sum:    add   t0, t0, t1
        addi  t1, t1, 1
        blt   t1, t2, sum
        mv    s7, t0              # EXPECT: s7 = 55
        li    s8, 0
        li    t3, 4
outer:  li    t4, 5
inner:  addi  s8, s8, 1
        addi  t4, t4, -1
        bnez  t4, inner
        addi  t3, t3, -1
        bgtz  t3, outer
# EXPECT: s8 = 20
        beqz  s11, done
fail:   li    s11, 0xbad
done:
# EXPECT: s11 = 0
        ecall

# function: s2 += 10, remembers its return address in s4
add_ten:
        addi  s2, s2, 10
        mv    s4, ra
        ret
