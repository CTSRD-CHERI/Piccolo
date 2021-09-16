// Copyright (c) 2016-2020 Bluespec, Inc. All Rights Reserved.
//-
// AXI (user fields) + CHERI modifications:
//     Copyright (c) 2019 Alexandre Joannou
//     Copyright (c) 2019 Peter Rugg
//     Copyright (c) 2019 Jonathan Woodruff
//     All rights reserved.
//
//     This software was developed by SRI International and the University of
//     Cambridge Computer Laboratory (Department of Computer Science and
//     Technology) under DARPA contract HR0011-18-C-0016 ("ECATS"), as part of the
//     DARPA SSITH research programme.
//-

package MMU_Cache;

// ================================================================
// A combined MMU and L1 Cache for RISC-V.
// The MMU is capable of handling pages, superpages and gigapages.
// The cache is simple, in-order, blocking, and has a "write-around" policy:
//    All writes (hits and misses) write back to fabric.
//    On write-hit, also update line in cache.
//    On write-miss: don't refill line.
// Thus, cache lines are always clean, never written back.

// Handles LD, ST, AMO_LR, AMO_SC, and remaining AMO_ops.
// Does VA-to-PA addr translation, but bypasses caches, for IO addresses.

// This MMU_Cache is parameterized for data-width on both the front
// side interface (facing CPU) and the back side interface (facing
// fabric).

// CPU-facing interface: can be used for both RV32 and RV64 CPUs.
// RV32 vs. RV64 only affects width of some CPU-side interface
// ports:
//    - inputs req 'addr' and 'satp'    (type WordXL)
//    - output response 'addr' (copy of requesting addr)    (type WordXL)
//    - output response load-value and input request store-value are
//        always 64b because of double-precision floating point LD/ST
//        in RV32
// For RV32, a cache line is 8 x 32b words.
// For RV64, a cache line is 8 x 64b words.

// Fabric-facing interface: AXI4, with data width 32b or 64b (type Wd_Data).

// Internally, the data RAM width is fixed at 64b.

// After MMU translation, there is a 2-way triage based on physical addr:
//  - Memory addrs: request goes to the cache logic
//                      (back end of cache logic talks to fabric interface)
//  - IO:           request does directly to fabric interface (no cacheing)

// ================================================================
// BSV lib imports

import Vector       :: *;
import BRAMCore     :: *;
import ConfigReg    :: *;
import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;

// ----------------
// BSV additional libs

import Cur_Cycle     :: *;
import GetPut_Aux    :: *;
import Semi_FIFOF    :: *;
import CreditCounter :: *;
import AXI4          :: *;
import SourceSink    :: *;

`ifdef PERFORMANCE_MONITORING
import SpecialRegs :: *;
import StatCounters :: *;
`endif

// ================================================================
// Project imports

import ISA_Decls    :: *;
import Near_Mem_IFC :: *;

`ifdef ISA_PRIV_S
import TLB          :: *;
`endif

`ifdef RV32
import Cache_Decls_RV32 :: *;
`elsif RV64
import Cache_Decls_RV64 :: *;
`endif

import SoC_Map      :: *;
import Fabric_Defs  :: *;

`ifdef ISA_CHERI
import ISA_Decls :: *;
`endif

`ifdef RVFI_DII
import RVFI_DII :: *;
`endif

// ================================================================

export  MMU_Cache_IFC (..);
export  MMU_ICache_IFC (..),  mkMMU_ICache;
export  MMU_DCache_IFC (..),  mkMMU_DCache;

// ================================================================
// MMU_Cache interface

interface MMU_Cache_IFC#(numeric type mID);
   method Action set_verbosity (Bit #(4) verbosity);

   // Reset request/response
   interface Server #(Token, Token) server_reset;

   // CPU interface: request
   (* always_ready *)
   method Action  req (CacheOp op,
		       Bit #(3) width_code,
               Bool is_unsigned,
`ifdef ISA_A
		       Bit #(5) amo_funct5,
`endif
		       WordXL addr,
		       Tuple2#(Bool, Bit #(128)) st_value,
		       // The following  args for VM
		       Priv_Mode  priv,
		       Bit #(1)   sstatus_SUM,
		       Bit #(1)   mstatus_MXR,
		       WordXL     satp);    // { VM_Mode, ASID, PPN_for_page_table }

`ifdef ISA_CHERI
   // CPU interface: commit previous request
   (* always_ready *)
   method Action commit;
`endif

   // CPU interface: response
   (* always_ready *)  method Bool       valid;
   (* always_ready *)  method WordXL     addr;        // req addr for which this is a response
   (* always_ready *)  method Tuple2#(Bool, Bit #(128)) word128;     // rd_val data for LD, LR, AMO, SC success/fail result)
   (* always_ready *)  method Tuple2#(Bool, Bit #(128)) st_amo_val;  // Final stored value for ST, SC, AMO
   (* always_ready *)  method Bool       exc;
   (* always_ready *)  method Exc_Code   exc_code;

   // Cache flush request/response
   interface Server #(Token, Token) server_flush;

   // TLB flush
   method Action tlb_flush;

   // Fabric master interface
   interface AXI4_Master #( mID, Wd_Addr, Wd_Data
                          , Wd_AW_User, Wd_W_User, Wd_B_User
                          , Wd_AR_User, Wd_R_User) mem_master;
   
`ifdef PERFORMANCE_MONITORING
   method EventsCache events;
`endif
endinterface


interface MMU_DCache_IFC;
   method Action set_verbosity (Bit #(4) verbosity);

   // Reset request/response
   interface Server #(Token, Token) server_reset;

   // CPU interface: request
   (* always_ready *)
   method Action  req (CacheOp op,
                       Bit #(3) width_code,
               Bool is_unsigned,
`ifdef ISA_A
                       Bit #(5) amo_funct5,
`endif
                       Addr addr,
               Tuple2#(Bool, Bit#(128)) st_value,
                       // The following  args for VM
                       Priv_Mode  priv,
                       Bit #(1)   sstatus_SUM,
                       Bit #(1)   mstatus_MXR,
                       WordXL     satp);    // { VM_Mode, ASID, PPN_for_page_table }

`ifdef ISA_CHERI
   // CPU interface: commit previous request
   (* always_ready *)
   method Action commit;
`endif

   // CPU interface: response
   (* always_ready *)  method Bool       valid;
   (* always_ready *)  method WordXL     addr;        // req addr for which this is a response
   (* always_ready *)  method Tuple2 #(Bool, CWord) cword; // rd_val data for LD, LR, AMO, SC success/fail result)
   (* always_ready *)  method Tuple2 #(Bool, CWord) st_amo_val; // Final stored value for ST, SC, AMO
   (* always_ready *)  method Bool       exc;
   (* always_ready *)  method Exc_Code   exc_code;

   // Cache flush request/response
   interface Server #(Token, Token) server_flush;

   // TLB flush
   method Action tlb_flush;

   // Fabric master interface
   interface AXI4_Master #( Wd_MId_2x3, Wd_Addr, Wd_Data
                          , Wd_AW_User, Wd_W_User, Wd_B_User
                          , Wd_AR_User, Wd_R_User) mem_master;

`ifdef PERFORMANCE_MONITORING
   method EventsL1D events;
