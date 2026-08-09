# axi-non-blocking-cache

A non-blocking L1 data cache with AXI4 memory access, built around a
Miss Status Holding Register (MSHR) that supports hit-under-miss
merging and out-of-order fill completion. SystemVerilog RTL with a
directed, self-checking testbench.

## Architecture

| Aspect | Choice |
|---|---|
| Associativity | 4-way set-associative |
| Line size | 4 words (128 bits), matching the AXI burst length |
| Write policy | Write-back, write-allocate |
| Miss handling | Non-blocking via a fully-associative MSHR, up to 16 outstanding misses, with hit-under-miss merging |
| Replacement policy | Not yet decided (LRU vs. pseudo-LRU) — pending the tag-array module |

The cache and the MSHR use two different addressing schemes on purpose:
the cache is indexed (`[TAG | SET | OFFSET]`) for fast, single-row
lookup; the MSHR is fully associative (every entry compared in
parallel) so any in-flight miss can be found regardless of arrival
order. See [`docs/STRUCTURE_README.md`](docs/STRUCTURE_README.md) for
why that split exists and how addresses flow between the two.

```
CPU  <->  Cache Controller  <->  MSHR  <->  Main Memory (AXI4)
```

The MSHR is the only block that ever touches the AXI bus. The cache
controller hands it complete misses and dirty victims; the MSHR turns
those into AXI bursts and hands back completed lines. Full protocol
and rationale: [`docs/MSHR_README.md`](docs/MSHR_README.md),
[`docs/AXI_IF_README.md`](docs/AXI_IF_README.md).

For a step-by-step visual walkthrough before reading the RTL, see
[`visual_flow/`](visual_flow/) (a static block diagram plus an
interactive MATLAB teaching tool — conceptual, not cycle-accurate).

## Status

| Module | RTL | Testbench |
|---|---|---|
| `axi_if.sv` — AXI4 interface | Done | — (exercised via `mshr_tb`) |
| `mshr.sv` — miss handling + writeback | Done | 9 directed tests, all passing |
| Tag array / cache controller | Not started | — |
| Top-level cache | Not started | — |

`mshr.sv` currently covers: single read/write miss fill, hit-under-miss
merge, single victim writeback, MSHR-full stall and recovery,
round-robin fairness of the AXI read-address arbiter, writeback-queue-full
stall and recovery, and fixed-priority ordering of the fill-completion
mux.

## Running the testbench

Requires Questa (path configured in `tools/sim/run.sh`).

```bash
./tools/sim/run.sh
```

Compiles `rtl/axi_if.sv`, `rtl/mshr.sv`, and `tb/mshr_tb.sv` into
`tools/sim/work/`, then runs all directed tests to completion, printing
a `[PASS]`/`[FAIL]` line per test.

## Repo layout

```
rtl/          Synthesizable SystemVerilog modules
tb/           Testbenches
docs/         Per-module design docs (architecture, interface, rationale)
visual_flow/  Conceptual diagrams / interactive teaching aid
tools/sim/    Simulation runner
```
