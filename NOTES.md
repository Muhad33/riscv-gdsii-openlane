# Notes: from RTL to a chip layout

Plain-language notes for this project. Numbers come from this design (`results/`, `final/reports/`)
unless marked as a simple made-up example.

---

## 1. What an ASIC flow is

An **ASIC** (application-specific integrated circuit) is a chip made for one design. An FPGA programs
a fixed chip; an ASIC turns the Verilog into the actual shapes of transistors and wires that a factory
(a **foundry**) prints on silicon.

The **flow** is the chain of tools that does this automatically:

```
Verilog ──synthesis──> gate netlist ──floorplan──> placement ──clock tree──> routing ──signoff──> GDSII
```

The result is a **GDSII** file: a list of polygons, one layer per mask, which is what the foundry
needs. Here the flow is **LibreLane** (the successor of OpenLane 2), which drives Yosys (synthesis),
OpenROAD (placement, clock tree, routing, timing), Magic and KLayout (layout checks), and Netgen (LVS).

## 2. PDK and standard cells

A **PDK** (process design kit) describes one manufacturing process: the layers, the minimum widths
and spacings, and the electrical models. This project uses **SkyWater sky130**, an open 130 nm process.
"130 nm" is roughly the smallest transistor length.

**Standard cells** are pre-drawn small circuits: NAND, NOR, flip-flop, buffer, and so on. They all
have the same height so they can sit side by side in rows. The library used is `sky130_fd_sc_hd`
("high density"). Every cell comes with:

- a layout (its polygons),
- a LEF abstract (its size and pin positions, for placement and routing),
- a Liberty timing model (delay vs. load and input slope, at each corner).

Example sizes from the library:

| Cell | What it is | Area |
|---|---|---:|
| `nand2_1` | 2-input NAND | 3.75 µm² |
| `dfxtp_2` | D flip-flop (1 bit of storage) | 21.3 µm² |
| `mux4_2` | 4-to-1 multiplexer | 22.5 µm² |

## 3. The flow stages

**Synthesis (Yosys).** Turns the Verilog into a netlist of standard cells. Here the result was
7,138 cells and about 90,000 µm² before layout. `SYNTH_STRATEGY "DELAY 1"` asks the synthesis tool
to prefer faster, shallower logic over the smallest area.

**Floorplan.** Chooses the die size and places the I/O pins and the power grid.

- `FP_CORE_UTIL = 40` means the cells should fill about 40 % of the core area at the start. The
  rest is space for buffers and for routing.
- 90,000 µm² / 0.40 ≈ 225,000 µm² of core. The actual core is 474 × 473 µm = 224,500 µm².
- The power grid is a mesh of wide metal straps that carries VDD and ground to every row.

**Placement.** Puts every cell at a legal spot in a row.

- *Global placement* minimizes total wire length.
- *Detailed placement* removes overlaps.
- After placement the tool repairs electrical problems by resizing cells and inserting buffers:
  slow signal edges (*slew*), too much load on one output (*capacitance*), and too many inputs on
  one net (*fanout*).

**Clock tree synthesis (CTS).** The clock must reach about 1,440 flip-flops at nearly the same time.
CTS builds a tree of clock buffers from the `clk` pin to every flip-flop.

- *Skew* is the difference in clock arrival time between two flip-flops.
- *Latency* is the time from the `clk` pin to a flip-flop.
- In the final design the clock passes about 4 buffer levels; latency is about 2.2 ns in the slow corner.

**Routing.** Draws the metal wires that connect everything, on 5 metal layers plus `li1` (a local
layer inside the cells).

- *Global routing* plans which regions each wire passes through.
- *Detailed routing* draws the exact tracks without breaking any spacing rule.
- Final total wire length: 553,934 µm, about 0.55 m of wire in 0.24 mm².

**Signoff.** The final checks before a design could go to a foundry: timing (STA), DRC, LVS and
antenna (see sections 4 and 7).

## 4. Setup and hold timing

