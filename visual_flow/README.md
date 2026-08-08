# MSHR Visual Flow Simulator

A MATLAB GUI (`mshr_simulator.m`) that walks through the MSHR's data flow
one step at a time, for building intuition before reading the RTL or the
testbench signal-by-signal.

`mshr_dataflow_diagram.html` is a static companion block diagram (open
directly in a browser) — CPU → controller → MSHR (fill engine +
writeback queue) → memory, with the fill engine's AR/R and the
writeback queue's AW/W/B drawn as two independent, directly-wired
channel groups rather than a shared port, plus a signal glossary and
the read-miss step list for quick reference.

**This is a conceptual teaching aid, not a functional or cycle-accurate
model of `rtl/mshr.sv`.** It does not read the RTL, does not simulate
logic, and is not a substitute for the testbench in `tb/`. It exists to
answer "what talks to what, and in which order" before diving into "how
is each signal actually driven."

## Running it

```matlab
cd visual_flow
mshr_simulator
```

Pick a scenario from the dropdown, then step through it with
Next/Previous. Each step highlights the block currently holding the
data, draws the active handshake (an internal signal or an AXI
channel), and prints the signals that would be asserted at that point.

## Scenarios covered

1. **Read Miss** — a load misses; MSHR fetches the line over `AR`/`R`
   and hands it back via `fill_valid`.
2. **Write Miss** — a store misses. Same AXI fetch as a read miss (this
   design is write-allocate), but the line comes back with
   `fill_is_write=1`, and the controller marks it dirty after merging
   the store — this is how a dirty line is created.
3. **Writeback (Eviction)** — a dirty victim is drained from the MSHR's
   writeback queue over `AW`/`W`, and the `B` response confirms the
   write before the queue slot is freed.

The Writeback scenario's last step also explains why AXI writes need a
dedicated response channel (`B`) while reads don't: read data already
flows memory → MSHR on `R`, so a status code can ride along with it; a
write's data channel (`W`) only flows the other way, so `B` is the only
wire carrying an acknowledgement back.

See `private_notes/MSHR_README.md` for the full design rationale these
scenarios are based on.
