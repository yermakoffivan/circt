; REQUIRES: verilator
; RUN: firtool --probes-to-signals -verilog %s > %t.sv
; RUN: circt-rtl-sim.py %t.sv --cycles 16 2>&1 | FileCheck %s
;
; Self-checking Verilator smoke tests for force/release synthesis.
; Cases (names from tmp-fr-sim):
;   c1/c12  clocked force/release of a wire; RHS tracks while forced
;   c18     concurrent force+release (release is last → not forced)
;   c19     two clocked forces; later force has higher priority
;   c4      exported regreset, local force, reset while forced
;   c22     child + parent both force one probe; local retrigger wins
;   c5      force one field of a locally-connected bundle
;   c14     self-incrementing register plus force/release
;
; The DUT lives in a child so the default driver is a port.  A constant
; connect to a local wire is copy-propagated before ProbesToSignals and
; deletes the force.  Forceable registers export an unused RWProbe to
; work around a CheckCombLoops crash on an undefined rwprobe.

FIRRTL version 4.0.0
circuit top :
  module ClockedWire :
    input clock : Clock
    input en : UInt<1>
    input rel : UInt<1>
    input v : UInt<8>
    input d : UInt<8>
    output o : UInt<8>

    wire w : UInt<8>
    connect w, d
    connect o, w
    force(clock, en, rwprobe(w), v)
    release(clock, rel, rwprobe(w))

  ; Later force (en2) wins a tie.
  module TwoForces :
    input clock : Clock
    input en1 : UInt<1>
    input en2 : UInt<1>
    input v1 : UInt<8>
    input v2 : UInt<8>
    input d : UInt<8>
    output o : UInt<8>

    wire w : UInt<8>
    connect w, d
    connect o, w
    force(clock, en1, rwprobe(w), v1)
    force(clock, en2, rwprobe(w), v2)

  ; Probe port is unused; it only exists so CheckCombLoops does not crash.
  module ForcedReg :
    input clock : Clock
    input rst : UInt<1>
    input en : UInt<1>
    input rel : UInt<1>
    input v : UInt<8>
    input d : UInt<8>
    output o : UInt<8>
    output p : RWProbe<UInt<8>>

    regreset r : UInt<8>, clock, rst, UInt<8>(0)
    connect r, d
    connect o, r
    define p = rwprobe(r)
    force(clock, en, rwprobe(r), v)
    release(clock, rel, rwprobe(r))

  module LocalForceChild :
    input clock : Clock
    input enL : UInt<1>
    input vL : UInt<8>
    input d : UInt<8>
    output o : UInt<8>
    output p : RWProbe<UInt<8>>

    wire w : UInt<8>
    connect w, d
    connect o, w
    define p = rwprobe(w)
    force(clock, enL, rwprobe(w), vL)

  module BundleField :
    input clock : Clock
    input en : UInt<1>
    input v : UInt<8>
    input x : UInt<8>
    input y : UInt<8>
    output oa : UInt<8>
    output ob : UInt<8>

    wire w : {a : UInt<8>, b : UInt<8>}
    connect w.a, x
    connect w.b, y
    connect oa, w.a
    connect ob, w.b
    force(clock, en, rwprobe(w.a), v)

  ; Probe port is unused; it only exists so CheckCombLoops does not crash.
  module SelfIncReg :
    input clock : Clock
    input rst : UInt<1>
    input en : UInt<1>
    input rel : UInt<1>
    input v : UInt<8>
    output o : UInt<8>
    output p : RWProbe<UInt<8>>

    regreset r : UInt<8>, clock, rst, UInt<8>(0)
    connect r, add(r, UInt<8>(1))
    connect o, r
    define p = rwprobe(r)
    force(clock, en, rwprobe(r), v)
    release(clock, rel, rwprobe(r))

  public module top :
    input clk : Clock
    input rst : UInt<1>

    regreset cycle : UInt<8>, clk, rst, UInt<8>(0)
    connect cycle, add(cycle, UInt<8>(1))
    node nreset = eq(rst, UInt<1>(0))
    ; Non-constant default driver so IMCP cannot fold the target away.
    node d = pad(rst, 8)
    node y = pad(nreset, 8)
    ; Live RHS: AA through cycle 2, BB afterwards.
    node vLive = mux(gt(cycle, UInt<8>(2)), UInt<8>(0hBB), UInt<8>(0hAA))

    inst c1 of ClockedWire
    connect c1.clock, clk
    connect c1.en, eq(cycle, UInt<8>(1))
    connect c1.rel, eq(cycle, UInt<8>(7))
    connect c1.v, vLive
    connect c1.d, d

    ; Concurrent force+release on the same edge; release is last in ClockedWire.
    inst c18 of ClockedWire
    connect c18.clock, clk
    connect c18.en, eq(cycle, UInt<8>(1))
    connect c18.rel, eq(cycle, UInt<8>(1))
    connect c18.v, UInt<8>(0hAA)
    connect c18.d, d

    inst c19 of TwoForces
    connect c19.clock, clk
    connect c19.en1, or(eq(cycle, UInt<8>(1)), eq(cycle, UInt<8>(5)))
    connect c19.en2, or(eq(cycle, UInt<8>(3)), eq(cycle, UInt<8>(5)))
    connect c19.v1, UInt<8>(0hA1)
    connect c19.v2, UInt<8>(0hA2)
    connect c19.d, d

    inst c4 of ForcedReg
    connect c4.clock, clk
    connect c4.rst, or(rst, eq(cycle, UInt<8>(3)))
    connect c4.en, eq(cycle, UInt<8>(1))
    connect c4.rel, eq(cycle, UInt<8>(7))
    connect c4.v, UInt<8>(0hAA)
    connect c4.d, d

    inst c22 of LocalForceChild
    connect c22.clock, clk
    connect c22.enL, or(eq(cycle, UInt<8>(1)), eq(cycle, UInt<8>(5)))
    connect c22.vL, mux(gt(cycle, UInt<8>(4)), UInt<8>(0hC1), UInt<8>(0hA1))
    connect c22.d, d
    force(clk, eq(cycle, UInt<8>(3)), c22.p, UInt<8>(0hA2))
    release(clk, eq(cycle, UInt<8>(7)), c22.p)

    inst c5 of BundleField
    connect c5.clock, clk
    connect c5.en, eq(cycle, UInt<8>(1))
    connect c5.v, vLive
    connect c5.x, d
    connect c5.y, y

    inst c14 of SelfIncReg
    connect c14.clock, clk
    connect c14.rst, rst
    connect c14.en, eq(cycle, UInt<8>(1))
    connect c14.rel, eq(cycle, UInt<8>(7))
    connect c14.v, UInt<8>(0h10)

    ; CHECK: idle w1={{0*}}00 conc={{0*}}00 two={{0*}}00 reg={{0*}}00 lp={{0*}}00 ba={{0*}}00 bb={{0*}}01 inc={{0*}}00
    printf(clk, and(nreset, eq(cycle, UInt<8>(0))), "idle w1=%x conc=%x two=%x reg=%x lp=%x ba=%x bb=%x inc=%x\n", c1.o, c18.o, c19.o, c4.o, c22.o, c5.oa, c5.ob, c14.o)
    ; CHECK: forced w1={{0*}}aa conc={{0*}}00 two={{0*}}a1 reg={{0*}}aa lp={{0*}}a1 ba={{0*}}aa bb={{0*}}01 inc={{0*}}10
    printf(clk, and(nreset, eq(cycle, UInt<8>(2))), "forced w1=%x conc=%x two=%x reg=%x lp=%x ba=%x bb=%x inc=%x\n", c1.o, c18.o, c19.o, c4.o, c22.o, c5.oa, c5.ob, c14.o)
    ; CHECK: live w1={{0*}}bb reg={{0*}}aa ba={{0*}}bb bb={{0*}}01
    printf(clk, and(nreset, eq(cycle, UInt<8>(3))), "live w1=%x reg=%x ba=%x bb=%x\n", c1.o, c4.o, c5.oa, c5.ob)
    ; CHECK: pri two={{0*}}a2 lp={{0*}}a2
    printf(clk, and(nreset, eq(cycle, UInt<8>(4))), "pri two=%x lp=%x\n", c19.o, c22.o)
    ; CHECK: pri2 two={{0*}}a2 lp={{0*}}c1
    printf(clk, and(nreset, eq(cycle, UInt<8>(6))), "pri2 two=%x lp=%x\n", c19.o, c22.o)
    ; CHECK: released w1={{0*}}00 reg={{0*}}00 lp={{0*}}00 inc={{0*}}11
    printf(clk, and(nreset, eq(cycle, UInt<8>(8))), "released w1=%x reg=%x lp=%x inc=%x\n", c1.o, c4.o, c22.o, c14.o)
    ; CHECK: PASS
    printf(clk, and(nreset, eq(cycle, UInt<8>(10))), "PASS\n")
    stop(clk, and(nreset, eq(cycle, UInt<8>(10))), 0)
