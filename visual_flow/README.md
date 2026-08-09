# MSHR Data-Flow Diagram

`mshr_dataflow_diagram.html` is a static block diagram (open directly
in a browser) — CPU → controller → MSHR (fill engine + writeback
queue) → memory, with the fill engine's AR/R and the writeback queue's
AW/W/B drawn as two independent, directly-wired channel groups rather
than a shared port, plus a signal glossary and the read-miss step list
for quick reference.

**This is a conceptual teaching aid, not a functional or cycle-accurate
model of `rtl/mshr.sv`.** It does not read the RTL and is not a
substitute for the testbench in `tb/`. It exists to answer "what talks
to what, and in which order" before diving into "how is each signal
actually driven." It covers the MSHR's three data-flow scenarios: read
miss, write miss (identical AXI fetch, but the line comes back flagged
for merge + dirty), and writeback (victim drained over `AW`/`W`,
confirmed by `B`).

See `docs/MSHR_README.md` for the full design rationale these
scenarios are based on.