`endif

   // ----------------------------------------------------------------
   // Misc. control and status

   // ----------------
   // For ISA tests: watch memory writes to <tohost> addr

`ifdef WATCH_TOHOST
   method Action set_watch_tohost (Bool watch_tohost, Bit #(64) tohost_addr);
   method Bit #(64) mv_tohost_value;
`endif

   // Inform core that DDR4 has been initialized and is ready to accept requests
   method Action ma_ddr4_ready;

   // Misc. status; 0 = running, no error
   (* always_ready *)
   method Bit #(8) mv_status;

endinterface

interface MMU_ICache_IFC;
   method Action set_verbosity (Bit #(4) verbosity);

   // Reset request/response
   interface Server #(Token, Token) server_reset;

   // CPU interface: request
   (* always_ready *)
   method Action  req (CacheOp op,
                       Bit #(3) width_code,
               Bool is_unsigned,
`ifdef ISA_A
                       Bit #(5) amo_funct5,
`endif
                       Addr addr,
               Tuple2#(Bool, Bit#(128)) st_value,
                       // The following  args for VM
                       Priv_Mode  priv,
                       Bit #(1)   sstatus_SUM,
                       Bit #(1)   mstatus_MXR,
                       WordXL     satp);    // { VM_Mode, ASID, PPN_for_page_table }

`ifdef ISA_CHERI
   // CPU interface: commit previous request
   (* always_ready *)
   method Action commit;
`endif

   // CPU interface: response
   (* always_ready *)  method Bool       valid;
   (* always_ready *)  method WordXL     addr;        // req addr for which this is a response
   (* always_ready *)  method Tuple2 #(Bool, CWord) cword; // rd_val data for LD, LR, AMO, SC success/fail result)
   (* always_ready *)  method Tuple2 #(Bool, CWord) st_amo_val; // Final stored value for ST, SC, AMO
   (* always_ready *)  method Bool       exc;
   (* always_ready *)  method Exc_Code   exc_code;

   // Cache flush request/response
   interface Server #(Token, Token) server_flush;

   // TLB flush
   method Action tlb_flush;

   // Fabric master interface
   interface AXI4_Master #( Wd_MId, Wd_Addr, Wd_Data
                          , Wd_AW_User, Wd_W_User, Wd_B_User
                          , Wd_AR_User, Wd_R_User) mem_master;

`ifdef PERFORMANCE_MONITORING
   method EventsL1I events;
`endif

   // ----------------------------------------------------------------
   // Misc. control and status

   // ----------------
   // For ISA tests: watch memory writes to <tohost> addr

`ifdef WATCH_TOHOST
   method Action set_watch_tohost (Bool watch_tohost, Bit #(64) tohost_addr);
   method Bit #(64) mv_tohost_value;
`endif

   // Inform core that DDR4 has been initialized and is ready to accept requests
   method Action ma_ddr4_ready;

   // Misc. status; 0 = running, no error
   (* always_ready *)
   method Bit #(8) mv_status;

endinterface



//typedef MMU_Cache_IFC#(Wd_MId_2x3) MMU_DCache_IFC;
//typedef MMU_Cache_IFC#(Wd_MId) MMU_ICache_IFC;

// ****************************************************************
// ****************************************************************
// ****************************************************************
// Internal types and constants

typedef enum { CTAG_EMPTY, CTAG_CLEAN } CTagState
deriving (Bits, Eq, FShow);

typedef struct {
   CTagState  state;
   CTag       ctag;
   } State_and_CTag
deriving (Bits, FShow);

typedef Vector #(Ways_per_CSet, State_and_CTag)  State_and_CTag_CSet;
typedef Vector #(Ways_per_CSet, Cache_Entry) Word128_Set;

typedef enum {MODULE_PRERESET,              // After power on reset, before soft reset
              MODULE_RESETTING,             // Clearing all tags to EMPTY state
              MODULE_READY,                 // Reset done, ready for first request
              MODULE_RUNNING,               // Normal operation, during hits
              MODULE_EXCEPTION_RSP,         // On misaligned and access exceptions

              PTW_START,                    // On TLB miss, initiate refill of PTE into TLB
`ifdef RV64
	      PTW_LEVEL_2,                  // Page Table Walk, Request Level 2
`endif
	      PTW_LEVEL_1,                  // Page Table Walk, Request Level 1
	      PTW_LEVEL_0,                  // Page Table Walk, Request Level 0

              CACHE_START_REFILL,           // On cache miss, initiate refill of cache line in cache
              CACHE_REFILL,                 // Refill
              CACHE_REREQ,                  // After refill, redo request that missed
              CACHE_ST_AMO_RSP,             // Provide ST/SC/AMO response

              IO_REQ,                       // For memory-mapped I/O requests
              IO_AWAITING_READ_RSP,         // No caching
              IO_READ_RSP,                  // Provide IO-read response

	      IO_AWAITING_AMO_READ_RSP
   } Module_State
deriving (Bits, Eq, FShow);

Bool bram_cmd_read  = False;
Bool bram_cmd_write = True;

// The reset-loop is run based on requests for reset and requests for flush
typedef enum {REQUESTOR_RESET_IFC, REQUESTOR_FLUSH_IFC} Requestor
deriving (Bits, Eq, FShow);

`ifndef ISA_PRIV_S

// VM Xlate related definitions which are only for the case where there is no
// VM, effectively making the following definitions, dummy ones. If VM, these
// definitions are taken from the TLB package, and include fields like the PTE

typedef enum { VM_XLATE_OK, VM_XLATE_TLB_MISS, VM_XLATE_EXCEPTION } VM_Xlate_Outcome
deriving (Bits, Eq, FShow);

typedef struct {
   VM_Xlate_Outcome   outcome;
   Bool               allow_cap;     // whether we will be allowed to load a cap
   PA                 pa;            // phys addr, if VM_XLATE_OK
   Exc_Code           exc_code;      // if VM_XLATE_EXC
   } VM_Xlate_Result
deriving (Bits, FShow);

`endif

// ================================================================
// Check if addr is aligned

function Bool fn_is_aligned (Bit #(3) width_code, Bit #(n) addr);
   return (    (width_code == w_SIZE_B)                                // B, BU
	   || ((width_code == w_SIZE_H) && (addr [0] == 1'b0))         // H, HU
	   || ((width_code == w_SIZE_W) && (addr [1:0] == 2'b00))      // W, WU
	   || ((width_code == w_SIZE_D) && (addr [2:0] == 3'b000))     // D
	   || ((width_code == w_SIZE_Q) && (addr [3:0] == 4'b0000))    // Q
	   );
endfunction

// ================================================================
// Convert RISC-V funct3 code into AXI4_Size code (number of bytes in a beat)

function AXI4_Size fn_width_code_to_AXI4_Size (Bit #(3) width_code);
   AXI4_Size  result;
   if      (width_code == w_SIZE_B)        result = 1;
   else if (width_code == w_SIZE_H)        result = 2;
   else if (width_code == w_SIZE_W)        result = 4;
   else if (width_code == w_SIZE_D)        result = 8;
   else /* if (width_code == w_SIZE_Q) */  result = 16;
   return result;
endfunction

// ================================================================
// Compute address, data and strobe (byte-enables) for writes to fabric

function
`ifdef ISA_CHERI
         Tuple5
`else
         Tuple4
`endif
                #(Fabric_Addr,    // addr is 32b- or 64b-aligned
		  Fabric_Data,    // data is lane-aligned
`ifdef ISA_CHERI
          Bit #(Wd_W_User),           // cap_tags
`endif
		  Fabric_Strb,    // strobe
		  AXI4_Size)      // 8 for 8-byte writes, else 4

   fn_to_fabric_write_fields (Bit #(3)  width_code,      // RISC-V size code: B/H/W/D/Q
			      Bit #(n)  addr,    // actual byte addr
            Tuple2#(Bool, Bit#(128)) write)  // data is in lsbs
   provisos (Add #(_, n, 64));

   match {.write_cap, .word128} = write;

   Bit #(64) word64 = truncate(word128);

   // First compute addr, data and strobe for a 64b-wide fabric
   Bit #(8)  strobe128    = 0;
   Bit #(3)   shift_bytes = addr [2:0];
   Bit #(6)   shift_bits  = { shift_bytes, 3'b0 };
   Bit #(64)  addr64     = zeroExtend (addr);
   AXI4_Size  axsize      = 128;    // Will be updated in 'case' below

   case (width_code)
      w_SIZE_B: begin
		    word64   = (word64 << shift_bits);
		    strobe128 = ('b_1   << shift_bytes);
		    axsize    = 1;
		 end
      w_SIZE_H: begin
		    word64   = (word64 << shift_bits);
		    strobe128 = ('b_11  << shift_bytes);
		    axsize    = 2;
		 end
      w_SIZE_W: begin
		    word64   = (word64  << shift_bits);
		    strobe128 = ('b_1111 << shift_bytes);
		    axsize    = 4;
		 end
      w_SIZE_D: begin
        word64   = (word64 << shift_bits);
	      strobe128 = ('b_1111_1111 << shift_bytes);
		    axsize    = 8;
		 end
/*      w_SIZE_Q: begin
            word128   = word128;
            strobe128 = 'b_1111_1111_1111_1111;
            axsize    = 16;
         end*/
   endcase

   let user = 0;

`ifdef ISA_CHERI
   //The tag controller must ignore user bits for entirely "strobed out" capabilities
   if (width_code == w_SIZE_CAP) user = signExtend(pack(write_cap));
`endif

   // Finally, create fabric addr/data/strobe
   Fabric_Addr  fabric_addr   = truncate (addr64);
   Fabric_Data  fabric_data   = truncate (word64);
   Fabric_Strb  fabric_strobe = truncate (strobe128);

   return
`ifdef ISA_CHERI
          tuple5
`else
          tuple4
`endif           (fabric_addr, fabric_data,
`ifdef ISA_CHERI
                                            user,
`endif
                                            fabric_strobe, axsize);
endfunction: fn_to_fabric_write_fields

// ================================================================
// Update a byte, halfword, word, doubleword or quadword in a Word128 at Way in a Word128_Set

function Word128_Set fn_update_word128_set (Word128_Set   old_word128_set,
					  Way_in_CSet  way,
					  Bit #(n)     addr,
					  Bit #(3)     width_code,
					  Tuple2 #(Bool, Bit#(Cache_Data_Width)) write);

   match {.tag, .word128} = write;

   let old_word128    = old_word128_set [way];

   let new_word128_set = old_word128_set;
   Bit#(Cache_Data_Width) new_word128     = tpl_2(old_word128);

   Bit #(4) addr_lsbs  = addr [3:0];

   // Replace relevant bytes in new_word128
   case (width_code)
      0:  case (addr_lsbs)
            'h0 : new_word128 [ 7:0 ] = word128 [7:0];
            'h1 : new_word128 [15:8 ] = word128 [7:0];
            'h2 : new_word128 [23:16] = word128 [7:0];
            'h3 : new_word128 [31:24] = word128 [7:0];
            'h4 : new_word128 [39:32] = word128 [7:0];
            'h5 : new_word128 [47:40] = word128 [7:0];
            'h6 : new_word128 [55:48] = word128 [7:0];
            'h7 : new_word128 [63:56] = word128 [7:0];
            'h8 : new_word128 [71:64] = word128 [7:0];
            'h9 : new_word128 [79:72] = word128 [7:0];
            'ha : new_word128 [87:80] = word128 [7:0];
            'hb : new_word128 [95:88] = word128 [7:0];
            'hc : new_word128 [103:96] = word128 [7:0];
            'hd : new_word128 [111:104] = word128 [7:0];
            'he : new_word128 [119:112] = word128 [7:0];
            'hf : new_word128 [127:120] = word128 [7:0];
        endcase
      1:  case (addr_lsbs)
            'h0 : new_word128 [15:0 ] = word128 [15:0];
            'h2 : new_word128 [31:16] = word128 [15:0];
            'h4 : new_word128 [47:32] = word128 [15:0];
            'h6 : new_word128 [63:48] = word128 [15:0];
            'h8 : new_word128 [79:64] = word128 [15:0];
            'ha : new_word128 [95:80] = word128 [15:0];
            'hc : new_word128 [111:96] = word128 [15:0];
            'he : new_word128 [127:112] = word128 [15:0];
        endcase
      2:  case (addr_lsbs)
            'h0 : new_word128 [31:0] = word128 [31:0];
            'h4 : new_word128 [63:32] = word128 [31:0];
            'h8 : new_word128 [95:64] = word128 [31:0];
            'hc : new_word128 [127:96] = word128 [31:0];
        endcase
      3:  case (addr_lsbs)
            'h0 : new_word128[63:0] = word128[63:0];
            'h8 : new_word128[127:64] = word128[63:0];
        endcase
      4:  begin
            new_word128[127:0] = word128;
          end
   endcase

`ifdef ISA_CHERI
   Bit#(Cache_Cap_Tag_Width) tags = tpl_1(old_word128);

   //We assume that caps are the widest write width on the processor
   let overwritten_idx = addr_lsbs >> valueOf(TLog#(TDiv#(CLEN,8)));
   tags[overwritten_idx] = width_code == w_SIZE_CAP ? pack(tag) : 0;
`else
   let tags = 0;
`endif

   new_word128_set [way] = tuple2(tags, new_word128);
   return new_word128_set;
endfunction: fn_update_word128_set


// ================================================================
// Displays, for debugging

function Action fa_display_state_and_ctag_cset (CSet_in_Cache        cset_in_cache,
						State_and_CTag_CSet  state_and_ctag_cset);
   action
      $write ("        CSet 0x%0x: (state, tag):", cset_in_cache);
      for (Integer j = 0; j < ways_per_cset; j = j + 1) begin
	 $write (" (", fshow (state_and_ctag_cset [j].state));
	 if (state_and_ctag_cset [j].state == CTAG_EMPTY)
	    $write (", --");
	 else
	    $write (", 0x%0x", state_and_ctag_cset [j].ctag);
	 $write (")");
      end
      $write ("\n");
   endaction
endfunction

function Action fa_display_word128_set (CSet_in_Cache    cset_in_cache,
				       Word128_in_CLine  word128_in_cline,
				       Word128_Set       word128_set);
   action
      $write ("        CSet 0x%0x, Word128 0x%0x: ", cset_in_cache, word128_in_cline);
      for (Integer j = 0; j < ways_per_cset; j = j + 1) begin
	 $write (" 0x%0x", word128_set [j]);
      end
      $write ("\n");
   endaction
endfunction

function Reg #(t) fn_genNullRegIfc (t x) provisos (Literal#(t));
   return (
      interface Reg;
         method _read = x;
         method _write (y) = noAction;
      endinterface
   );
endfunction

// ****************************************************************
// ****************************************************************
// ****************************************************************
// The module implementation

(* synthesize *)
module mkMMU_DCache(MMU_DCache_IFC);
  MMU_Cache_IFC#(Wd_MId_2x3) cache <- mkMMU_Cache(False, fabric_2x3_default_mid);
  EventsL1D evts = EventsL1D { evt_LD           : zeroExtend(pack(cache.events.evt_LD))
                             , evt_LD_MISS      : zeroExtend(pack(cache.events.evt_LD_MISS))
                             , evt_LD_MISS_LAT  : zeroExtend(pack(cache.events.evt_LD_MISS_LAT))
                             , evt_ST           : zeroExtend(pack(cache.events.evt_ST))
                             , evt_ST_MISS      : zeroExtend(pack(cache.events.evt_ST_MISS))
                             , evt_ST_MISS_LAT  : zeroExtend(pack(cache.events.evt_ST_MISS_LAT))
                             , evt_AMO          : zeroExtend(pack(cache.events.evt_AMO))
                             , evt_AMO_MISS     : zeroExtend(pack(cache.events.evt_AMO_MISS))
                             , evt_AMO_MISS_LAT : zeroExtend(pack(cache.events.evt_AMO_MISS_LAT))
                             , evt_TLB          : zeroExtend(pack(cache.events.evt_TLB))
                             , evt_TLB_MISS     : zeroExtend(pack(cache.events.evt_TLB_MISS))
                             , evt_TLB_MISS_LAT : zeroExtend(pack(cache.events.evt_TLB_MISS_LAT))
                             , evt_TLB_FLUSH    : zeroExtend(pack(cache.events.evt_TLB_FLUSH))
                             , evt_EVICT        : zeroExtend(pack(cache.events.evt_EVICT))
                             };
  method set_verbosity = cache.set_verbosity;
  interface server_reset = cache.server_reset;
  method req = cache.req;
`ifdef ISA_CHERI
  method commit = cache.commit;
`endif
  method valid = cache.valid;
  method addr = cache.addr;
  method cword = cache.cword;
  method st_amo_val = cache.st_amo_val;
  method exc = cache.exc;
  method exc_code = cache.exc_code;
  interface server_flush = cache.server_flush;
  method tlb_flush = cache.tlb_flush;
  interface mem_master = cache.mem_master;
`ifdef WATCH_HOST
  method set_watch_tohost = cache.set_watch_tohost;
  method mv_tohost_value = cache.mv_tohost_value;
`endif
  method ma_ddr4_ready = cache.ma_ddr4_ready;
  method mv_status = cache.mv_status;
  method events = evts;
endmodule
(* synthesize *)
module mkMMU_ICache(MMU_ICache_IFC);
  MMU_Cache_IFC#(Wd_MId) cache <- mkMMU_Cache(True, fabric_default_mid);
  EventsL1I evts = EventsL1I { evt_LD           : zeroExtend(pack(cache.events.evt_LD))
                             , evt_LD_MISS      : zeroExtend(pack(cache.events.evt_LD_MISS))
                             , evt_LD_MISS_LAT  : zeroExtend(pack(cache.events.evt_LD_MISS_LAT))
                             , evt_TLB          : zeroExtend(pack(cache.events.evt_TLB))
                             , evt_TLB_MISS     : zeroExtend(pack(cache.events.evt_TLB_MISS))
                             , evt_TLB_MISS_LAT : zeroExtend(pack(cache.events.evt_TLB_MISS_LAT))
                             , evt_TLB_FLUSH    : zeroExtend(pack(cache.events.evt_TLB_FLUSH))
                             };
  method set_verbosity = cache.set_verbosity;
  interface server_reset = cache.server_reset;
  method req = cache.req;
`ifdef ISA_CHERI
  method commit = cache.commit;
`endif
  method valid = cache.valid;
  method addr = cache.addr;
  method cword = cache.cword;
  method st_amo_val = cache.st_amo_val;
  method exc = cache.exc;
  method exc_code = cache.exc_code;
  interface server_flush = cache.server_flush;
  method tlb_flush = cache.tlb_flush;
  interface mem_master = cache.mem_master;
`ifdef WATCH_HOST
  method set_watch_tohost = cache.set_watch_tohost;
  method mv_tohost_value = cache.mv_tohost_value;
`endif
  method ma_ddr4_ready = cache.ma_ddr4_ready;
  method mv_status = cache.mv_status;
  method events = evts;
endmodule
//(* synthesize *)
//module mkMMU_DCache(MMU_DCache_IFC);
//  let cache <- mkMMU_Cache(True, fabric_2x3_default_mid);
//  return cache;
//endmodule
module mkMMU_Cache  #(parameter Bool dmem_not_imem,
                      parameter Bit#(mID) default_mid)  (MMU_Cache_IFC#(mID));

   String d_or_i = (dmem_not_imem ? "D_MMU_Cache" : "I_MMU_Cache");

   // Verbosity: 0: quiet; 1 reset info; 2: + detail; 3: cache refill loop detail
   Integer verbosity = (dmem_not_imem ? 0 : 0);
   Reg #(Bit #(4)) cfg_verbosity <- mkConfigReg (fromInteger (verbosity));

   // Overall state of this module
   Reg #(Module_State)  rg_state  <- mkReg (MODULE_PRERESET);

   // SoC_Map is needed for method 'm_is_mem_addr' to distinguish mem
   // (cached) and other (non-cached) addrs
   SoC_Map_IFC soc_map <- mkSoC_Map;

`ifdef ISA_CHERI
   Wire#(Bool) dw_commit <- mkDWire(!dmem_not_imem); // Icache always commits, since no writes. Instruction must be canceled in pipe
`endif

   // Reset request/response: REQUESTOR_RESET_IFC, REQUESTOR_FLUSH_IFC
   FIFOF #(Requestor) f_reset_reqs <- mkFIFOF;
   Bool resetting = f_reset_reqs.notEmpty;
   FIFOF #(Requestor) f_reset_rsps <- mkFIFOF;

   RWire #(Requestor) rw_reset_req <- mkRWire;
   PulseWire pw_tlb_flush_req <- mkPulseWire;

   // Fabric request/response
   let masterPortShim <- mkAXI4ShimFF;

`ifdef ISA_PRIV_S
   // The TLB
   TLB_IFC  tlb <- mkTLB (dmem_not_imem);
`endif

   // For discarding write-responses
   CreditCounter_IFC #(4) ctr_wr_rsps_pending <- mkCreditCounter; // Max 15 writes outstanding

   // Cache RAMs
   // BRAM Port A is only used for writing
   // BRAM Port B is only used for reading
   Bool config_output_register = False;    // i.e., no output register
   // Tag RAM
   BRAM_DUAL_PORT #(CSet_in_Cache,
		    State_and_CTag_CSet)  ram_state_and_ctag_cset <- mkBRAMCore2 (csets_per_cache,
										  config_output_register);

   // Data RAM
   BRAM_DUAL_PORT #(Word128_Set_in_Cache, Word128_Set) ram_word128_set <- mkBRAMCore2 (word128_sets_per_cache,
										    config_output_register);

   // Registers holding incoming request args
   Reg #(CacheOp)    rg_op          <- mkRegU;    // CACHE_LD, CACHE_ST, CACHE_AMO
   Reg #(Bit #(3))   rg_width_code  <- mkRegU;    // specifies B/H/W/D/Q access size
   Reg #(Bool)       rg_is_unsigned    <- mkRegU;    // whether to sign extend returned val
`ifdef ISA_A
   Reg #(Bit #(5))   rg_amo_funct5  <- mkRegU;    // specifies which kind of AMO op
`endif
   Reg #(WordXL)     rg_addr        <- mkRegU;    // VA or PA
   Reg #(Tuple2#(Bool, Bit #(128))) rg_st_amo_val  <- mkRegU;    // Store-value for ST, SC, AMO
   Reg #(Bool)       rg_allow_cap <- mkRegU;      // Whether load result is allowed to be tagged by VM page bits

   // The following are needed for VM
`ifdef ISA_PRIV_S
   Reg #(Priv_Mode)  rg_priv        <- mkRegU;    // Privilege level for this request
   Reg #(Bit #(1))   rg_sstatus_SUM <- mkRegU;    // SUM bit in SSTATUS CSR
   Reg #(Bit #(1))   rg_mstatus_MXR <- mkRegU;    // MXR bit in MSTATUS CSR

   Reg #(WordXL)     rg_satp        <- mkRegU;    // Copy of value in SATP CSR { VM_Mode, ASID, PPN }
`else
   // Dummy registers in non-VM mode
   Priv_Mode x = m_Priv_Mode;
   Reg #(Priv_Mode)  rg_priv        = fn_genNullRegIfc (x);

   Bit #(1) y = ?;
   Reg #(Bit #(1))   rg_sstatus_SUM = fn_genNullRegIfc (y);
   Reg #(Bit #(1))   rg_mstatus_MXR = fn_genNullRegIfc (y);

   WordXL z = ?;
   Reg #(WordXL)     rg_satp        = fn_genNullRegIfc (z);
`endif

   // Phys addr (initially taken from rg_addr; VM xlation may replace it)
   Reg #(PA)  rg_pa <- mkRegU;

`ifdef ISA_PRIV_S
   // Derivations from rg_addr (virtual addr)
   VA      va     = fn_WordXL_to_VA (rg_addr);
   VPN     vpn    = fn_Addr_to_VPN (va);
`ifdef RV64
   VPN_J   vpn_2  = fn_Addr_to_VPN_2 (va);
`endif
   VPN_J   vpn_1  = fn_Addr_to_VPN_1 (va);
   VPN_J   vpn_0  = fn_Addr_to_VPN_0 (va);
   Offset  offset = fn_Addr_to_Offset (rg_addr);
`endif

   CSet_in_Cache        cset_in_cache        = fn_Addr_to_CSet_in_Cache   (rg_addr);
   Word128_Set_in_Cache word128_set_in_cache = fn_Addr_to_Word128_Set_in_Cache (rg_addr);
   Word128_in_CLine     word128_in_cline     = fn_Addr_to_Word128_in_CLine (rg_addr);
   Bit #(4)             byte_in_word128       = fn_Addr_to_Byte_in_Word128  (rg_addr);

`ifdef ISA_PRIV_S
   // Derivations from rg_satp
   VM_Mode  vm_mode  = fn_satp_to_VM_Mode (rg_satp);
   ASID     asid     = fn_satp_to_ASID    (rg_satp);
   PPN      satp_ppn = fn_satp_to_PPN     (rg_satp);
   PA       satp_pa  = fn_PPN_and_Offset_to_PA (satp_ppn, 12'b0);

   // We continuously probe the TLB with (asid, vpn)
   TLB_Lookup_Result  tlb_result = tlb.lookup (asid, vpn);
`endif

   // Outputs
   Reg #(Bool)      dw_valid             <- mkDWire (False);
   Reg #(Bool)      dw_exc               <- mkDWire (False);
   Reg #(Exc_Code)  rg_exc_code          <- mkRegU;
   Reg #(Exc_Code)  dw_exc_code          <- mkDWire (?);
   Reg #(Tuple2 #(Bool, Bit #(128))) rg_ld_val            <- mkReg (tuple2 (False, ?));      // Load-value for LOAD/LR/AMO, success/fail for SC
   Reg #(Tuple2 #(Bool, Bit #(128))) dw_output_ld_val     <- mkDWire (tuple2 (False, ?));
   Reg #(Tuple2 #(Bool, Bit #(128))) dw_output_st_amo_val <- mkDWire (tuple2 (False, ?));    // stored value for ST, SC, AMO (for verification only)

   // This reg is used during PTWs
   Reg #(PA) rg_pte_pa <- mkRegU;

`ifdef ISA_A
   // Reservation regs for AMO LR/SC (Load-Reserved/Store-Conditional)
   Reg #(Bool)     rg_lrsc_valid  <- mkReg (False);
   Reg #(PA)       rg_lrsc_pa     <- mkRegU;    // Phys. address for an active LR
`endif

   // This reg is used in the reset-loop when resetting all states
   Reg #(CSet_in_Cache)  rg_cset_in_cache   <- mkReg (0);

   // These regs are used in the cache refill loop for ram_State_and_CTag_CSet
   // and ram_Word128_Set
   Reg #(Word128_Set_in_Cache) rg_word128_set_in_cache <- mkRegU;
   Reg #(Bool)                 rg_error_during_refill <- mkRegU;
   // In 64b (or lower) fabrics, these hold the lower word64 while we're fetching the upper word64 of a word128
   Reg #(Bool)      rg_lower_word64_full <- mkReg (False);
   Reg #(Bit #(64)) rg_lower_word64      <- mkRegU;
   Reg #(Bit #(1))      rg_lower_tag      <- mkRegU;

   // When a CSet is full and we need to replace a cache line due to a refill,
   // the victim is picked 'randomly' according to this register
   Reg #(Way_in_CSet)  rg_victim_way <- mkRegU;

`ifdef PERFORMANCE_MONITORING
   Array #(Reg #(EventsCache)) aw_events <- mkDRegOR (8, unpack (0));
   Wire #(Bool) wr_mem_req_sent <- mkDWire (False);
   Reg #(Bool)  rg_mem_req_sent <- mkReg (False);
   Reg #(Bool)  rg_cache_rereq_data <- mkReg (False);
   Reg #(Bool)  rg_tlb_walk <- mkReg (False);
`endif

   // ----------------------------------------------------------------
   // This function initiates a read request on the 'B' ports of the rams
   // Invoked from original cache request method, and internally after refills

   function Action fa_req_ram_B (Addr addr);
      action
	 // Request tag RAM
	 let cset_in_cache = fn_Addr_to_CSet_in_Cache (addr);
	 ram_state_and_ctag_cset.b.put (bram_cmd_read, cset_in_cache,    ?);

	 // Request data RAM
	 let word128_set_in_cache = fn_Addr_to_Word128_Set_in_Cache (addr);
	 ram_word128_set.b.put          (bram_cmd_read, word128_set_in_cache, ?);

	 if (cfg_verbosity > 1)
	    $display ("    fa_req_ram_B tagCSet [0x%0x] word128_set [0x%0d]",
		      cset_in_cache, word128_set_in_cache);
      endaction
   endfunction

   // ----------------------------------------------------------------
   // Outputs of RAM read-ports (B ports)

   let state_and_ctag_cset = ram_state_and_ctag_cset.b.read;
   let word128_set          = ram_word128_set.b.read;

   // Test cache hit or miss; if hit, return which 'way', and the word128 data
   // ---- This pure function is an ActionValue only for the $display inside
   function ActionValue #(Tuple3 #(Bool, Way_in_CSet, Cache_Entry)) fn_test_cache_hit_or_miss (CTag  pa_ctag);
      actionvalue
	 Bool         hit     = False;
	 Way_in_CSet  way_hit = 0;
	 Bit#(SizeOf#(Cache_Entry))  word128  = 0;

	 for (Integer way = 0; way < ways_per_cset; way = way + 1) begin
	    let hit_at_way  = (   (state_and_ctag_cset [way].state != CTAG_EMPTY)
			       && (state_and_ctag_cset [way].ctag  == pa_ctag));
	    let word128_at_way = word128_set [way];

	    // Assertion: cannot have > 1 hit in a set
	    if (hit && hit_at_way)
	       $display ("        ASSERTION ERROR: fn_test_cache_hit_or_miss: multiple hits in set at [%0d] and [%0d]",
			 way, way_hit);

	    hit     = hit || hit_at_way;
	    if (hit_at_way) way_hit = fromInteger (way);
	    word128  = (word128 | (pack(word128_at_way) & pack (replicate (hit_at_way))));
	 end

	 return tuple3 (hit, way_hit, unpack(word128));
      endactionvalue
   endfunction

   // Abbreviations testing for LR and SC (avoids ifdef clutter later)
`ifdef ISA_A
   Bool is_AMO    = (rg_op == CACHE_AMO) && dmem_not_imem;
   Bool is_AMO_LR = ((rg_op == CACHE_AMO) && (rg_amo_funct5 == f5_AMO_LR)) && dmem_not_imem;
   Bool is_AMO_SC = ((rg_op == CACHE_AMO) && (rg_amo_funct5 == f5_AMO_SC)) && dmem_not_imem;
`else
   Bool is_AMO    = False;
   Bool is_AMO_LR = False;
   Bool is_AMO_SC = False;
`endif

   Exc_Code access_exc_code     = fn_access_exc_code     (dmem_not_imem, ((rg_op == CACHE_LD) || is_AMO_LR));

`ifdef ISA_PRIV_S
   Exc_Code page_fault_exc_code = fn_page_fault_default_exc_code (dmem_not_imem, ((rg_op == CACHE_LD) || is_AMO_LR));
`endif

   // ----------------------------------------------------------------
   // Functions to drive read-responses (outputs)

   // Memory-read responses
   function Action fa_drive_mem_rsp (Bit #(3) width_code, Bool is_unsigned, Addr addr, Cache_Entry ld_val, Cache_Entry st_amo_val, Bool allow_cap, Bool commit);
      action
	 dw_valid             <= commit;
	 // Value loaded into rd (LOAD, LR, AMO, SC success/fail result)
	 let extracted = fn_extract_and_extend_bytes (width_code, is_unsigned, addr, ld_val);
	 if (! allow_cap) extracted = tuple2 (False, tpl_2 (extracted));
	 dw_output_ld_val     <= extracted;
	 // Value stored into mem (STORE, SC, AMO final value stored)
	 dw_output_st_amo_val <= tuple2 (tpl_1 (st_amo_val) [(valueOf (CLEN) == 64 && addr[4:0] == 0) ? 1 : 0] == 1'b1, tpl_2 (st_amo_val));
	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.drive_mem_rsp: addr 0x%0h ld_val 0x%0h st_amo_val 0x%0h",
		      cur_cycle, d_or_i, addr, ld_val, st_amo_val);
      endaction
   endfunction

   // IO-read responses
   function Action fa_drive_IO_read_rsp (Bit #(3) width_code, Bool is_unsigned, Addr addr, Tuple2#(Bool, Bit #(128)) ld_val, Bool allow_cap);
      action
	 dw_valid         <= True;
	 // Value loaded into rd (LOAD, LR, AMO, SC success/fail result)
	 if (! allow_cap) ld_val = tuple2 (False, tpl_2 (ld_val));
	 dw_output_ld_val <= ld_val;
	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.drive_IO_read_rsp: addr 0x%0h ld_val 0x%0h", cur_cycle, d_or_i, addr, ld_val);
      endaction
   endfunction

   // Send a read-request into the fabric
   function Action fa_fabric_send_read_req (Fabric_Addr  addr, AXI4_Size  size, AXI4_Len len);
      action
	 let mem_req_rd_addr = AXI4_ARFlit {arid:     default_mid,
				            araddr:   addr,
					    arlen:    len,           // burst len = arlen+1
					    arsize:   size,
					    arburst:  INCR,
					    arlock:   fabric_default_lock,
					    arcache:  fabric_default_arcache,
					    arprot:   fabric_default_prot,
					    arqos:    fabric_default_qos,
					    arregion: fabric_default_region,
					    aruser:   fabric_default_aruser};

	 masterPortShim.slave.ar.put(mem_req_rd_addr);

	 // Debugging
	 if (cfg_verbosity > 1) begin
	    $display ("            To fabric: ", fshow (mem_req_rd_addr));
	 end
      endaction
   endfunction

   FIFOF #(Tuple3 #(Bit #(3), PA, Tuple2 #(Bool, Bit#(128)))) f_fabric_write_reqs <- mkFIFOF;

   // Send a write-request into the fabric
   function Action fa_fabric_send_write_req (Bit #(3)  width_code, PA  pa, Tuple2 #(Bool, Bit#(128))  st_val
                                                                                                           );
      action
	 f_fabric_write_reqs.enq (tuple3 (width_code, pa, st_val));
      endaction
   endfunction

   rule rl_fabric_send_write_req (dmem_not_imem);
      match { .f3, .pa, .st_val } <- pop (f_fabric_write_reqs);

      match {.fabric_addr,
	     .fabric_data,
`ifdef ISA_CHERI
       .fabric_user,
`endif
	     .fabric_strb,
	     .fabric_size} = fn_to_fabric_write_fields (f3, pa, st_val);

      let mem_req_wr_addr = AXI4_AWFlit {awid:     default_mid,
					  awaddr:   fabric_addr,
					  awlen:    0,           // burst len = awlen+1
					  awsize:   fabric_size,
					  awburst:  fabric_default_burst,
					  awlock:   fabric_default_lock,
					  awcache:  fabric_default_awcache,
					  awprot:   fabric_default_prot,
					  awqos:    fabric_default_qos,
					  awregion: fabric_default_region,
					  awuser:   fabric_default_awuser};

      let mem_req_wr_data = AXI4_WFlit {wdata:  fabric_data,
					  wstrb:  fabric_strb,
					  wlast:  True,
					  wuser:  fabric_user};

      masterPortShim.slave.aw.put (mem_req_wr_addr);
      masterPortShim.slave.w.put (mem_req_wr_data);

      // Expect a fabric response
      ctr_wr_rsps_pending.incr;

      // Debugging
      if (cfg_verbosity > 1) begin
	 $display ("            To fabric: ", fshow (mem_req_wr_addr));
	 $display ("                       ", fshow (mem_req_wr_data));
      end
   endrule

   // ================================================================
   // When PTE.A or PTE.D is updated, this function records it in the TLB
   // and enqueues a writeback to memory.

`ifdef ISA_PRIV_S
   FIFOF #(Tuple2 #(PA, PTE)) f_pte_writebacks <- mkFIFOF;

   function Action fa_record_pte_A_D_updates (TLB_Lookup_Result  tlb_result1,  VM_Xlate_Result  vm_xlate_result);
      action
	 if (vm_xlate_result.pte_modified) begin
	    // Update the TLB
	    tlb.insert (asid, vpn, vm_xlate_result.pte, tlb_result1.pte_level, tlb_result1.pte_pa);
	    // Enqueue it to be written back to memory
	    f_pte_writebacks.enq (tuple2 (tlb_result1.pte_pa, vm_xlate_result.pte));
	    if (cfg_verbosity >= 2) begin
	       $display ("    fa_record_pte_A_D_updates:");
	       $display ("      ", fshow (tlb_result1));
	       $display ("      ", fshow (vm_xlate_result));
	    end
	 end
      endaction
   endfunction

   rule rl_writeback_updated_PTE;
      match { .pa, .pte } <- pop (f_pte_writebacks);
      let width_code = ((xlen == 32) ? 3'b010 : 3'b011);
      fa_fabric_send_write_req (width_code, pa, tuple2(False, zeroExtend (pte)));
   endrule
`endif

   // ================================================================
   // BEHAVIOR

   // ----------------------------------------------------------------
   // Reset

   rule rl_start_reset (resetting && (rg_state != MODULE_RESETTING));
      rg_state             <= MODULE_RESETTING;
      rg_cset_in_cache     <= 0;
      rg_lower_word64_full <= False;

      // Flush the TLB
`ifdef ISA_PRIV_S
      tlb.flush;
`ifdef PERFORMANCE_MONITORING
      EventsCache events = unpack (0);
      events.evt_TLB_FLUSH = True;
      aw_events [0] <= events;
`endif
`endif

`ifdef ISA_A
      rg_lrsc_valid  <= False;
`endif

      if (f_reset_reqs.first == REQUESTOR_RESET_IFC) begin
	 ctr_wr_rsps_pending.clear;
      end

      $display ("%0d: %s: cache size %0d KB, associativity %0d, line size %0d bytes (= %0d XLEN words)",
		cur_cycle, d_or_i, kb_per_cache, ways_per_cset,
		(word128s_per_cline * 16),
`ifdef RV32
		(word128s_per_cline * 4)
`else
		(word128s_per_cline * 2)
`endif
		);
   endrule

   // This rule loops over csets, setting state of each cline in the set to EMPTY
   rule rl_reset (rg_state == MODULE_RESETTING);
      let state_and_ctag = State_and_CTag { state: CTAG_EMPTY, ctag: ? };
      ram_state_and_ctag_cset.a.put (bram_cmd_write, rg_cset_in_cache, replicate (state_and_ctag));

      if (f_reset_reqs.first == REQUESTOR_RESET_IFC) masterPortShim.clear;

      if (rg_cset_in_cache == fromInteger (csets_per_cache - 1)) begin
	 // This is the last cset; exit the loop
	 let requestor <- pop (f_reset_reqs);
	 f_reset_rsps.enq (requestor);
	 rg_state <= MODULE_READY;

	 if ((cfg_verbosity != 0) && (requestor == REQUESTOR_RESET_IFC))
	    $display ("%0d: %s.rl_reset: %0d sets x %0d ways: all tag states reset to CTAG_EMPTY",
		      cur_cycle, d_or_i, csets_per_cache, ways_per_cset);
	 if ((cfg_verbosity > 1) && (requestor == REQUESTOR_FLUSH_IFC))
	    $display ("%0d: %s.rl_reset: Flushed", cur_cycle, d_or_i);
      end
      rg_cset_in_cache <= rg_cset_in_cache + 1;
   endrule

   // ----------------------------------------------------------------
   // This rule probes the MMU and provides an immediate response for
   // memory (non-IO) requests, if possible, i.e., if
   //     VM off, LD or AMO_LR, cache hit
   //     VM on,  LD or AMO_LR, TLB hit and cache hit
   // Otherwise, moves to other states that handle TLB misses, cache
   // misses, 1-cycle delayed responses for ST and AMO, I/O requests, etc.

`ifdef ISA_PRIV_S
   (* descending_urgency = "rl_probe_and_immed_rsp, rl_writeback_updated_PTE" *)
`endif

   rule rl_probe_and_immed_rsp (!resetting && (rg_state == MODULE_RUNNING));
`ifdef PERFORMANCE_MONITORING
      EventsCache events = unpack (0);
`endif

      let new_state = rg_state;
      let new_exc_code = rg_exc_code;

      // Print some initial information for debugging
      if (cfg_verbosity > 1) begin
	 $display ("%0d: %s: rl_probe_and_immed_rsp; eaddr %0h", cur_cycle, d_or_i, rg_addr);

`ifdef ISA_PRIV_S
`ifdef RV32
	 if (vm_mode != satp_mode_RV32_bare)
	    $display ("        Priv:%0d  SATP:{mode %0d asid %0h pa %0h}  VA:%0h.%0h.%0h",
		      rg_priv, vm_mode, asid, satp_pa, vpn_1, vpn_0, offset);
`elsif SV39
	 if (vm_mode != satp_mode_RV64_bare)
	    $display ("        Priv:%0d  SATP:{mode %0d asid %0h pa %0h}  VA:%0h.%0h.%0h",
		      rg_priv, vm_mode, asid, satp_pa, vpn_1, vpn_0, offset);
`endif
`endif
	 $display ("        eaddr = {CTag 0x%0h  CSet 0x%0h  Word128 0x%0h  Byte 0x%0h}",
		   fn_PA_to_CTag (fn_WordXL_to_PA (rg_addr)),
		   cset_in_cache,
		   word128_in_cline,
		   byte_in_word128);
	 fa_display_state_and_ctag_cset (cset_in_cache, state_and_ctag_cset);
	 fa_display_word128_set (cset_in_cache, word128_in_cline, word128_set);
      end

      // ----------------
      // Virtual Memory translation

`ifdef ISA_PRIV_S
      VM_Xlate_Result vm_xlate_result <- fav_vm_xlate (rg_addr,
						       rg_satp,
						       tlb_result,
						       dmem_not_imem,
						       ((rg_op == CACHE_LD) || is_AMO_LR),
						       tpl_1 (rg_st_amo_val),
						       rg_priv,
						       rg_sstatus_SUM,
						       rg_mstatus_MXR);

`ifdef PERFORMANCE_MONITORING
      events.evt_TLB = rg_mem_req_sent;
      let tlb_miss = rg_mem_req_sent && vm_xlate_result.outcome == VM_XLATE_TLB_MISS;
      events.evt_TLB_MISS = tlb_miss;
      events.evt_TLB_MISS_LAT = tlb_miss;
      //if (rg_mem_req_sent)
	 //$display ("DMEM: %0d, TLB_MISS: %0d", dmem_not_imem, tlb_miss);
`endif
`else
      // In non-VM, PA is always WordXL
      VM_Xlate_Result vm_xlate_result = VM_Xlate_Result {outcome:      VM_XLATE_OK,
							 allow_cap:    True,
							 pa:           rg_addr,
							 exc_code:     ?};
`endif

      // Compute cache hit/miss. If hit, also compute Way_in_CSet and Word128
      let pa_ctag = fn_PA_to_CTag (vm_xlate_result.pa);
      match { .hit, .way_hit, .word128 } <- fn_test_cache_hit_or_miss (pa_ctag);

      if (cfg_verbosity > 1)
	 $display ("    TLB result: ", fshow (vm_xlate_result));

      // ---- TLB miss
      if (vm_xlate_result.outcome == VM_XLATE_TLB_MISS) begin
	 new_state = PTW_START;
      end

      // ---- TLB translation exception
      else if (vm_xlate_result.outcome == VM_XLATE_EXCEPTION) begin
	 new_state = MODULE_EXCEPTION_RSP;
	 new_exc_code = vm_xlate_result.exc_code;
      end
`ifdef RVFI_DII
   else if (vm_xlate_result.pa < fromInteger (valueOf (RVFI_DII_Mem_Start)) || vm_xlate_result.pa >= fromInteger (valueOf (RVFI_DII_Mem_End))) begin
	 // We detect accesses outside of the assigned RVFI_DII range and trap on them
	 new_state    = MODULE_EXCEPTION_RSP;
	 new_exc_code = (((rg_op == CACHE_LD) || is_AMO_LR) ? exc_code_LOAD_ACCESS_FAULT : exc_code_STORE_AMO_ACCESS_FAULT);
      end
`endif

      // ---- vm_xlate_result.outcome == VM_XLATE_OK
      else begin
`ifdef ISA_PRIV_S
	 fa_record_pte_A_D_updates (tlb_result, vm_xlate_result);
`endif

	 rg_pa <= vm_xlate_result.pa;
	 rg_allow_cap <= vm_xlate_result.allow_cap;
	 let is_mem_addr = soc_map.m_is_mem_addr (fn_PA_to_Fabric_Addr (vm_xlate_result.pa));

	 // Access to non-memory
	 if (dmem_not_imem && (! is_mem_addr)) begin
	    // IO requests
	    new_state = IO_REQ;

	    if (cfg_verbosity > 1)
	       $display ("    => IO_REQ");
	 end

	 // Memory requests. Note: it's ok that this can go to non-memory space.
	 else begin
`ifdef PERFORMANCE_MONITORING
      //$display ("DMEM: %0d, LD_MISS: %0d, AMO_MISS: %0d", dmem_not_imem, (rg_op == CACHE_LD && !hit), (rg_op == CACHE_AMO && !hit));
`ifdef ISA_A
      events.evt_AMO_MISS = rg_mem_req_sent && rg_op == CACHE_AMO && !hit;
`endif
`endif
	    // ----------------
	    // Memory LD and AMO_LR
	    if ((rg_op == CACHE_LD) || is_AMO_LR || (! dmem_not_imem)) begin
	       if (hit) begin
		  // Cache hit; drive response
		     fa_drive_mem_rsp (rg_width_code, rg_is_unsigned, rg_addr, word128, unpack(0), vm_xlate_result.allow_cap, dw_commit);

`ifdef ISA_A
		  if (is_AMO_LR) begin
		     rg_lrsc_valid <= True;
		     rg_lrsc_pa    <= vm_xlate_result.pa;
		     if (cfg_verbosity > 1)
			$display ("        AMO LR: reserving PA 0x%0h", vm_xlate_result.pa);
		  end
`endif
		  if (cfg_verbosity > 1) begin
		     $display ("        Read-hit: addr 0x%0h word128 0x%0h", rg_addr, word128);
		  end
	       end
	       else begin
		  // Cache miss; start cache-line refill
		  new_state = CACHE_START_REFILL;
		  if (cfg_verbosity > 1)
		     $display ("        Read Miss: -> CACHE_START_REFILL.");
`ifdef ISA_A
		  // TODO: this is pessimistic; unnecessary in a single-hart system?
		  if (is_AMO_LR && (vm_xlate_result.pa == rg_lrsc_pa)) begin
		     rg_lrsc_valid <= False;
		     if (cfg_verbosity > 1)
			$display ("        AMO LR: cache refill: cancelling LR/SC reservation for PA 0x%0h", rg_lrsc_pa);
		  end
`endif
	       end
	    end

	    // ----------------
	    // Memory ST and AMO SC
	    else if ((rg_op == CACHE_ST) || is_AMO_SC) begin
	       Bool do_write = True;    // Always True for ST; success/fail for AMO_SC
`ifdef ISA_A
	       // ST: if to an LR/SC reserved address, invalidate the reservation
	       if ((rg_op == CACHE_ST) && (vm_xlate_result.pa == rg_lrsc_pa)) begin
		  rg_lrsc_valid <= False;
		  if (cfg_verbosity > 1)
		     $display ("        ST: cancelling LR/SC reservation for PA", vm_xlate_result.pa);
	       end

	       // AMO_SC
	       else if (is_AMO_SC) begin
		  // Fail if reservation is not valid, or if not to the reserved addr
		  if (! rg_lrsc_valid) begin
		     do_write = False;
		     if (cfg_verbosity > 1)
			$display ("        AMO SC: fail due to invalid LR/SC reservation");
		  end
		  else if (rg_lrsc_pa != vm_xlate_result.pa) begin
		     do_write = False;
		     if (cfg_verbosity > 1)
			$display ("        AMO SC: fail: reserved addr 0x%0h, this address 0x%0h",
				  rg_lrsc_pa, vm_xlate_result.pa);
		  end

		  // SC result=0 on success, =1 on failure
		  Bit #(1) lrsc_result = (do_write ? 1'b0 : 1'b1);

		  rg_ld_val     <= tuple2(False, zeroExtend (lrsc_result));
		  rg_lrsc_valid <= False;
		  if (cfg_verbosity > 1)
		     $display ("        AMO SC result = %0d", lrsc_result);
	       end
`endif
           if (do_write) begin
            //ST or succesfull SC
               if (dw_commit) begin
                  if (hit) begin
                     // Update cache line in cache
                    let new_word128_set = fn_update_word128_set (word128_set, way_hit, vm_xlate_result.pa, rg_width_code, rg_st_amo_val);
                     ram_word128_set.a.put (bram_cmd_write, word128_set_in_cache, new_word128_set);

                    if (cfg_verbosity > 1) begin
                       $display ("        Write-Cache-Hit: pa 0x%0h word128 0x%0h", vm_xlate_result.pa, rg_st_amo_val);
                       $write   ("        New Word128_Set:");
                       fa_display_word128_set (cset_in_cache, word128_in_cline, new_word128_set);
                    end
                  end
                  else begin
                     if (cfg_verbosity > 1)
                        $display ("        Write-Cache-Miss: pa 0x%0h word128 0x%0h", vm_xlate_result.pa, rg_st_amo_val);
                  end

                  if (cfg_verbosity > 1)
                     $display ("        Write-Cache-Hit/Miss: eaddr 0x%0h word128 0x%0h", rg_addr, rg_st_amo_val);

                  // For write-hits and write-misses, writeback data to memory (so cache remains clean)
                  fa_fabric_send_write_req (rg_width_code, vm_xlate_result.pa, rg_st_amo_val);

                  // Provide write-response after 1-cycle delay (thus locking the cset for 1 cycle),
                  // in case the next incoming request tries to read from the same SRAM address.
                  new_state = CACHE_ST_AMO_RSP;

                  if (cfg_verbosity > 1)
                     $display ("        => rl_write_response");
               end
           end
           else begin // do_write == False
           // SC fail
              // Hard-code address to 0 to ensure fn_extract_and_extend_bytes takes the LSBs of our 1 value.
              fa_drive_mem_rsp (rg_width_code, rg_is_unsigned, 0, tuple2(0,1), unpack(0), False, dw_commit);
           if (cfg_verbosity > 1)
              $display ("        AMO SC: Fail response for addr 0x%0h", rg_addr);
           end
       end

`ifdef ISA_A
	    // ----------------
	    // Remaining AMOs
	    else begin
	       if (! hit || !dw_commit) begin
		  // Cache miss; AMOs are only done in the cache, so first refill the cache-line
		  new_state = CACHE_START_REFILL;
		  if (cfg_verbosity > 1)
		     $display ("        AMO Miss: -> CACHE_START_REFILL.");
	       end
	       else begin
		  if (cfg_verbosity > 1) begin
		     $display ("        AMO: addr 0x%0h amo_f5 0x%0h width_code %0d is_unsigned %0d rs2_val 0x%0h",
			       rg_addr, rg_amo_funct5, rg_width_code, rg_is_unsigned, rg_st_amo_val);
		     $display ("          PA 0x%0h ", vm_xlate_result.pa);
		     $display ("          Cache word128 0x%0h, load-result 0x%0h", word128, word128);
		  end

		  // Do the AMO op on the loaded value and the store value
		  match {.new_ld_val,
			 .new_st_val} = fn_amo_op (rg_width_code, rg_amo_funct5, rg_addr, word128, rg_st_amo_val);

		  // Update cache line in cache
		  let new_word128_set = fn_update_word128_set (word128_set, way_hit, vm_xlate_result.pa, rg_width_code, new_st_val);
		  ram_word128_set.a.put (bram_cmd_write, word128_set_in_cache, new_word128_set);

		  if (cfg_verbosity > 1) begin
		     $display ("          0x%0h  op  0x%0h -> 0x%0h", word128, word128, new_st_val);
		     $write   ("          New Word128_Set:");
		     fa_display_word128_set (cset_in_cache, word128_in_cline, new_word128_set);
		  end

		  // Writeback data to memory (so cache remains clean)
		  fa_fabric_send_write_req (rg_width_code, vm_xlate_result.pa, new_st_val);

		  // If this is to the LR/SC reserved address, invalidate the reservation
		  // TODO: should we invalidate even if to a different
		  // addr, since LR/SC pairs are not supposed to have
		  // other mem ops between them?
		  if (vm_xlate_result.pa == rg_lrsc_pa) begin
		     rg_lrsc_valid <= False;
		     if (cfg_verbosity > 1)
			$display ("        AMO_op: cancelling LR/SC reservation for PA", vm_xlate_result.pa);
		  end

		  // Provide amo response after 1-cycle delay (thus locking the cset for 1 cycle),
		  // in case the next incoming request tries to read from the same address.
		  rg_ld_val     <= new_ld_val;
		  rg_st_amo_val <= new_st_val;
		  new_state     = CACHE_ST_AMO_RSP;
	       end
	    end
`endif
	 end
      end
   `ifdef ISA_CHERI
         // ---- Cancelled by Cap exception
         if (!dw_commit) begin
           new_state = MODULE_EXCEPTION_RSP;
           new_exc_code = exc_code_CHERI;
         end
   `endif
         rg_state <= new_state;
         rg_exc_code <= new_exc_code;
`ifdef PERFORMANCE_MONITORING
         aw_events [1] <= events;
`endif
   endrule: rl_probe_and_immed_rsp


`ifdef ISA_PRIV_S
   // ****************************************************************
   // TLB REFILLS (Page Table Walks)
   // ****************************************************************

`ifdef PERFORMANCE_MONITORING
   // Similar to rl_count_miss_lat but for TLB miss
   rule rl_count_tlb_latency (rg_state == PTW_START || rg_tlb_walk);
      //$display ("DMEM: %0d, TLB_LAT", dmem_not_imem);
      EventsCache events = unpack (0);
      events.evt_TLB_MISS_LAT = True;
      aw_events [2] <= events;

      rg_tlb_walk <= rg_state != MODULE_RUNNING;
   endrule
`endif

   // TODO: should this rule be merged into rl_probe_and_immed_rsp, to avoid losing a cycle?
   //       or does that worsen critical path?

   rule rl_start_tlb_refill ((rg_state == PTW_START) && (ctr_wr_rsps_pending.value == 0));
//TODO check if this needs to change for 128?
`ifdef RV32

      // RV32.Sv32: Page Table top is at Level 1

      if (cfg_verbosity > 1)
	 $display ("%0d: %s.rl_start_tlb_refill for eaddr 0x%0h; req for level 1 PTE",
		   cur_cycle, d_or_i, rg_addr);

      PA           vpn_1_pa            = (zeroExtend (vpn_1) << bits_per_byte_in_wordxl);
      PA           lev_1_pte_pa        = satp_pa + vpn_1_pa;
      PA           lev_1_pte_pa_w64    = { lev_1_pte_pa [pa_sz - 1 : 3], 3'b0 };    // 64b-aligned addr
      Fabric_Addr  lev_1_pte_pa_w64_fa = fn_PA_to_Fabric_Addr (lev_1_pte_pa_w64);
      fa_fabric_send_read_req (lev_1_pte_pa_w64_fa, 4, 1 - 1);

      rg_pte_pa <= lev_1_pte_pa;
      rg_state  <= PTW_LEVEL_1;
`elsif SV39    // ifdef RV32

      // RV64.Sv39: Page Table top is at Level 2

      if (cfg_verbosity > 1)
	 $display ("%0d: %s.rl_start_tlb_refill for eaddr 0x%0h; req for level 2 PTE",
		   cur_cycle, d_or_i, rg_addr);

      PA           vpn_2_pa            = (zeroExtend (vpn_2) << bits_per_byte_in_wordxl);
      PA           lev_2_pte_pa        = satp_pa + vpn_2_pa;
      PA           lev_2_pte_pa_w64    = { lev_2_pte_pa [pa_sz - 1 : 3], 3'b0 };    // 64b-aligned addr
      Fabric_Addr  lev_2_pte_pa_w64_fa = fn_PA_to_Fabric_Addr (lev_2_pte_pa_w64);
      fa_fabric_send_read_req (lev_2_pte_pa_w64_fa, 8, 1 - 1);

      rg_pte_pa <= lev_2_pte_pa;
      rg_state  <= PTW_LEVEL_2;
`endif         // elsif SV39

   endrule

   // ----------------
   // Receive Level 2 PTE and process it (Sv39 or Sv48 only)

`ifdef SV39
   //TODO change the widths in this
   rule rl_ptw_level_2 (rg_state == PTW_LEVEL_2);
      // Memory read-response is a level 1 PTE
      let mem_rsp <- get(masterPortShim.slave.r);

      Bit #(128) x128 = mem_rsp.rdata;
      WordXL pte;

      // PTE is lower or upper 64b word of 128b mem response
      pte = x128 [63:0];
      if (rg_pte_pa [3] == 1'b1)
	 pte = x128 [127:64];

      // Bus error
      if (mem_rsp.rresp != OKAY) begin
	 rg_exc_code <= access_exc_code;
	 rg_state    <= MODULE_EXCEPTION_RSP;
	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.rl_ptw_level_2: for eaddr 0x%0h: pte_pa 0x%0h: FABRIC_RSP_ERR: access exception %0d",
		      cur_cycle, d_or_i, rg_addr, rg_pte_pa, access_exc_code);
      end

      // Invalid PTE
      else if (is_invalid_pte (pte)) begin
	 rg_exc_code <= page_fault_exc_code;
	 rg_state    <= MODULE_EXCEPTION_RSP;

	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.rl_ptw_level_2: for eaddr 0x%0h: pte 0x%0h @ 0x%0h: Invalid PTE; page fault %0d",
		      cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa, page_fault_exc_code);
      end

      // Pointer to next-level PTE
      else if ((fn_PTE_to_X (pte) == 0) && (fn_PTE_to_R (pte) == 0)) begin
	 if (cfg_verbosity > 1) begin
	    $display ("%0d: %s.rl_rl_ptw_level_2: for eaddr 0x%0h: pte 0x%0h @ 0x%0h: continue to level 1",
		      cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa);
	    $display ("    Req for level 1 PTE");
	 end

	 PPN          ppn                 = fn_PTE_to_PPN (pte);
	 PA           lev_1_PTN_pa        = fn_PPN_and_Offset_to_PA (ppn, 12'b0);
	 PA           vpn_1_pa            = (zeroExtend (vpn_1) << bits_per_byte_in_wordxl);
	 PA           lev_1_pte_pa        = lev_1_PTN_pa + vpn_1_pa;
	 PA           lev_1_pte_pa_w64    = { lev_1_pte_pa [pa_sz - 1 : 3], 3'b0 };    // 64b-aligned addr
	 Fabric_Addr  lev_1_pte_pa_w64_fa = fn_PA_to_Fabric_Addr (lev_1_pte_pa_w64);
	 fa_fabric_send_read_req (lev_1_pte_pa_w64_fa, 8, 1 - 1);

	 rg_pte_pa <= lev_1_pte_pa;
	 rg_state  <= PTW_LEVEL_1;
      end

      // Leaf PTE pointing at address-space gigapage
      else begin
	 // Fault if PPN [1] or PPN [0] are not 0
	 PPN_1 ppn_1 = fn_PTE_to_PPN_1 (pte);
	 PPN_0 ppn_0 = fn_PTE_to_PPN_0 (pte);
	 if ((ppn_1 != 0) || (ppn_0 != 0)) begin
	    rg_exc_code <= page_fault_exc_code;
	    rg_state    <= MODULE_EXCEPTION_RSP;

	    if (cfg_verbosity > 1)
	       $display ("%0d: %s.rl_ptw_level_2: for eaddr 0x%0h: gigapage pte 0x%0h @ 0x%0h",
			 cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa);
	       $display ("    Invalid PTE: PPN[1] or PPN[0] is not zero; page fault %0d",
			 page_fault_exc_code);
	 end

	 // Insert gigapage PTE in TLB (permissions will be checked on subsequent TLB hit)
	 else begin
	    tlb.insert (asid, vpn, pte, /* level */ 2, rg_pte_pa);
	    rg_state <= CACHE_REREQ;

	    if (cfg_verbosity > 1) begin
	       PPN  ppn                = fn_PTE_to_PPN (pte);
	       PA   addr_space_page_pa = fn_PPN_and_Offset_to_PA (ppn, 12'b0);
	       $display ("%0d: %s.rl_ptw_level_2: for eaddr 0x%0h: pte 0x%0h @ 0x%0h: leaf PTE for gigapage",
			 cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa);
	       $display ("    Addr Space megapage pa: 0x%0h", addr_space_page_pa);
	    end
	 end
      end
   endrule: rl_ptw_level_2
`endif      // ifdef SV39

   // ----------------
   // Receive Level 1 PTE and process it (Sv32, Sv39 or Sv48)

   rule rl_ptw_level_1 (rg_state == PTW_LEVEL_1);
      // Memory read-response is a level 1 PTE
      let mem_rsp <- get(masterPortShim.slave.r);

      Bit #(128) x128 = mem_rsp.rdata;
      WordXL pte;
      // PTE is lower or upper 64b word of 32b mem response
      pte = x128 [63:0];
      if (rg_pte_pa [3] == 1'b1)
	 pte = x128 [127:64];

      // Bus error
      if (mem_rsp.rresp != OKAY) begin
	 rg_exc_code <= access_exc_code;
	 rg_state    <= MODULE_EXCEPTION_RSP;
	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.rl_ptw_level_1: for eaddr 0x%0h: pte_pa 0x%0h: FABRIC_RSP_ERR: access exception %0d",
		      cur_cycle, d_or_i, rg_addr, rg_pte_pa, access_exc_code);
      end

      // Invalid PTE
      else if (is_invalid_pte (pte)) begin
	 rg_exc_code <= page_fault_exc_code;
	 rg_state    <= MODULE_EXCEPTION_RSP;

	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.rl_ptw_level_1: for eaddr 0x%0h: pte 0x%0h @ 0x%0h: Invalid PTE; page fault %0d",
		      cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa, page_fault_exc_code);
      end

      // Pointer to next-level PTE
      else if ((fn_PTE_to_X (pte) == 0) && (fn_PTE_to_R (pte) == 0)) begin
	 if (cfg_verbosity > 1) begin
	    $display ("%0d: %s.rl_rl_ptw_level_1: for eaddr 0x%0h: pte 0x%0h @ 0x%0h: continue to level 0",
		      cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa);
	    $display ("    Req for level 0 PTE");
	 end

	 PPN          ppn                 = fn_PTE_to_PPN (pte);
	 PA           lev_0_PTN_pa        = fn_PPN_and_Offset_to_PA (ppn, 12'b0);
	 PA           vpn_0_pa            = (zeroExtend (vpn_0) << bits_per_byte_in_wordxl);
	 PA           lev_0_pte_pa        = lev_0_PTN_pa + vpn_0_pa;
	 PA           lev_0_pte_pa_w64    = { lev_0_pte_pa [pa_sz - 1 : 3], 3'b0 };    // 64b-aligned addr
	 Fabric_Addr  lev_0_pte_pa_w64_fa = fn_PA_to_Fabric_Addr (lev_0_pte_pa_w64);
`ifdef SV32
	 AXI4_Size    axi4_size           = 4;
`else
	 AXI4_Size    axi4_size           = 8;
`endif
	 fa_fabric_send_read_req (lev_0_pte_pa_w64_fa, axi4_size, 1 - 1);

	 rg_pte_pa <= lev_0_pte_pa;
	 rg_state  <= PTW_LEVEL_0;

      end

      // Leaf PTE pointing at address-space megapage
      // (permissions will be checked on subsequent TLB hit)
      else begin
	 // Fault if PPN [0] is not 0
	 PPN_0 ppn_0 = fn_PTE_to_PPN_0 (pte);
	 if (ppn_0 != 0) begin
	    rg_exc_code <= page_fault_exc_code;
	    rg_state    <= MODULE_EXCEPTION_RSP;

	    if (cfg_verbosity > 1)
	       $display ("%0d: %s.rl_ptw_level_1: for eaddr 0x%0h: megapage pte 0x%0h @ 0x%0h",
			 cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa);
	       $display ("    Invalid PTE: PPN [0] is not zero; page fault %0d",
			 page_fault_exc_code);
	 end

	 // Insert gigapage PTE in TLB (permissions will be checked on subsequent TLB hit)
	 else begin
	    tlb.insert (asid, vpn, pte, /* level */ 1, rg_pte_pa);
	    rg_state <= CACHE_REREQ;

	    if (cfg_verbosity > 1) begin
	       PPN ppn                = fn_PTE_to_PPN (pte);
	       PA  addr_space_page_pa = fn_PPN_and_Offset_to_PA (ppn, 12'b0);
	       $display ("%0d: %s.rl_ptw_level_1: for eaddr 0x%0h: pte 0x%0h @ 0x%0h: leaf PTE for megapage",
			 cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa);
	       $display ("    Addr Space megapage pa: 0x%0h", addr_space_page_pa);
	    end
	 end
      end
   endrule: rl_ptw_level_1

   // ----------------
   // Receive Level 0 PTE and process it

   rule rl_ptw_level_0 (rg_state == PTW_LEVEL_0);
      // Memory read-response is a level 0 PTE
      let mem_rsp <- get(masterPortShim.slave.r);

      Bit #(128) x128 = mem_rsp.rdata;
      WordXL pte;
      // PTE is lower or upper 32b word of 64b mem response
      pte = x128 [63:0];
      if (rg_pte_pa [3] == 1'b1)
	 pte = x128 [127:64];

      // Bus error
      if (mem_rsp.rresp != OKAY) begin
	 rg_exc_code <= access_exc_code;
	 rg_state    <= MODULE_EXCEPTION_RSP;
	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.rl_ptw_level_0: for eaddr 0x%0h: pte_pa 0x%0h: FABRIC_RSP_ERR: access exception %0d",
		      cur_cycle, d_or_i, rg_addr, rg_pte_pa, access_exc_code);
      end

      // Invalid PTE
      else if (is_invalid_pte (pte)) begin
	 rg_exc_code <= page_fault_exc_code;
	 rg_state    <= MODULE_EXCEPTION_RSP;

	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.rl_ptw_level_0: for eaddr 0x%0h: pte 0x%0h @ 0x%0h: Invalid PTE; page fault %0d",
		      cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa, page_fault_exc_code);
      end

      // Pointer to next-level PTE: invalid at level 0
      else if ((fn_PTE_to_X (pte) == 0) && (fn_PTE_to_R (pte) == 0)) begin
	 rg_exc_code <= page_fault_exc_code;
	 rg_state    <= MODULE_EXCEPTION_RSP;

	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.rl_ptw_level_0: for eaddr 0x%0h: pte 0x%0h @ 0x50h: Not a leaf PTE; page fault %0d",
		      cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa, page_fault_exc_code);
      end

      // Leaf PTE pointing at address-space page; insert in TLB
      // (permissions will be checked on next TLB hit)
      else begin
	 tlb.insert (asid, vpn, pte, /* level */ 0, rg_pte_pa);
	 rg_state <= CACHE_REREQ;

	 if (cfg_verbosity > 1) begin
	    PPN ppn                = fn_PTE_to_PPN (pte);
	    PA  addr_space_page_pa = fn_PPN_and_Offset_to_PA (ppn, 12'b0);
	    $display ("%0d: %s.rl_ptw_level_0: for eaddr 0x%0h: pte 0x%0h @ 0x%0h: leaf PTE",
		      cur_cycle, d_or_i, rg_addr, pte, rg_pte_pa);
	    $display ("    Addr Space page pa: 0x%0h", addr_space_page_pa);
	 end
      end
   endrule
`endif      // ifdef ISA_PRIV_S

   // ****************************************************************
   // CACHE REFILLS
   // ****************************************************************

`ifdef PERFORMANCE_MONITORING
   // Count latency of a miss, starts firing when state is CACHE_START_REFILL
   // and stops firing once state returns to MODULE_RUNNING
   // First cycle of miss is not counted, but overcounts by one at the end to compensate
   rule rl_count_miss_lat (!resetting && (rg_state == CACHE_START_REFILL || rg_cache_rereq_data));
      EventsCache events = unpack (0);
      //$display ("DMEM: %0d, LD_LAT: %0d, AMO_LAT: %0d", dmem_not_imem, rg_op == CACHE_LD, rg_op == CACHE_AMO);
      events.evt_LD_MISS_LAT = rg_op == CACHE_LD;
`ifdef ISA_A
      events.evt_AMO_MISS_LAT = rg_op == CACHE_AMO;
`endif
      aw_events [3] <= events;

      rg_cache_rereq_data <= rg_state != MODULE_RUNNING;
   endrule
`endif

   // Start cache-line refill loop when no more write-responses are outstanding
   // Send request into fabric for first fabric-word of cache line.
   // Pick victim way, update ctag.
   // Initiate read of word64_set in cache for read-modify-write of word64

   rule rl_start_cache_refill (!resetting && (rg_state == CACHE_START_REFILL) && (ctr_wr_rsps_pending.value == 0));
      if (cfg_verbosity > 1)
	 $display ("%0d: %s.rl_start_cache_refill: ", cur_cycle, d_or_i);

`ifdef PERFORMANCE_MONITORING
      EventsCache events = unpack (0);
      events.evt_LD_MISS = rg_op == CACHE_LD;
      aw_events [7] <= events;
`endif

      // Send burst request into fabric for full cache line
      PA             cline_addr        = fn_align_Addr_to_CLine (rg_pa);
      Fabric_Addr    cline_fabric_addr = fn_PA_to_Fabric_Addr (cline_addr);
      fa_fabric_send_read_req (cline_fabric_addr, ((bytes_per_fabric_addr == 8) ? 8 : 16), fromInteger ((bytes_per_cline / bytes_per_fabric_data) - 1));

      // Pick a victim 'way'
      // TODO: prioritize picking an EMPTY slot over a CLEAN slot
      // Currently just uses rg_victim_way and increments it
      // The following extend/truncate trickery is because
      // Bits_per_Way_in_CSet may be 0 (direct-mapped),
      // for which the '1' in '+1' is not a valid literal
      Bit #(TAdd #(1, Bits_per_Way_in_CSet)) tmp = extend (rg_victim_way);
      tmp = tmp + 1;
      Way_in_CSet new_victim_way = truncate (tmp);
      rg_victim_way <= new_victim_way;

      // State_and_CTag_CSet are updated in rl_cache_refill_rsps_loop
      // only after observing the first read-response, to assure that
      // the read is successfule and not an access error.

      // Request read of first Word128_Set in CLine (BRAM port B)
      // for set read-modify-write (not relevant for direct-mapped)
      let word128_in_cline      = 0;
      let word128_set_in_cache  = { cset_in_cache, word128_in_cline };
      rg_word128_set_in_cache  <= word128_set_in_cache;
      ram_word128_set.b.put (bram_cmd_read, word128_set_in_cache, ?);

      // Enter cache refill loop, awaiting refill responses from mem
      rg_lower_word64_full   <= False;
      rg_error_during_refill <= False;
      rg_state               <= CACHE_REFILL;

      if (cfg_verbosity > 1)
	 $display ("    Victim way %0d; => CACHE_REFILL", new_victim_way);
   endrule: rl_start_cache_refill

   /* TODO: Remove; this was used before support for read-bursts
   // Loop that issues requests for subsequent fabric-words in cline refill
   rule rl_cache_refill_req_loop (rg_requesting_cline);
      if (cfg_verbosity > 2)
	 $display ("%0d: %s.rl_cache_refill_req_loop", cur_cycle, d_or_i);

      // Send request into fabric for next fabric-word of cache line
      PA          cline_addr        = fn_align_Addr_to_CLine (rg_pa);
      Fabric_Addr cline_fabric_addr = (fn_PA_to_Fabric_Addr (cline_addr) | rg_req_byte_in_cline);
      AXI4_Size   axi4_size         = ((bytes_per_fabric_data == 4) ? 4 : 8);
      fa_fabric_send_read_req (cline_fabric_addr, axi4_size);

      // Check if end of refill loop (req_byte_in_cline is last one)
      Fabric_Addr last_byte_offset_in_cline = fromInteger (bytes_per_cline - bytes_per_fabric_data);

      rg_requesting_cline  <= (rg_req_byte_in_cline != last_byte_offset_in_cline);
      rg_req_byte_in_cline <= rg_req_byte_in_cline + fromInteger (bytes_per_fabric_data);
   endrule
   */

   // ----------------------------------------------------------------
   // TODO (possibly): we complete a cache refill (in rl_cache_refill_loop) and
   // then, in rl_rereq, redo the missing request, just in case the
   // last word128 of the refill is exactly the word128 we need in which
   // case we'd have a race on ram port A (refill write) and port B
   // (request).
   // An alternative would be to buffer the target word64 during the
   // refill and drive it as a result, but that would cost more state
   // and/or muxes.
   // An alternative would be to do a "wrapping refill", in which case
   // the last word64 of the refill will never conflict with the
   // requested word.

   // ----------------------------------------------------------------
   // Loop that receives responses from the fabric with fabric-words of the cline (from mem).
   // For 32b fabrics:
   //     If this is the lower Word32, just register it.
   //     else concat with lower Word32 and update word64 in word64_set
   // For 64b fabrics:
   //     update word64 in word64_set.
   // Update word64 in word64_set:
   //     write back to word64_set ram, and
   //     initiate read of next word64_set from ram
   //         (for set read-modify-write; not relevant for direct-mapped)

   rule rl_cache_refill_rsps_loop (!resetting && rg_state == CACHE_REFILL);
      let mem_rsp <- get(masterPortShim.slave.r);
      if (cfg_verbosity > 2) begin
	 $display ("%0d: %s.rl_cache_refill_rsps_loop:", cur_cycle, d_or_i);
	 $display ("        ", fshow (mem_rsp));
      end

      // Bus errors; remember it, and raise exception after all the refill responses
      Bool err_rsp = (mem_rsp.rresp != OKAY);
      if (err_rsp) begin
	 rg_error_during_refill <= True;
	 rg_exc_code            <= access_exc_code;
	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.rl_cache_refill_rsps_loop: FABRIC_RSP_ERR: raising access exception %0d",
		      cur_cycle, d_or_i, access_exc_code);
      end

      // For 64b fabrics, if this is lower Word64, just register it to hold until upper Word64 arrives
      if (! rg_lower_word64_full) begin
	 rg_lower_word64      <= mem_rsp.rdata;
         rg_lower_tag         <= mem_rsp.ruser;
	 rg_lower_word64_full <= True;
	 if (cfg_verbosity > 2)
	    $display ("        Recording rdata in rg_lower_word64");
      end

      // Refill 128b of cache line
      else begin
	 // Assert: rg_lower_64_full == True
	 Cache_Entry new_word128 = tuple2({mem_rsp.ruser, rg_lower_tag}, { mem_rsp.rdata, rg_lower_word64 });
	 rg_lower_word64_full <= False;
	 if (cfg_verbosity > 2)
	    $display ("        64b fabric: concat with rg_lower_word64: new_word128 0x%0x", new_word128);

	 Word128_in_CLine word128_in_cline = truncate (rg_word128_set_in_cache);

	 // Update the State_and_CTag_CSet (BRAM port A) (if this is the first
	 // response and not an error)
	 if ((word128_in_cline == 0) && (! err_rsp)) begin
`ifdef PERFORMANCE_MONITORING
	    //if (state_and_ctag_cset[rg_victim_way].state == CTAG_CLEAN) $display ("EVT_EVICT, DMEM: %0d", dmem_not_imem);
	    EventsCache events = unpack (0);
	    events.evt_EVICT = (state_and_ctag_cset [rg_victim_way].state == CTAG_CLEAN);
	    aw_events [4] <= events;
`endif

	    let new_state_and_ctag_cset = state_and_ctag_cset;
	    new_state_and_ctag_cset [rg_victim_way] = State_and_CTag {state: CTAG_CLEAN,
								      ctag : fn_PA_to_CTag (rg_pa)};
	    ram_state_and_ctag_cset.a.put (bram_cmd_write, cset_in_cache, new_state_and_ctag_cset);
	 end

	 // Update the Word128_Set (BRAM port A) (if this response was not an error)
	 let new_word128_set = word128_set;
	 new_word128_set [rg_victim_way] = new_word128;
	 if (! err_rsp)
	    ram_word128_set.a.put (bram_cmd_write, rg_word128_set_in_cache, new_word128_set);

	 // If more word64_sets in cacheline, initiate RAM read for next word64_set
	 if (word128_in_cline != fromInteger (word128s_per_cline - 1)) begin
	    let next_word128_set_in_cache = rg_word128_set_in_cache + 1;
	    ram_word128_set.b.put (bram_cmd_read, next_word128_set_in_cache, ?);
	    rg_word128_set_in_cache <= next_word128_set_in_cache;
	 end

	 // else final Word128 of CLine; raise exception if pending,
	 // or redo original missing request on port B.
	 // The word128 we just wrote in port A may be the word128 we request on port B,
	 // so we do it a cycle later, in rl_rereq.
	 else if (err_rsp || rg_error_during_refill) begin
	    rg_state    <= MODULE_EXCEPTION_RSP;
	    if (cfg_verbosity > 1)
	       $display ("    => MODULE_EXCEPTION_RSP");
	 end

	 else begin
	    rg_state <= CACHE_REREQ;
	    if (cfg_verbosity > 1)
	       $display ("    => CACHE_REREQ");
	 end

	 if (cfg_verbosity > 2) begin
	    $display ("        Updating Cache word128_set 0x%0h, word128_in_cline %0d) old => new",
		      rg_word128_set_in_cache, word128_in_cline);

	    fa_display_word128_set (cset_in_cache, word128_in_cline, word128_set);
	    fa_display_word128_set (cset_in_cache, word128_in_cline, new_word128_set);
	 end
      end
   endrule: rl_cache_refill_rsps_loop

   // ----------------------------------------------------------------
   // After tlb and cache refills, redo the missing request,
   // i.e., probe the TLB and cache (BRAM port B) again

   rule rl_rereq (!resetting && rg_state == CACHE_REREQ);
      rg_state <= MODULE_RUNNING;
      fa_req_ram_B (rg_addr);
   endrule

   // ----------------------------------------------------------------
   // Provide write-response (ST op)
   // Stays in this state until CPU's next request puts it back into RUNNING state

   rule rl_ST_AMO_response (rg_state == CACHE_ST_AMO_RSP && dmem_not_imem);
      dw_valid             <= True;
      let ld_val = rg_ld_val;
      if (! rg_allow_cap) ld_val = tuple2 (False, tpl_2 (ld_val));
      dw_output_ld_val     <= ld_val;        // Irrelevant for ST; relevant for SC, AMO
      dw_output_st_amo_val <= rg_st_amo_val;
   endrule

   // ----------------------------------------------------------------
   // Memory-mapped I/O read requests (LD and AMO_LR)
   // LRs are treated just like LDs, but we do not place any reservation on the address
   // (so a subsequent SC is guaranteed to fail).
   // TODO: Move this into rl_probe_and_immed_rsp, post MMU translation?
   // No caching, send request directly to fabric

   rule rl_io_read_req (   !resetting
                        && (rg_state == IO_REQ)
			&& ((rg_op == CACHE_LD) || is_AMO_LR)
			&& (ctr_wr_rsps_pending.value == 0)
            && dmem_not_imem);

      if (cfg_verbosity > 1)
	 $display ("%0d: %s.rl_io_read_req; width_code 0x%0h vaddr %0h  paddr %0h",
		   cur_cycle, d_or_i, rg_width_code, rg_addr, rg_pa);

      Fabric_Addr fabric_addr = fn_PA_to_Fabric_Addr (rg_pa);
      if (fromInteger(bytes_per_fabric_data) >= fromAXI4_Size(fn_width_code_to_AXI4_Size(rg_width_code)))
        fa_fabric_send_read_req (fabric_addr, fn_width_code_to_AXI4_Size(rg_width_code), 1 - 1);
      else
        fa_fabric_send_read_req (fabric_addr, fromInteger(bytes_per_fabric_data), 2 - 1); // XXX only bursts of size 2 supported

`ifdef ISA_A
      // Invalidate LR/SC reservation if AMO_LR
      if (is_AMO_LR) rg_lrsc_valid <= False;
`endif
      rg_state <= IO_AWAITING_READ_RSP;
   endrule

   // ----------------------------------------------------------------
   // Receive I/O read response from fabric

   rule rl_io_read_rsp (!resetting && (rg_state == IO_AWAITING_READ_RSP));

      let rd_data <- get(masterPortShim.slave.r);

      if (cfg_verbosity > 1) begin
	 $display ("%0d: %s.rl_io_read_rsp: vaddr 0x%0h  paddr 0x%0h", cur_cycle, d_or_i, rg_addr, rg_pa);
	 $display ("    ", fshow (rd_data));
      end

      if (!rg_lower_word64_full && rd_data.rlast) begin // Single flit response
        let ld_val = fn_extract_and_extend_bytes(rg_width_code, rg_is_unsigned, zeroExtend(rg_addr[2:0]), tuple2(0, zeroExtend (rd_data.rdata)));
        rg_ld_val <= ld_val;

        // Successful read
        if (rd_data.rresp == OKAY) begin
           fa_drive_IO_read_rsp (rg_width_code, rg_is_unsigned, rg_addr, ld_val, rg_allow_cap);
           rg_state <= IO_READ_RSP;
        end

        // Bus error
        else begin
           rg_state    <= MODULE_EXCEPTION_RSP;
           rg_exc_code <= exc_code_LOAD_ACCESS_FAULT;
           if (cfg_verbosity > 1)
              $display ("%0d: %s.rl_io_read_rsp: FABRIC_RSP_ERR: raising trap LOAD_ACCESS_FAULT",
                     cur_cycle, d_or_i);
        end
      end else begin
        if (!rd_data.rlast) begin
          rg_lower_word64_full <= True;
          rg_lower_word64 <= rd_data.rdata;
        end else begin // rg_lower_word64_full && rd_data.rlast
          if (rd_data.rresp == OKAY) begin
            fa_drive_IO_read_rsp(rg_width_code, rg_is_unsigned, rg_addr, tuple2(False, {rd_data.rdata, rg_lower_word64}), rg_allow_cap); // No tags from IO mem
            rg_ld_val <= tuple2(False, {rd_data.rdata, rg_lower_word64});
            rg_lower_word64_full <= False;
          end else begin
            rg_state    <= MODULE_EXCEPTION_RSP;
            rg_exc_code <= exc_code_LOAD_ACCESS_FAULT;
            if (cfg_verbosity > 1)
              $display ("%0d: %s.rl_io_read_rsp: FABRIC_RSP_ERR: raising trap LOAD_ACCESS_FAULT",
                     cur_cycle, d_or_i);
          end
        end
      end
   endrule

   // ----------------
   // Maintain I/O-read response
   // Stays in this state until CPU's next request puts it back into RUNNING state

   rule rl_maintain_io_read_rsp (!resetting && rg_state == IO_READ_RSP && dmem_not_imem);
      fa_drive_IO_read_rsp (rg_width_code, rg_is_unsigned, rg_addr, rg_ld_val, rg_allow_cap);
   endrule

   // ----------------------------------------------------------------
   // Memory-mapped I/O write requests (ST)
   // No caching, send request directly to fabric.
   // TODO: Move this into rl_probe_and_immed_rsp, post MMU translation

`ifdef ISA_PRIV_S
   (* descending_urgency = "rl_io_write_req, rl_writeback_updated_PTE" *)
`endif

   rule rl_io_write_req (!resetting && (rg_state == IO_REQ) && (rg_op == CACHE_ST) && dmem_not_imem);
      if (cfg_verbosity > 1)
	 $display ("%0d: %s: rl_io_write_req; width_code 0x%0h  vaddr %0h  paddr %0h  word64 0x%0h",
		   cur_cycle, d_or_i, rg_width_code, rg_addr, rg_pa, rg_st_amo_val);

       fa_fabric_send_write_req (rg_width_code, rg_pa, rg_st_amo_val);

      rg_state <= CACHE_ST_AMO_RSP;

      if (cfg_verbosity > 1)
	 $display ("    => rl_ST_AMO_response");
   endrule

   // ----------------------------------------------------------------
   // Memory-mapped I/O AMO_SC requests. Always fail.

`ifdef ISA_A
   rule rl_io_AMO_SC_req (!resetting && (rg_state == IO_REQ) && is_AMO_SC && dmem_not_imem);

      rg_ld_val <= tuple2(False, 1);    // 1 is LR/SC failure value
      rg_state  <= CACHE_ST_AMO_RSP;

      if (cfg_verbosity > 1) begin
	 $display ("%0d: %s: rl_io_AMO_SC_req; width_code 0x%0h  vaddr %0h  paddr %0h  word64 0x%0h",
		   cur_cycle, d_or_i, rg_width_code, rg_addr, rg_pa, rg_st_amo_val);
	 $display ("    FAIL due to I/O address.");
	 $display ("    => rl_ST_AMO_response");
      end
   endrule
`endif

   // ----------------------------------------------------------------
   // Memory-mapped I/O AMO requests other than LR/SC
   // Fail with STORE/AMO Access fault exception
   // TODO: Extend fabric to do these ops at the I/O device?

`ifdef ISA_A
   rule rl_io_AMO_op_req (!resetting && (rg_state == IO_REQ) && is_AMO && (! is_AMO_LR) && (! is_AMO_SC) && dmem_not_imem);
      if (cfg_verbosity > 1)
	 $display ("%0d: %s.rl_io_AMO_op_req; width_code 0x%0h vaddr %0h  paddr %0h",
		   cur_cycle, d_or_i, rg_width_code, rg_addr, rg_pa);

      Fabric_Addr fabric_addr = fn_PA_to_Fabric_Addr (rg_pa);
      if (fromInteger(bytes_per_fabric_data) >= fromAXI4_Size(fn_width_code_to_AXI4_Size(rg_width_code)))
        fa_fabric_send_read_req (fabric_addr, fn_width_code_to_AXI4_Size(rg_width_code), 1 - 1);
      else
        fa_fabric_send_read_req (fabric_addr, fn_width_code_to_AXI4_Size(rg_width_code), 2 - 1); // XXX only bursts of size 2 supported

      rg_state <= IO_AWAITING_AMO_READ_RSP;

   endrule
`endif

   // ----------------
   // Receive I/O AMO read response from fabric,
   // Do the AMO op, and send store to fabric

`ifdef ISA_A
`ifdef ISA_PRIV_S
   (* descending_urgency = "rl_io_AMO_read_rsp, rl_writeback_updated_PTE" *)
`endif

   rule rl_io_AMO_read_rsp (!resetting && rg_state == IO_AWAITING_AMO_READ_RSP && dmem_not_imem);
      let rd_data <- get(masterPortShim.slave.r);
      if (cfg_verbosity > 1) begin
	 $display ("%0d: %s.rl_io_AMO_read_rsp: vaddr 0x%0h  paddr 0x%0h", cur_cycle, d_or_i, rg_addr, rg_pa);
	 $display ("    ", fshow (rd_data));
      end

      // Bus error for AMO read
      if (rd_data.rresp != OKAY) begin
	 rg_state    <= MODULE_EXCEPTION_RSP;
	 rg_exc_code <= exc_code_STORE_AMO_ACCESS_FAULT;
	 if (cfg_verbosity > 1)
	    $display ("%0d: %s.rl_io_AMO_read_rsp: FABRIC_RSP_ERR: raising trap STORE_AMO_ACCESS_FAULT",
		      cur_cycle, d_or_i);
      end
      // Successful AMO read
      else begin
         if (!rg_lower_word64_full && !rd_data.rlast) begin
           rg_lower_word64_full <= True;
           rg_lower_word64 <= rd_data.rdata;
         end else begin
            let ld_val = ?;
            if (rg_lower_word64_full) begin
               ld_val = tuple2(False, {rd_data.rdata, rg_lower_word64});
               rg_lower_word64_full <= False;
            end else begin
               ld_val = fn_extract_and_extend_bytes(rg_width_code, rg_is_unsigned, zeroExtend(rg_addr[2:0]), tuple2(0, zeroExtend(rd_data.rdata)));
            end
           if (cfg_verbosity > 1)
              $display ("%0d: %s: rl_io_AMO_read_rsp; f3 0x%0h  vaddr %0h  paddr %0h  word128 0x%0h",
                        cur_cycle, d_or_i, rg_width_code, rg_addr, rg_pa, rg_st_amo_val);

           // Do the AMO op on the loaded value and the store value
           match {.new_ld_val,
                  .new_st_val} = fn_amo_op (rg_width_code, rg_amo_funct5, rg_addr, tuple2(0, tpl_2(ld_val)), rg_st_amo_val);

           // Write back new st_val to fabric
           fa_fabric_send_write_req (rg_width_code, rg_pa, new_st_val);

	    fa_drive_IO_read_rsp (rg_width_code, rg_is_unsigned, rg_addr, new_ld_val, rg_allow_cap);
	    rg_ld_val <= new_ld_val;
	    rg_state  <= IO_READ_RSP;

           if (cfg_verbosity > 1)
              $display ("    => rl_ST_AMO_response");
         end
      end
   endrule
`endif

   // ----------------------------------------------------------------
   // Discard write-responses from the fabric
   // NOTE: assuming in-order responses from fabric

   rule rl_discard_write_rsp (dmem_not_imem);
      let wr_resp <- get(masterPortShim.slave.b);

      if (ctr_wr_rsps_pending.value == 0) begin
	 $display ("%0d: ERROR: %s.rl_discard_write_rsp: unexpected W response (ctr_wr_rsps_pending.value == 0)",
		   cur_cycle, d_or_i);
	 $display ("    ", fshow (wr_resp));
	 $finish (1);    // Assertion failure
      end

      ctr_wr_rsps_pending.decr;

      if (wr_resp.bresp != OKAY) begin
	 // TODO: need to raise a non-maskable interrupt (NMI) here
	 $display ("%0d: %s.rl_discard_write_rsp: fabric response error: exit", cur_cycle, d_or_i);
	 $display ("    ", fshow (wr_resp));
      end
      else if (cfg_verbosity > 1) begin
	 $display ("%0d: %s.rl_discard_write_rsp: pending %0d ",
		   cur_cycle, d_or_i, ctr_wr_rsps_pending.value, fshow (wr_resp));
      end
   endrule

   // ----------------------------------------------------------------
   // This rule drives an exception response until the cache is put
   // into MODULE_RUNNING state by the next request.

   rule rl_drive_exception_rsp (!resetting && rg_state == MODULE_EXCEPTION_RSP);
      dw_valid    <= True;
      dw_exc      <= True;
      dw_exc_code <= rg_exc_code;
   endrule

      Wire#(CacheOp) w_req_op <- mkWire;
      Wire#(Bit#(3)) w_req_width_code <- mkWire;
      Wire#(Bool) w_req_is_unsigned <- mkWire;
`ifdef ISA_A
      Wire#(Bit#(5)) w_req_amo_funct5 <- mkWire;
`endif
      Wire#(Addr) w_req_addr <- mkWire;
      Wire#(Tuple2#(Bool,Bit#(128))) w_req_st_value <- mkWire;
      Wire#(Priv_Mode) w_req_priv <- mkWire;
      Wire#(Bit#(1)) w_req_sstatus_SUM <- mkWire;
      Wire#(Bit#(1)) w_req_mstatus_MXR <- mkWire;
      Wire#(WordXL) w_req_satp <- mkWire;

   (* mutually_exclusive = "do_req, rl_cache_refill_rsps_loop" *)
   (* mutually_exclusive = "do_req, rl_rereq" *)
   (* mutually_exclusive = "do_req, rl_start_cache_refill" *)
   (* mutually_exclusive = "do_req, do_reset_req" *)
   (* mutually_exclusive = "do_req, do_tlb_flush" *)
   rule do_req (! resetting);
      let op = w_req_op;
      let width_code = w_req_width_code;
      let is_unsigned = w_req_is_unsigned;
`ifdef ISA_A
      let amo_funct5 = w_req_amo_funct5;
`endif
      let addr = w_req_addr;
      let st_value = w_req_st_value;
      let priv = w_req_priv;
      let sstatus_SUM = w_req_sstatus_SUM;
      let mstatus_MXR = w_req_mstatus_MXR;
      let satp = w_req_satp;

      if (cfg_verbosity > 1) begin
	 $display ("%0d: %m.req: op:", cur_cycle, fshow (op),
		   " f3:%0d addr:0x%0h st_value:0x%0h", width_code, addr, st_value);
	 $display ("    priv:", fshow_Priv_Mode (priv),
		   " sstatus_SUM:%0d mstatus_MXR:%0d satp:0x%0h",
		   sstatus_SUM,    mstatus_MXR,    satp);
`ifdef ISA_A
	 $display ("    amo_funct5 = 0x%0h", amo_funct5);
`endif
      end

      rg_op          <= op;
      rg_width_code  <= width_code;
      rg_is_unsigned <= is_unsigned;
`ifdef ISA_A
      rg_amo_funct5  <= amo_funct5;
`endif
      rg_addr        <= addr;
      rg_st_amo_val  <= st_value;

      rg_priv        <= priv;
      rg_sstatus_SUM <= sstatus_SUM;
      rg_mstatus_MXR <= mstatus_MXR;
      rg_satp        <= satp;

      // Initial default PA assumes no VM translation
      rg_pa <= fn_WordXL_to_PA (addr);

      if (! fn_is_aligned (width_code, addr)) begin
	 // We detect misaligned accesses and trap on them
	 rg_state    <= MODULE_EXCEPTION_RSP;
	 rg_exc_code <= ((op == CACHE_LD) ? exc_code_LOAD_ADDR_MISALIGNED : exc_code_STORE_AMO_ADDR_MISALIGNED);
      end
      else begin
	 rg_state <= MODULE_RUNNING;
	 fa_req_ram_B (addr);
      end
   endrule

   rule do_set_req_valid;
`ifdef PERFORMANCE_MONITORING
      rg_mem_req_sent <= wr_mem_req_sent;
`endif
   endrule

   (* fire_when_enabled *)
   rule do_reset_req (rw_reset_req.wget matches tagged Valid .req);
      f_reset_reqs.enq(req);
   endrule

   (* no_implicit_conditions, fire_when_enabled *)
   rule do_tlb_flush if (pw_tlb_flush_req);
`ifdef ISA_PRIV_S
      tlb.flush;
      rg_state <= MODULE_READY;
      if (cfg_verbosity > 1)
        $display ("%0d: %s.tlb_flush", cur_cycle, d_or_i);
`ifdef PERFORMANCE_MONITORING
      EventsCache events = unpack (0);
      events.evt_TLB_FLUSH = True;
      aw_events [5] <= events;
`endif
`else
      noAction;
`endif
   endrule


   // ================================================================
   // INTERFACE

   method Action set_verbosity (Bit #(4) v);
      cfg_verbosity <= v;
   endmethod

   interface Server server_reset;
      interface Put request;
        method Action put (Token t) if (f_reset_reqs.notFull);
           rw_reset_req.wset (REQUESTOR_RESET_IFC);
        endmethod
      endinterface
      interface Get response;
        method ActionValue #(Token) get () if (f_reset_rsps.first == REQUESTOR_RESET_IFC);
           f_reset_rsps.deq;
           return ?;
        endmethod
      endinterface
   endinterface

   // CPU interface: request
   // NOTE: this has no flow control: CPU should only invoke it when consuming prev output.
   // As soon as this method is called, the module starts working on this new request.
   method Action  req (CacheOp op,
               Bit #(3) width_code,
               Bool is_unsigned,
`ifdef ISA_A
               Bit #(5) amo_funct5,
`endif
               Addr addr,
               Tuple2#(Bool, Bit#(128)) st_value,
               // The following  args for VM
               Priv_Mode  priv,
               Bit #(1)   sstatus_SUM,
               Bit #(1)   mstatus_MXR,
               WordXL     satp);    // { VM_Mode, ASID, PPN_for_page_table }
      w_req_op <= op;
      w_req_width_code <= width_code;
      w_req_is_unsigned <= is_unsigned;
`ifdef ISA_A
      w_req_amo_funct5 <= amo_funct5;
`endif
      w_req_addr <= addr;
      w_req_st_value <= st_value;
      w_req_priv <= priv;
      w_req_sstatus_SUM <= sstatus_SUM;
      w_req_mstatus_MXR <= mstatus_MXR;
      w_req_satp <= satp;
`ifdef PERFORMANCE_MONITORING
      EventsCache events = unpack (0);
      wr_mem_req_sent <= True;
      //$display ("DMEM: %0d, MEM_OP: %0d", dmem_not_imem, op);
      events.evt_LD = op == CACHE_LD;
      events.evt_ST = op == CACHE_ST;
`ifdef ISA_A
      events.evt_AMO = op == CACHE_AMO;
`endif
      aw_events [6] <= events;
`endif
   endmethod

`ifdef ISA_CHERI
   method Action commit;
      dw_commit <= True;
   endmethod
`endif

   method Bool  valid;
      return dw_valid;
   endmethod

   method WordXL  addr;    // req addr for which this is a response
      return rg_addr;
   endmethod

   method Tuple2#(Bool, Bit #(128))  word128;
      return dw_output_ld_val;
   endmethod

   method Tuple2#(Bool, Bit #(128))  st_amo_val;
      return dw_output_st_amo_val;
   endmethod

   method Bool  exc;
      return dw_exc;
   endmethod

   method Exc_Code  exc_code;
      return dw_exc_code;
   endmethod

   // Flush request/response
   interface Server  server_flush;
      interface Put  request;
	 method Action  put (Token t) if (f_reset_reqs.notFull);
	    rw_reset_req.wset (REQUESTOR_FLUSH_IFC);
	 endmethod
      endinterface
      interface Get  response;
	 method ActionValue #(Token)  get () if (f_reset_rsps.first == REQUESTOR_FLUSH_IFC);
	    f_reset_rsps.deq;
	    return ?;
	 endmethod
      endinterface
   endinterface

   // TLB flush
   method Action tlb_flush;
      pw_tlb_flush_req.send;
   endmethod

   // Fabric interface
   interface mem_master = masterPortShim.master;

`ifdef PERFORMANCE_MONITORING
   method EventsCache events = aw_events [0];
`endif

endmodule: mkMMU_Cache

// ================================================================

endpackage: MMU_Cache
