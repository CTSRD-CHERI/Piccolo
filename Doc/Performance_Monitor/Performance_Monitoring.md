# Performance Monitoring module
## Usage
To use the module, enable `PERFORMANCE_MONITORING` in your build (ensure that `BSC_COMPILATION_FLAGS` includes `-D PERFORMANCE_MONITORING` when running make).
Code running on a core with `PERFORMANCE_MONITORING` enabled can now access any of the relevant counter CSRs as specified by the [RISC-V Privileged Specification](https://riscv.org/technical/specifications/) (section __3.1.11 Hardware Performance Monitor__), which would normally be hardcoded to 0 on base Flute.
The implemented CSRs are:
- `mcycle` and `minstret` (also work without `PERFORMANCE_MONITORING` enabled)
- `mhpmcounter3–mhpmcounter31` event counters (29 total)
- `mcycleh`, `minstreth` & `mhpmcounternh` versions of the above to access the high bits on RV32
- `cycle`, `instret` & `hpmcountern` as read-only shadows
- `mhpmevent3-mhpmevent31` event selectors
- `mcounteren` to enable reads to masked counters in S- and U-mode (Seems that check is implemented in CSR_RegFile, but never used)
- `mcountinhibit` to control which counters increment

Unimplemented features are:
- `scounteren` to enable reads to masked counters in U-mode (generally not implemented in Flute)
- Generation of a interrupt when a counter overflows, due to not being defined in the privileged spec. The `PerformanceMonitor` package  read_ctr_overflow

## Events
Any event happening any number of times per cycle in the core can be counted, using the provided `mhpmcounter<N>` and `mhpmevent<N>` CSRs. Most common events are already provided, though it should be simple to extend and add additional events as needed.
The following events along with corresponding event id (this id should be written to the `mhpmevent<N>` selector CSR) are given:
- No event (0x0)

Core events:
- Redirect &ndash; count PC redirects (0x1)
- Stage 2 Traps &ndash; caused by a dmem exception or failed CHERI check (0x2)
- Branch &ndash; count branch instrs (0x3)
- Jal &ndash; count jal instrs (0x4)
- Jalr &ndash; count jalr instrs (0x5)
- Auipc &ndash; count auipc instrs (0x6)
- Load &ndash; count load instrs (0x7)
- Store &ndash; count store instrs (0x8)
- LR &ndash; count lr instrs (0x9)
- SC &ndash; count sc instrs (0xa)
- AMO &ndash; count (non lr or sc) atomic instrs (0xb)
- Serial shift &ndash; count serial shift (slli, srli, srai) instrs (0xc)
- Integer Mult/Div &ndash; count integer multiply and divide instrs (0xd)
- FP &ndash; count all floating point instrs (0xe)
- SC Success &ndash; count SC successes (0xf)
- Load wait &ndash; count cycles stage 2 waiting on load (0x10)
- Store wait &ndash; count cycles stage 2 waiting on store (0x11)
- Fence &ndash; count fence instrs (0x12)
- F Busy No Consume &ndash; count cycles where stage F is busy (0x13)
- D Busy No Consume &ndash; count cycles where stage F is ready to pipe but D is busy (0x14)
- 1 Busy No Consume &ndash; count cycles where stage D is ready to pipe but 1 is busy (0x15)
- 2 Busy No Consume &ndash; count cycles where stage 1 is ready to pipe but 2 is busy (0x16)
- 3 Busy No Consume &ndash; count cycles where stage 2 is ready to pipe but 3 is busy (0x17)
- Imprecise setbounds &ndash; count when a setbounds instr does NOT result in the exact bounds requested (0x18)
- Unrepresentable cap &ndash; count when a capability is out of bounds (due to set offset instr) and is nullified (0x19)
- Mem cap load &ndash; count when stage 2 loads a capability wide thing, regardless of tag (0x1a)
- Mem cap store &ndash; count when stage 2 stores a capability wide thing, regardless of tag (0x1b)
- Mem cap load tag set &ndash; count when stage 2 loads a tagged capability (0x1c)
- Mem cap store tag set &ndash; count when stage 2 stores a tagged capability (0x1d)

IMem and DMem L1 Cache, events identical for both, though some are irrelevant for IMem. IDs in format (IMem/DMem):
- Load &ndash; count loads requested by cpu (0x20/0x30)
- Load miss &ndash; count loads missed (0x21/0x31)
- Load miss latency &ndash; count cycles waiting on a load miss (0x22/0x32)
- Store &ndash; count stores requested by cpu (0x23/0x33)
- Store miss &ndash; unimplemented
- Store miss latency &ndash; unimplemented
- Amo &ndash; count atomic ops requested by cpu (0x26/0x36)
- Amo miss &ndash; count atomics missed (0x27/0x37)
- Amo miss latency &ndash; count cycles waiting on a atomics miss (0x28/0x38)
- Tlb &ndash; count tlb accesses (0x29/0x39)
- Tlb miss &ndash; count tlb missed (0x2a/0x3a)
- Tlb miss latency &ndash; count cycles waiting on a tlb miss (0x2b/0x3b)
- Tlb flush &ndash; count tlb flushes (0x2c/0x3c)
- Evict &ndash; count cache line evictions (0x2d/0x3d)

External events:
Not generic for non-cheri setups but one should try to count all events between any two connected AXI4 master/slave pairs.
For `ISA_CHERI` enabled builds, the `EventsAXI4` struct counts AXI4 events in and out of the tag cache. With IDs in the format (Slave/Master):
- AR Flit (0x40/0x46)
- AW Flit (0x41/0x47)
- W Flit (0x42/0x48)
- R Flit (0x43/0x49)
- R Flit Final (0x44/0x4a)
- B Flit (0x45/0x4b)

That is, to count the extra read requests the tag cache generates, one can count ((0x46) - (0x40)).

If `NO_TAG_CACHE` is NOT defined (i.e. using the `mkTagControllerAXI` tag cache) then the following events will also be counted:
- Write &ndash; count writes to tag cache (0x4c)
- Write miss (0x4d)
- Read (0x4e)
- Read miss (0x4f)
- Evict (0x50)
- Set tag write (0x51)
- Set tag read (0x52)

Missing events are:
- L1 WT CHERI events
- L1 WB events
- L2 WB events