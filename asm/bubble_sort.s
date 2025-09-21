# bubble_sort.s - sort 16 signed words in place (ascending), with early exit when a
# pass makes no swaps.
# Input:  34 -5 17 0 99 -120 7 7 1000 -1 23 56 -77 3 12 2
# Output: -120 -77 -5 -1 0 2 3 7 7 12 17 23 34 56 99 1000

        .data
array:  .word 34, -5, 17, 0, 99, -120, 7, 7, 1000, -1, 23, 56, -77, 3, 12, 2

        .text
        la    s0, array
        li    s1, 16              # n
outer:  li    t5, 0               # swapped flag
        addi  s1, s1, -1          # compare n-1 pairs
        blez  s1, done
        mv    t0, s0              # p
        mv    t1, s1              # pairs left
inner:  lw    t2, 0(t0)
        lw    t3, 4(t0)
        ble   t2, t3, noswap      # signed compare
        sw    t3, 0(t0)
        sw    t2, 4(t0)
        li    t5, 1
noswap: addi  t0, t0, 4
        addi  t1, t1, -1
        bnez  t1, inner
        bnez  t5, outer
done:   lw    a0, 0(s0)           # smallest
        lw    a1, 60(s0)          # largest
        ecall

# EXPECT: a0 = -120
# EXPECT: a1 = 1000
# EXPECT_MEM: 0x10000 = -120
# EXPECT_MEM: 0x10004 = -77
# EXPECT_MEM: 0x10008 = -5
# EXPECT_MEM: 0x1000c = -1
# EXPECT_MEM: 0x10010 = 0
# EXPECT_MEM: 0x10014 = 2
# EXPECT_MEM: 0x10018 = 3
# EXPECT_MEM: 0x1001c = 7
# EXPECT_MEM: 0x10020 = 7
# EXPECT_MEM: 0x10024 = 12
# EXPECT_MEM: 0x10028 = 17
# EXPECT_MEM: 0x1002c = 23
# EXPECT_MEM: 0x10030 = 34
# EXPECT_MEM: 0x10034 = 56
# EXPECT_MEM: 0x10038 = 99
# EXPECT_MEM: 0x1003c = 1000
