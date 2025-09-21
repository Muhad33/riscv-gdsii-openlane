# fibonacci.s - store the first 20 Fibonacci numbers F(0)..F(19) as words at 0x10000.
# F = 0 1 1 2 3 5 8 13 21 34 55 89 144 233 377 610 987 1597 2584 4181

        .text
        li    s0, 0x10000         # output pointer
        li    t0, 0               # F(n)
        li    t1, 1               # F(n+1)
        li    t2, 20              # count
loop:   sw    t0, 0(s0)
        add   t3, t0, t1          # F(n+2)
        mv    t0, t1
        mv    t1, t3
        addi  s0, s0, 4
        addi  t2, t2, -1
        bnez  t2, loop
        mv    a0, t0              # F(20) = 6765 (one step past the stored list)
        ecall

# EXPECT_MEM: 0x10000 = 0
# EXPECT_MEM: 0x10004 = 1
# EXPECT_MEM: 0x10008 = 1
# EXPECT_MEM: 0x1000c = 2
# EXPECT_MEM: 0x10010 = 3
# EXPECT_MEM: 0x10014 = 5
# EXPECT_MEM: 0x10018 = 8
# EXPECT_MEM: 0x1001c = 13
# EXPECT_MEM: 0x10020 = 21
# EXPECT_MEM: 0x10024 = 34
# EXPECT_MEM: 0x10028 = 55
# EXPECT_MEM: 0x1002c = 89
# EXPECT_MEM: 0x10030 = 144
# EXPECT_MEM: 0x10034 = 233
# EXPECT_MEM: 0x10038 = 377
# EXPECT_MEM: 0x1003c = 610
# EXPECT_MEM: 0x10040 = 987
# EXPECT_MEM: 0x10044 = 1597
# EXPECT_MEM: 0x10048 = 2584
# EXPECT_MEM: 0x1004c = 4181
# EXPECT: a0 = 6765
