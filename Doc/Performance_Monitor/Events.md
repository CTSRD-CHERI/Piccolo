Refer to `Performance_Monitoring.md` for implementation details.

## Flute counters
### Mem
- [ ] L1 I$ Load count
- [ ] L1 I$ Load miss count
- [ ] L1 I$ Load miss latency sum
- [ ] L1 D$ Load count
- [ ] L1 D$ Load miss count
- [ ] L1 D$ Load miss latency sum
- [ ] L1 D$ Store count
- [ ] _L1 D$ Store miss count (currently does not affect performance)_
- [ ] _L1 D$ Store miss latency sum (not currently needed)_
- [ ] L1 D$ Atomic op count
- [ ] L1 D$ Atomic op miss count
- [ ] L1 D$ Atomic op miss latency sum
- [ ] _L2/LLC (not currently implemented)_
- [ ] I TLB Access count
- [ ] I TLB Miss count
- [ ] I TLB Miss latency sum
- [ ] D TLB Access count
- [ ] D TLB Miss count
- [ ] D TLB Miss latency sum
### Core
- [ ] Redirect PC count (eg. due to misprediction)
- [ ] Redirect PC due to {branch,jump,...?} count
- [ ] Serial shift instr count
- [ ] Integer mul/div instr count
- [ ] FP instr count (maybe count specific instrs?)
- [ ] TLB exception count
- [ ] SC success count
- [ ] Load memory latency sum
- [ ] Store memory latency sum
- [ ] Fence count
- [ ] Flush TLB count (due to SFENCE.VMA)
- [ ] Cycle count
- [ ] Instructions retired count
- [ ] Cycles waiting on stage{F,D,1,2,3}

Please add any other events which it may be useful to count, maybe some CHERI specific events (see below for ARM and Toooba events)
## Riscv Spec
All counters are 64bit registers  
Cycle and retired instruction counters required  
Up to 29 generic counters each with corresponding event selector CSR  
Event 0 is no event, other events defined by platform  
A future revision will define a mechanism to generate an interrupt when a counter overflows
## Arm Spec
64bit cycle counter  
Up to 31 generic counters, either 32 or 64bit  
Flag set and optional interrupt on overflow  
Counters can be written, to allow arbitrary frequency of interrupts  
Many common predefined events, space for custom events
- Common microarchitectural events:  
  https://static.docs.arm.com/ddi0487/fb/DDI0487F_b_armv8_arm.pdf#G25.11133487
- Common architectural events (possibly less interesting):  
  https://static.docs.arm.com/ddi0487/fb/DDI0487F_b_armv8_arm.pdf#G25.10914501
- Some memory counter ratios:  
  https://static.docs.arm.com/ddi0487/fb/DDI0487F_b_armv8_arm.pdf#G25.10920567
- Events required to count (short list):  
  https://static.docs.arm.com/ddi0487/fb/DDI0487F_b_armv8_arm.pdf#G25.10910311
## Toooba Events
One counter per event, all events counted  
Counters are `Count#(Data)` from Cntrs package (Data-wide counters)  
'Counter set' or 'overflow interrupt' NOT possible, global 'counter enable'  
Some events are specific to this core and couldn't be used for other cores
### Recorded events
- Memory
  - L1 {Instruction,Data} Cache (events counted for both)
    - Load count
    - Load miss count
    - Load miss latency sum
    - Reconcile count (For self invalidating cache)
  - L1 Data Cache only
    - Store count
    - Store miss count
    - Store miss latency sum
    - Atomic op count
    - Atomic op miss count
    - Atomic op miss latency sum
    - Self invalidation count (For self invalidating cache)
  - Last level cache
    - DMA mem load count
    - DMA mem load latency sum
    - Normal mem load count
    - Normal mem load latency sum
    - Memory request blocked by full MSHR cycle count
    - Downgrade response count
    - Downgrade response with data count
    - Downgrade request count
    - Upgrade response count
    - Upgrade response with data count
    - DMA load request count
    - DMA store request count
  - L1 {Instruction,Data} TLB (events counted for both)
    - Access count
    - Miss and fill from Parent TLB count (Request generated to parent)
    - Miss and fill from Parent TLB latency sum
  - L1 Data TLB only
    - Miss but fill from Peer request count (Satisfied by another request)
    - Miss but fill from Peer request latency sum
    - Hit Under Miss Count
    - All miss cycle count (TLB blocked by miss request entries full)
  - L2 TLB
    - {Instruction,Data} miss count
    - {Instruction,Data} miss latency sum
    - {Instruction,Data} page walks count
    - {Instruction,Data} saved page walks count (by translation caching)
    - {Instruction,Data} huge page hit count
    - {Instruction,Data} huge page miss count
    - Hit under miss count
    - All miss cycle count (TLB blocked by PT walk entries full)
    - Miss but walk done by Peer request (Saved page walk)
- Core
  - Decode (Fetch) Stage
    - Redirect PC on {branch,jump,jump reg,any other} count (eg. due to misprediction)
  - Rename Stage
    - Superscalar correct path rename count (#renames >1)
    - Cycles of none speculate (# of cycles speculation is off)
    - Cycles of non-mem speculate (# of cycles speculation is off for mem instr only)
  - ALU & Branch Execute
    - Redirect {branch,jump reg,any other} count (from wrong speculative execution)
  - FPU (+ Mul & Div) Execute
    - Int mul count
    - Int div count
    - FP any of [FAdd, FSub, FMul, FMAdd, FMSub, FNMSub, FNMAdd] count (not counted individually)
    - FP div count
    - FP sqrt count
  - Memory Execute
    - Stall load by Load Queue count
    - Stall load by Store Queue count
    - Stall load by Store Buffer count
    - Load forward count
    - Load memory latency sum
    - Store memory latency sum
    - Load to use count
    - Load to use latency sum
    - TLB exception count
    - SC success count
    - Any of [LR, SC, AMO] acquire count
    - Any of [LR, SC, AMO] release count
    - Fence acquire count
    - Fence release count
    - Fence count
  - Commit
    - Instruction count (User or System instr)
    - User instruction count
    - Superscalar user instruction (#inst committed >1)
    - {Br,Jmp,Jr,Ld,St,Lr,Sc,Amo} Count (counted individually)
    - Load kill by {Ld,St,Cache}
    - System instruction count
    - Exception count
    - Interrupt count
    - Flush TLB count
    - Flush for Security count
    - Flush Branch Predictor count
    - Flush Cache count
  - Whole Core
    - Cycle count
    - Load Queue full cycle count
    - Store Queue full cycle count
    - Reorder Buffer full cycle count
    - ALU Reservation Station {0,1} full cycle count
    - FPU (+ Mul & Div) Reservation Station full cycle count
    - Memory Execute Reservation Station full cycle count
    - Epoch full cycle count
    - Spec Tag full cycle count