Every flip-flop samples its input on the rising clock edge. Two rules must hold for every path from
one flip-flop (the *launch*) to the next (the *capture*):

- **Setup:** the data must arrive *some time before* the next clock edge.
  Rule: `clk→Q + logic delay + setup time ≤ clock period`.
- **Hold:** the data must *not change too soon after* the edge, or the capturing flip-flop would see
  the new value instead of the old one.
  Rule: `clk→Q + logic delay ≥ hold time`.

**Slack** = how much margin is left. Positive slack means the rule is met; negative means it is
violated. **WNS** (worst negative slack) is the slack of the worst path. **TNS** (total negative slack)
is the sum over all failing endpoints; 0 means nothing fails.

**Worked example (made-up round numbers):** clock period 20 ns.

| Item | Value |
|---|---:|
| clock→Q of launching flop | 0.7 ns |
| logic delay (forwarding mux → ALU → branch compare → PC mux) | 18.5 ns |
| setup time of capturing flop | 0.3 ns |
| clock uncertainty (jitter margin) | 0.25 ns |
| **arrival** = 0.7 + 18.5 | 19.2 ns |
| **required** = 20 − 0.3 − 0.25 | 19.45 ns |
| **setup slack** = required − arrival | **+0.25 ns ✓** |

At a 18 ns period the required time drops to 17.45 ns. The slack would be 17.45 − 19.2 = −1.75 ns:
a violation, and the chip would compute wrong results at that speed.

**Hold example:** a short path, flop → mux → flop, with a total delay of 0.15 ns. Required:
hold time 0.05 ns + uncertainty 0.25 ns = 0.30 ns. Slack = 0.15 − 0.30 = −0.15 ns: violated. A faster
clock does **not** fix hold. The tool inserts delay cells instead. This design needed 1,152 of them
(`dlygate4sd3_1`), mostly on the short paths into the register file.

**Corners.** Delays depend on manufacturing (**p**rocess), supply **v**oltage and **t**emperature
(PVT), and on the wire resistance and capacitance. Signoff checks 9 corners: 3 PVT × 3 RC.

- `tt_025C_1v80`: typical silicon, 25 °C, 1.80 V
- `ss_100C_1v60`: slow silicon, hot, low voltage. **Worst for setup.**
- `ff_n40C_1v95`: fast silicon, cold, high voltage. **Worst for hold.**
- `min` / `nom` / `max`: wire resistance and capacitance

The same path is about **1.9× slower** in ss than in tt. In the final design, setup slack is +9.7 ns
in tt but only +0.066 ns in max_ss.

The real worst path is in `final/reports/sta/max_ss_100C_1v60/worst_setup_path.rpt`: data arrives
at 21.651 ns and is required by 21.716 ns, so slack is +0.066 ns. Both times include about 2.2 ns of
clock latency.

## 5. Why the memories are kept off-chip

The CPU needs a 4 KiB instruction memory and a 4 KiB data memory: 2 × 32,768 = 65,536 bits.

**As flip-flops** (what synthesis would build from a Verilog array):

- 65,536 bits × 21.3 µm² ≈ **1.4 mm²** for the flip-flops alone.
- Read multiplexers and write-enable logic add roughly as much again.
- Total: around 2.5–3 mm², more than **10×** the whole final core die (0.24 mm²).
- The flow would also run for hours.

**The 32 × 32 register file (kept inside the core):**

- 31 × 32 = 992 flip-flops × 21.3 µm² ≈ 21,100 µm².
- Plus its two 32-input read multiplexers.
- In total roughly a quarter of the logic area. That is fine for 1 Kbit, but it does not scale to
  64 Kbit.

**As SRAM macros:** an SRAM stores a bit in a compact 6-transistor cell instead of a ~20-transistor
flip-flop. The sky130 PDK ships OpenRAM macros:

- `sky130_sram_1kbyte_1rw1r_32x256_8` (8,192 bits) is 479.8 × 397.5 µm = **0.19 mm²**.
- `sky130_sram_2kbyte_1rw1r_32x512_8` (16,384 bits) is 683.1 × 416.5 µm = **0.28 mm²**.
- So 4 KiB as two 2 KiB macros ≈ 0.57 mm². That is still big, because these small macros are mostly
  periphery (decoders, sense amplifiers), but much smaller than flip-flops.
