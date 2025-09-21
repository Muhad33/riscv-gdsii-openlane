# gcd.s - greatest common divisor (Euclid, by repeated subtraction) and
# multiplication by repeated addition, as real functions with a stack.
#   gcd(1071, 462) = 21     gcd(270, 192) = 6     gcd(17, 5) = 1    gcd(0, 9) = 9
#   mul(123, 45) = 5535     mul(-6, 7) = -42      mul(7, -6) = -42  mul(1000, 0) = 0
# Results are stored at 0x10000.. (stack grows down from 0x11000, the top of the RAM).

        .text
        li    sp, 0x11000
        li    s0, 0x10000

        li    a0, 1071
        li    a1, 462
        call  gcd
        sw    a0, 0(s0)           # EXPECT_MEM: 0x10000 = 21
        li    a0, 270
        li    a1, 192
        call  gcd
        sw    a0, 4(s0)           # EXPECT_MEM: 0x10004 = 6
        li    a0, 17
        li    a1, 5
        call  gcd
        sw    a0, 8(s0)           # EXPECT_MEM: 0x10008 = 1
        li    a0, 0
        li    a1, 9
        call  gcd
        sw    a0, 12(s0)          # EXPECT_MEM: 0x1000c = 9

        li    a0, 123
        li    a1, 45
        call  mul
        sw    a0, 16(s0)          # EXPECT_MEM: 0x10010 = 5535
        li    a0, -6
        li    a1, 7
        call  mul
        sw    a0, 20(s0)          # EXPECT_MEM: 0x10014 = -42
        li    a0, 7
        li    a1, -6
        call  mul
        sw    a0, 24(s0)          # EXPECT_MEM: 0x10018 = -42
        li    a0, 1000
        li    a1, 0
        call  mul
        sw    a0, 28(s0)          # EXPECT_MEM: 0x1001c = 0

        # gcd of two products: gcd(mul(12, 18), mul(8, 9)) = gcd(216, 72) = 72
        li    a0, 12
        li    a1, 18
        call  mul
        mv    s1, a0              # 216
        li    a0, 8
        li    a1, 9
        call  mul
        mv    a1, a0              # 72
        mv    a0, s1
        call  gcd
        sw    a0, 32(s0)          # EXPECT_MEM: 0x10020 = 72
# EXPECT: sp = 0x11000
        ecall

# a0 = gcd(a0, a1) for a0, a1 >= 0 (Euclid with subtraction)
gcd:    beqz  a0, gcd_b           # gcd(0, b) = b
        beqz  a1, gcd_ret         # gcd(a, 0) = a
gcd_lp: beq   a0, a1, gcd_ret     # equal -> done
        bltu  a0, a1, gcd_sw
        sub   a0, a0, a1
        j     gcd_lp
gcd_sw: sub   a1, a1, a0
        j     gcd_lp
gcd_b:  mv    a0, a1
gcd_ret:
        ret

# a0 = a0 * a1 by repeated addition (saves s registers on the stack)
mul:    addi  sp, sp, -12
        sw    ra, 8(sp)
        sw    s2, 4(sp)
        sw    s3, 0(sp)
        mv    s2, a0              # multiplicand
        mv    s3, a1              # counter
        bgez  s3, mul_pos
        neg   s3, s3              # make the counter positive ...
        neg   s2, s2              # ... and flip the multiplicand
mul_pos:
        li    a0, 0
mul_lp: beqz  s3, mul_end
        add   a0, a0, s2
        addi  s3, s3, -1
        j     mul_lp
mul_end:
        lw    s3, 0(sp)
        lw    s2, 4(sp)
        lw    ra, 8(sp)
        addi  sp, sp, 12
        ret
