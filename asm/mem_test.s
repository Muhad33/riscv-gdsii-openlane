# mem_test.s - loads and stores of every size, sign / zero extension, byte and
# halfword offsets inside a word, negative offsets, and a load into x0.
# Data RAM is little-endian: the word 0x8899aabb holds bytes bb aa 99 88.

        .data
src:    .word 0x8899aabb          # 0x10000: bytes bb aa 99 88
        .word 0x7f01807f          # 0x10004: bytes 7f 80 01 7f

        .text
        la    s0, src             # 0x10000
        li    s1, 0x10100         # results

        lw    t0, 0(s0)
        sw    t0, 0(s1)           # EXPECT_MEM: 0x10100 = 0x8899aabb
        lb    t0, 0(s0)           # 0xbb sign-extended
        sw    t0, 4(s1)           # EXPECT_MEM: 0x10104 = 0xffffffbb
        lbu   t0, 0(s0)
        sw    t0, 8(s1)           # EXPECT_MEM: 0x10108 = 0x000000bb
        lb    t0, 1(s0)           # byte offset 1
        sw    t0, 12(s1)          # EXPECT_MEM: 0x1010c = 0xffffffaa
        lbu   t0, 2(s0)           # byte offset 2
        sw    t0, 16(s1)          # EXPECT_MEM: 0x10110 = 0x00000099
        lb    t0, 3(s0)           # byte offset 3
        sw    t0, 20(s1)          # EXPECT_MEM: 0x10114 = 0xffffff88
        lh    t0, 0(s0)
        sw    t0, 24(s1)          # EXPECT_MEM: 0x10118 = 0xffffaabb
        lhu   t0, 0(s0)
        sw    t0, 28(s1)          # EXPECT_MEM: 0x1011c = 0x0000aabb
        lh    t0, 2(s0)           # upper halfword
        sw    t0, 32(s1)          # EXPECT_MEM: 0x10120 = 0xffff8899
        lhu   t0, 2(s0)
        sw    t0, 36(s1)          # EXPECT_MEM: 0x10124 = 0x00008899

# positive values must not be sign-extended (second word: bytes 7f 80 01 7f)
        lb    t0, 4(s0)
        sw    t0, 40(s1)          # EXPECT_MEM: 0x10128 = 0x0000007f
        lb    t0, 5(s0)
        sw    t0, 44(s1)          # EXPECT_MEM: 0x1012c = 0xffffff80
        lh    t0, 6(s0)
        sw    t0, 48(s1)          # EXPECT_MEM: 0x10130 = 0x00007f01
        lh    t0, 4(s0)
        sw    t0, 52(s1)          # EXPECT_MEM: 0x10134 = 0xffff807f

# byte and halfword stores only change their own bytes
        li    t1, 0x11223344
        sw    t1, 56(s1)
        li    t2, 0xab
        sb    t2, 57(s1)          # byte 1
        li    t2, 0x1cd           # only the low byte (0xcd) is stored
        sb    t2, 59(s1)          # byte 3
        lw    a0, 56(s1)          # EXPECT_MEM: 0x10138 = 0xcd22ab44
        li    t2, 0xbeef
        sh    t2, 60(s1)          # lower half of a zero word
        li    t2, 0x12345678
        sh    t2, 62(s1)          # upper half gets 0x5678
        lw    a1, 60(s1)          # EXPECT_MEM: 0x1013c = 0x5678beef
        sb    t2, 64(s1)          # EXPECT_MEM: 0x10140 = 0x00000078

# negative offsets
        addi  s2, s1, 80
        sw    t1, -12(s2)         # EXPECT_MEM: 0x10144 = 0x11223344
        lw    t0, -12(s2)
        sw    t0, 72(s1)          # EXPECT_MEM: 0x10148 = 0x11223344

# a load into x0 is discarded
        lw    x0, 0(s0)

# EXPECT: a0 = 0xcd22ab44
# EXPECT: a1 = 0x5678beef
# EXPECT: zero = 0
# the source data is unchanged
# EXPECT_MEM: 0x10000 = 0x8899aabb
        ecall
