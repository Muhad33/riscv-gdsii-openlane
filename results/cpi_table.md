# CPI per program

| Program | Cycles | Instructions | CPI | Result |
|---|---:|---:|---:|---|
| arith_test | 106 | 102 | 1.039 | PASS |
| mem_test | 73 | 54 | 1.352 | PASS |
| branch_test | 251 | 163 | 1.540 | PASS |
| hazard_test | 95 | 70 | 1.357 | PASS |
| fibonacci | 188 | 146 | 1.288 | PASS |
| bubble_sort | 1396 | 948 | 1.473 | PASS |
| gcd | 939 | 607 | 1.547 | PASS |
| 50 random programs (mean) | 184 | 150 | 1.228 | 50/50 PASS |

Cycles are counted from reset release to the halt, including the 4-cycle pipeline fill.
