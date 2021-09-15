// Copyright (c) 2018-2019 Bluespec, Inc. All Rights Reserved.

//-
// RVFI_DII modifications:
//     Copyright (c) 2018 Peter Rugg
// AXI (user fields) modifications:
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

package Core_IFC;

// ================================================================
// This package defines the interface of a Core module which
// contains:
//     - mkCPU (the RISC-V CPU)
//     - mkFabric_2x3
//     - mkNear_Mem_IO_AXI4
//     - mkPLIC_16_2_7
//     - mkTV_Encode          (Tandem-Verification logic, optional: INCLUDE_TANDEM_VERIF)
//     - mkDebug_Module       (RISC-V Debug Module, optional: INCLUDE_GDB_CONTROL)

// ================================================================
// BSV library imports

import Vector        :: *;
import GetPut        :: *;
import ClientServer  :: *;

// ----------------
// BSV additional libs
import AXI4 :: *;

// ================================================================
// Project imports

// Main fabric
import Fabric_Defs  :: *;

`ifdef INCLUDE_DMEM_SLAVE
import AXI4_Lite_Types :: *;
`endif

// External interrupt request interface
import PLIC  :: *;

`ifdef INCLUDE_TANDEM_VERIF
import TV_Info  :: *;
`endif

`ifdef RVFI_DII
import RVFI_DII     :: *;
import ISA_Decls      :: *;
`endif

`ifdef INCLUDE_GDB_CONTROL
import Debug_Module  :: *;
`endif

`ifdef PERFORMANCE_MONITORING
`ifdef ISA_CHERI
`ifdef NO_TAG_CACHE
`define TAG_CACHE_EVENTS_EXTERNAL
`endif
`endif
`endif

// ================================================================
// The Core interface

interface Core_IFC #(numeric type t_n_interrupt_sources);

   // ----------------------------------------------------------------
   // Debugging: set core's verbosity

   method Action  set_verbosity (Bit #(4)  verbosity, Bit #(64)  logdelay);

   // ----------------------------------------------------------------
   // Soft reset
   // 'Bool' is initial 'running' state

   interface Server #(Bool, Bool)  cpu_reset_server;

   // ----------------------------------------------------------------
   // AXI4 Fabric interfaces

   // CPU IMem to Fabric master interface
   interface AXI4_Master #(Wd_MId, Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)
      cpu_imem_master;

   // CPU DMem to Fabric master interface
   interface AXI4_Master #( Wd_MId_ext, Wd_Addr, Wd_Data
                          , Wd_AW_User_ext, Wd_W_User_ext, Wd_B_User_ext
                          , Wd_AR_User_ext, Wd_R_User_ext)
      cpu_dmem_master;

   // ----------------------------------------------------------------
   // Optional AXI4-Lite D-cache slave interface

`ifdef INCLUDE_DMEM_SLAVE
   interface AXI4Lite_Slave #(Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)
      cpu_dmem_slave;
`endif

   // ----------------------------------------------------------------
   // External interrupt sources

   interface Vector #(t_n_interrupt_sources, PLIC_Source_IFC)
      core_external_interrupt_sources;

   // ----------------------------------------------------------------
   // Non-maskable interrupt request

   (* always_ready, always_enabled *)
   method Action nmi_req (Bool set_not_clear);

   // ----------------------------------------------------------------
   // Optional Tandem Verifier interface output tuples (n,vb),
   // where 'vb' is a vector of bytes
   // with relevant bytes in locations [0]..[n-1]

`ifdef INCLUDE_TANDEM_VERIF
   interface Get #(Info_CPU_to_Verifier)  tv_verifier_info_get;
`elsif RVFI_DII
   interface Piccolo_RVFI_DII_Server rvfi_dii_server;
`endif

   // ----------------------------------------------------------------
   // Optional Debug Module interfaces

`ifdef INCLUDE_GDB_CONTROL
   // ----------------
   // DMI (Debug Module Interface) facing remote debugger

   interface DMI dm_dmi;

   // ----------------
   // Facing Platform
   // Non-Debug-Module Reset (reset all except DM)
   // Bool indicates 'running' hart state.

   interface Client #(Bool, Bool) ndm_reset_client;
`endif

`ifdef TAG_CACHE_EVENTS_EXTERNAL
   (* always_ready, always_enabled *)
   method Action send_tag_cache_master_events (Vector #(6, Bit #(1)) events);
`endif
endinterface

// ================================================================

// ================================================================
// The Synthesizable Core interface (same with Synth AXI)

interface Core_IFC_Synth #(numeric type t_n_interrupt_sources);
   method Action  set_verbosity (Bit #(4)  verbosity, Bit #(64)  logdelay);
   interface Server #(Bool, Bool)  cpu_reset_server;
   interface AXI4_Master_Sig #(Wd_MId, Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)
      cpu_imem_master;
   interface AXI4_Master_Sig #( Wd_MId_ext, Wd_Addr, Wd_Data
                                , Wd_AW_User_ext, Wd_W_User_ext, Wd_B_User_ext
                                , Wd_AR_User_ext, Wd_R_User_ext)
      cpu_dmem_master;
`ifdef INCLUDE_DMEM_SLAVE
   interface AXI4Lite_Slave_Synth #(Wd_Addr, Wd_Data, 0, 0, 0, 0, 0)
      cpu_dmem_slave;
`endif
   interface Vector #(t_n_interrupt_sources, PLIC_Source_IFC)
      core_external_interrupt_sources;
   (* always_ready, always_enabled *)
   method Action nmi_req (Bool set_not_clear);
`ifdef INCLUDE_TANDEM_VERIF
   interface Get #(Info_CPU_to_Verifier)  tv_verifier_info_get;
`elsif RVFI_DII
   interface Piccolo_RVFI_DII_Server rvfi_dii_server;
`endif
`ifdef INCLUDE_GDB_CONTROL
   interface DMI dm_dmi;
   interface Client #(Bool, Bool) ndm_reset_client;
`endif
`ifdef TAG_CACHE_EVENTS_EXTERNAL
   (* always_ready, always_enabled *)
   method Action send_tag_cache_master_events (Vector #(6, Bit #(1)) events);
`endif
endinterface

// ================================================================

endpackage