- Larger memories get much denser per bit.

So the core exposes **memory ports** (`imem_*`, `dmem_*`). A real chip would connect them to SRAM
macros or to an external memory. This project builds and signs off only the core.

## 6. Clock frequency and period

`frequency = 1 / period`, so a period in ns gives a frequency of 1000 / period MHz.

| Period | Frequency | Result in this project |
|---:|---:|---|
| 25 ns | 40 MHz | met (+5.07 ns) |
| **20 ns** | **50 MHz** | **met (+0.066 ns), final design** |
| 17.5 ns | 57.1 MHz | fails setup in ss (−2.43 ns) |
| 15 ns | 66.7 MHz | fails (−2.80 ns) |
| 12.5 ns | 80 MHz | fails (−2.81 ns) |
| 10 ns | 100 MHz | fails (−2.93 ns) |
| 5 ns | 200 MHz | (not tried) |
| 1 ns | 1 GHz | (not tried) |

The typical corner still meets timing at 10 ns. The flow's timing repair works against a single
corner, the typical one (see `docs/iteration_log.md` F17), so 20 ns is the limit of this flow setup.

## 7. DRC, LVS and antenna checks

- **DRC (design rule check).** Checks every polygon against the foundry's geometry rules: minimum
  width, spacing, overlap, enclosure. Example: two `met1` wires closer than 0.14 µm could short when
  printed. Checked by Magic, by KLayout and by the router. Result: **0 / 0 / 0 errors**.
- **LVS (layout vs. schematic).** Extracts the transistors and connections from the drawn layout
  and compares them with the netlist. A missing via or an accidental short shows up as a mismatch.
  Result: Netgen reports **"Circuits match uniquely"**, 0 errors.
- **Antenna check.** During manufacturing a long metal wire collects electric charge (it acts like an
  antenna). If it connects only to a transistor gate, the charge can damage the thin gate oxide. Fixes:
  - change routing layers, so the wire is broken up by a jump to a higher layer, or
  - add a small **diode** that drains the charge.

  Result: 0 violations, with 88 repair diodes inserted.
- Also clean: **XOR**, where the GDS written by Magic and by KLayout are identical (0 differences).

**Not clean**, and reported as is:

- Max-slew violations exist only in the 3 slow corners. They are over the flow's own 0.75 ns target
  but under the library's 1.5 ns limit, and STA already uses the real slews when computing delay.
- 1 max-capacitance and 25 max-fanout violations, all on the clock tree.

## 8. What the final numbers mean

| Number | Meaning |
|---|---|
| 50 MHz, setup +0.066 ns in the worst corner | Even slow silicon at 100 °C and 1.60 V would run at 50 MHz, with 66 ps to spare. Typical silicon has ~10 ns of slack, so it could clock much faster. |
| CPI 1.23 (average over the test programs) | 1.23 clock cycles per instruction, so ≈ 50 / 1.23 ≈ **41 million instructions per second**. |
| 0.24 mm² die (485 × 496 µm) | About half a millimetre on a side, the size of a grain of fine sand. It is the core only: no memories, no I/O pads. |
| 57 % utilization | 57 % of the core area holds logic cells; the rest is filler and decap cells (which keep the supply stable). |
| 15,606 logic cells | Only 7,138 came from synthesis. The rest is what physical design added: buffers for long wires and fanout (3,770), hold-fix delay cells (1,152), and the clock tree (292). |
| 8.3 mW (estimate) | At 41 MIPS that is ≈ 0.2 nJ (200 pJ) per instruction. The estimate uses a default switching activity, not a real program, so treat it as order-of-magnitude. |
| 0 DRC / 0 LVS / 0 antenna | The layout is manufacturable by the rules the flow checks. It has not been fabricated, has no pad ring, and has not been checked by a foundry. |
