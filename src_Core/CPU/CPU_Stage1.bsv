// Copyright (c) 2016-2019 Bluespec, Inc. All Rights Reserved

//-
// RVFI_DII + CHERI modifications:
//     Copyright (c) 2018 Jack Deeley (RVFI_DII)
//     Copyright (c) 2018-2019 Peter Rugg (RVFI_DII + CHERI)
//     All rights reserved.
//
//     This software was developed by SRI International and the University of
//     Cambridge Computer Laboratory (Department of Computer Science and
//     Technology) under DARPA contract HR0011-18-C-0016 ("ECATS"), as part of the
//     DARPA SSITH research programme.
//-

package CPU_Stage1;

// ================================================================
// This is Stage 1 of the "Piccolo" CPU.
// It contains the IF, RD, and EX functionality.
// IF: "Instruction Fetch".
// RD: "Register Read"
// EX: "Execute"

// ================================================================
// Exports

export
CPU_Stage1_IFC (..),
mkCPU_Stage1;

// ================================================================
// BSV library imports

import FIFOF        :: *;
import FIFO         :: *;
import SpecialFIFOs :: *;
import GetPut       :: *;
import ClientServer :: *;
import ConfigReg    :: *;

// ----------------
// BSV additional libs

import Cur_Cycle :: *;

// ================================================================
// Project imports

import ISA_Decls        :: *;
import CPU_Globals      :: *;
import Near_Mem_IFC     :: *;
import GPR_RegFile      :: *;
`ifdef ISA_F
import FPR_RegFile      :: *;
`endif
import CSR_RegFile      :: *;
import EX_ALU_functions :: *;
`ifdef ISA_CHERI
import CHERICap :: *;
import CHERICC_Fat :: *;
`endif

`ifdef ISA_C
// 'C' extension (16b compressed instructions)
import CPU_Decode_C     :: *;
`endif

// ================================================================
// Interface

interface ALU_IFC;
   method ALU_Outputs get(ALU_Inputs args);
endinterface

(* synthesize *)
module mkALU(ALU_IFC);
   method ALU_Outputs get(ALU_Inputs args);
       return fv_ALU(args);
   endmethod
endmodule

interface CPU_Stage1_IFC;
   // ---- Reset
   interface Server #(Token, Token) server_reset;

   // ---- Output
   (* always_ready *)
   method Output_Stage1 out;

   (* always_ready *)
   method Action deq;

   // ---- Input
   (* always_ready *)
   method Action enq (
`ifdef ISA_CHERI
                                                    PCC_T pcc
                                                  , CapPipe ddc
`else
                                                    Addr next_pc
`endif
                                                  , Priv_Mode priv
`ifdef RVFI_DII
                                                  , Dii_Id seq_req
`endif
                                                  , Bit #(1) sstatus_SUM, Bit #(1) mstatus_MXR, WordXL satp);

   (* always_ready *)
   method Action set_full (Bool full);
endinterface

// ================================================================
// Implementation module

module mkCPU_Stage1 #(Bit #(4)         verbosity,
		      GPR_RegFile_IFC  gpr_regfile,
		      Bypass           bypass_from_stage2,
		      Bypass           bypass_from_stage3,
`ifdef ISA_F
		      FPR_RegFile_IFC  fpr_regfile,
		      FBypass          fbypass_from_stage2,
		      FBypass          fbypass_from_stage3,
`endif
		      CSR_RegFile_IFC  csr_regfile,
		      IMem_IFC         imem,
		      Priv_Mode        cur_priv)
                    (CPU_Stage1_IFC);

   FIFOF #(Token) f_reset_reqs <- mkFIFOF;
   FIFOF #(Token) f_reset_rsps <- mkFIFOF;

   Reg #(Bool) rg_full  <- mkReg (False);

`ifdef ISA_CHERI
   Reg #(PCC_T) rg_pcc <- mkRegU;
   Reg #(Bit#(TAdd#(XLEN,1))) rg_pcc_top <- mkRegU;
   Reg #(CapPipe) rg_ddc <- mkRegU;
`endif


   MISA misa   = csr_regfile.read_misa;
   Bit #(2) xl = ((xlen == 32) ? misa_mxl_32 : misa_mxl_64);

   // ----------------------------------------------------------------
   // BEHAVIOR

   rule rl_reset;
      f_reset_reqs.deq;
      rg_full <= False;
      f_reset_rsps.enq (?);
   endrule

   // ----------------
   // ALU

   let alu <- mkALU();

`ifdef ISA_CHERI
   let   pc             = getPC(rg_pcc);
`else
   let   pc             = imem.pc;
`endif
   let   is_i32_not_i16 = imem.is_i32_not_i16;
`ifdef RVFI_DII
   Instr instr          = tpl_1(imem.instr);
`else
   Instr instr          = imem.instr;
`endif
   Instr instr_or_instr_C = instr;
`ifdef ISA_C
   Instr_C instr_C = instr [15:0];
   if (! is_i32_not_i16) begin
      instr = fv_decode_C (misa, xl, getFlags(rg_pcc) == 1, instr_C);
      instr_or_instr_C = zeroExtend(instr_C);
   end
`endif
   let decoded_instr  = fv_decode (instr);
   let funct3         = decoded_instr.funct3;

   // Register rs1 read and bypass
   let rs1 = decoded_instr.rs1;
   let rs1_val = gpr_regfile.read_rs1 (rs1);
   match { .busy1a, .rs1a } = fn_gpr_bypass (bypass_from_stage3, rs1, rs1_val);
   match { .busy1b, .rs1b } = fn_gpr_bypass (bypass_from_stage2, rs1, rs1a);
   Bool rs1_busy = (busy1a || busy1b);
`ifdef ISA_CHERI
   CapPipe rs1_val_bypassed = ((rs1 == 0) ? nullCap : rs1b);
`else
   Word rs1_val_bypassed = ((rs1 == 0) ? 0 : rs1b);
`endif


   // Register rs2 read and bypass
   let rs2 = decoded_instr.rs2;
   let rs2_val = gpr_regfile.read_rs2 (rs2);
   match { .busy2a, .rs2a } = fn_gpr_bypass (bypass_from_stage3, rs2, rs2_val);
   match { .busy2b, .rs2b } = fn_gpr_bypass (bypass_from_stage2, rs2, rs2a);
   Bool rs2_busy = (busy2a || busy2b);
`ifdef ISA_CHERI
   CapPipe rs2_val_bypassed = ((rs2 == 0) ? nullCap : rs2b);
`else
   Word rs2_val_bypassed = ((rs2 == 0) ? 0 : rs2b);
`endif

`ifdef ISA_F
   // FP Register rs1 read and bypass
   let frs1_val = fpr_regfile.read_rs1 (rs1);
   match { .fbusy1a, .frs1a } = fn_fpr_bypass (fbypass_from_stage3, rs1, frs1_val);
   match { .fbusy1b, .frs1b } = fn_fpr_bypass (fbypass_from_stage2, rs1, frs1a);
   Bool frs1_busy = (fbusy1a || fbusy1b);
   WordFL frs1_val_bypassed = frs1b;

   // FP Register rs2 read and bypass
   let frs2_val = fpr_regfile.read_rs2 (rs2);
   match { .fbusy2a, .frs2a } = fn_fpr_bypass (fbypass_from_stage3, rs2, frs2_val);
   match { .fbusy2b, .frs2b } = fn_fpr_bypass (fbypass_from_stage2, rs2, frs2a);
   Bool frs2_busy = (fbusy2a || fbusy2b);
   WordFL frs2_val_bypassed = frs2b;

   // FP Register rs3 read and bypass
   let rs3 = decoded_instr.rs3;
   let frs3_val = fpr_regfile.read_rs3 (rs3);
   match { .fbusy3a, .frs3a } = fn_fpr_bypass (fbypass_from_stage3, rs3, frs3_val);
   match { .fbusy3b, .frs3b } = fn_fpr_bypass (fbypass_from_stage2, rs3, frs3a);
   Bool frs3_busy = (fbusy3a || fbusy3b);
   WordFL frs3_val_bypassed = frs3b;
`endif

   // ALU function
   let alu_inputs = ALU_Inputs {
        cur_priv        : cur_priv
      , pc              : pc
`ifdef ISA_CHERI
      , pcc             : rg_pcc
      , ddc             : rg_ddc
`endif
      , is_i32_not_i16  : imem.is_i32_not_i16
      , instr           : instr
`ifdef ISA_C
      , instr_or_instr_C : instr_or_instr_C
`endif
      , decoded_instr   : decoded_instr
`ifdef ISA_CHERI
      , cap_rs1_val     : rs1_val_bypassed
      , cap_rs2_val     : rs2_val_bypassed
      , rs1_idx         : rs1
      , rs2_idx         : rs2
      , rs1_val         : getAddr(rs1_val_bypassed)
      , rs2_val         : getAddr(rs2_val_bypassed)
`else
      , rs1_val         : rs1_val_bypassed
      , rs2_val         : rs2_val_bypassed
`endif
`ifdef ISA_F
      , frs1_val       : frs1_val_bypassed
      , frs2_val       : frs2_val_bypassed
      , frs3_val       : frs3_val_bypassed
      , frm            : csr_regfile.read_frm
`ifdef INCLUDE_TANDEM_VERIF
                                fflags         : csr_regfile.read_fflags,
`endif
`endif
      , mstatus         : csr_regfile.read_mstatus
      , misa            : csr_regfile.read_misa };

   let alu_outputs = alu.get (alu_inputs);

   let fall_through_pc = pc + (imem.is_i32_not_i16 ? 4 : 2);

   let next_pc_local = ((alu_outputs.control == CONTROL_BRANCH)
		 ? alu_outputs.addr
		 : fall_through_pc);

   let next_pcc_local = ((alu_outputs.control == CONTROL_CAPBRANCH)
     ? alu_outputs.pcc
     : setPC(rg_pcc, next_pc_local).value); //TODO unrepresentable?
   let next_ddc_local = alu_outputs.ddc;

`ifdef RVFI
   CapReg tmp_val2 = cast(alu_outputs.cap_val2);
   CapMem cap_val2 = cast(tmp_val2);
   let info_RVFI = Data_RVFI_Stage1 {
                       instr:          instr_or_instr_C,
                       rs1_addr:       rs1,
                       rs2_addr:       rs2,
`ifdef ISA_CHERI
                       rs1_data:       getAddr(rs1_val_bypassed),
                       rs2_data:       getAddr(rs2_val_bypassed),
`else
                       rs1_data:       rs1_val_bypassed,
                       rs2_data:       rs2_val_bypassed,
`endif
                       pc_rdata:       getPC(rg_pcc),
                       pc_wdata:       getPC(next_pcc_local),
`ifdef ISA_F
                       mem_wdata:      alu_outputs.rs_frm_fpr ? alu_outputs.fval2 : truncate(cap_val2),
`else
                       mem_wdata:      truncate(cap_val2),
`endif
                       rd_addr:        alu_outputs.rd,
                       rd_alu:         (alu_outputs.op_stage2 == OP_Stage2_ALU),
                       rd_wdata_alu:   alu_outputs.val1,
                       mem_addr:       ((alu_outputs.op_stage2 == OP_Stage2_LD) || (alu_outputs.op_stage2 == OP_Stage2_ST)
`ifdef ISA_A
                                       || (alu_outputs.op_stage2 == OP_Stage2_AMO)
`endif
                                       ) ? alu_outputs.addr : 0
                   };
`endif

   let data_to_stage2 = Data_Stage1_to_Stage2 {
`ifdef ISA_CHERI
        pcc             : rg_pcc
      , ddc             : rg_ddc
`else
        pc              : pc
`endif
      , instr           : instr
`ifdef RVFI_DII
      , instr_seq       : tpl_2(imem.instr)
`endif
      , op_stage2       : alu_outputs.op_stage2
      , rd              : alu_outputs.rd
      , addr            : alu_outputs.addr
      , mem_width_code  : alu_outputs.mem_width_code
      , mem_unsigned    : alu_outputs.mem_unsigned
`ifdef ISA_CHERI
      , mem_allow_cap   : alu_outputs.mem_allow_cap
      , val1            : alu_outputs.val1_cap_not_int ? embed_cap(alu_outputs.cap_val1)
                                                       : embed_int(truncate(alu_outputs.val1))
      , val2            : alu_outputs.val2_cap_not_int ? embed_cap(alu_outputs.cap_val2)
                                                       : embed_int(truncate(alu_outputs.val2))
      , val1_fast       : alu_outputs.val1_fast
      , val2_fast       : alu_outputs.val2_fast
`ifdef ISA_CHERI
      , check_enable       : alu_outputs.check_enable
      , check_inclusive    : alu_outputs.check_inclusive
      , check_authority    : alu_outputs.check_authority
      , check_authority_idx : alu_outputs.check_authority_idx
      , check_address_low  : alu_outputs.check_address_low
      , check_address_high : alu_outputs.check_address_high
      , check_exact_enable : alu_outputs.check_exact_enable
      , check_exact_success: alu_outputs.check_exact_success
`ifdef PERFORMANCE_MONITORING
      , set_offset_in_bounds : alu_outputs.set_offset_in_bounds
`endif
`endif
`ifdef ISA_F
      , fval1         : alu_outputs.fval1
      , fval2         : alu_outputs.fval2
      , fval3         : alu_outputs.fval3
      , rd_in_fpr     : alu_outputs.rd_in_fpr
      , rs_frm_fpr    : alu_outputs.rs_frm_fpr
      , val1_frm_gpr  : alu_outputs.val1_frm_gpr
      , rounding_mode : alu_outputs.rm
`endif
`ifdef INCLUDE_TANDEM_VERIF
      , trace_data      : alu_outputs.trace_data
`endif
`ifdef RVFI
      , info_RVFI_s1    : info_RVFI
`endif
      , priv            : cur_priv };


`ifdef ISA_CHERI
   let fetch_exc = checkValid(rg_pcc, rg_pcc_top, imem.is_i32_not_i16);
`endif

   // ----------------
   // Combinational output function

   function Output_Stage1 fv_out;
      Output_Stage1 output_stage1 = ?;
      output_stage1.ostatus_fetch = OSTATUS_EMPTY;

      // This stage is empty
      if (! rg_full) begin
	 output_stage1.ostatus = OSTATUS_EMPTY;
      end

      // Stall if IMem not ready
      else if (! imem.valid) begin
	 output_stage1.ostatus = OSTATUS_BUSY;
	 output_stage1.ostatus_fetch = OSTATUS_BUSY;
      end

`ifdef ISA_CHERI
      else if (isValid(fetch_exc)) begin
	 output_stage1.ostatus   = OSTATUS_NONPIPE;
	 output_stage1.control   = CONTROL_TRAP;
	 output_stage1.trap_info = Trap_Info_Pipe {
					      exc_code: exc_code_CHERI,
                cheri_exc_code : fetch_exc.Valid,
                cheri_exc_reg : {1, scr_addr_PCC},
                epcc: rg_pcc,
                eddc: rg_ddc,
					      tval:     imem.tval};
	 output_stage1.data_to_stage2 = data_to_stage2;
      end
`endif

      // Stall if bypass pending for GPR rs1 or rs2
      else if (rs1_busy || rs2_busy) begin
	 output_stage1.ostatus = OSTATUS_BUSY;
      end

`ifdef ISA_F
      // Stall if bypass pending for FPR rs1, rs2 or rs3
      else if (frs1_busy || frs2_busy || frs3_busy) begin
	 output_stage1.ostatus = OSTATUS_BUSY;
      end
`endif

      // Trap on fetch-exception
      else if (imem.exc) begin
	 output_stage1.ostatus   = OSTATUS_NONPIPE;
	 output_stage1.control   = CONTROL_TRAP;
	 output_stage1.trap_info = Trap_Info_Pipe {
					      exc_code: imem.exc_code,
                cheri_exc_code : ?,
                cheri_exc_reg : ?,
                epcc: rg_pcc,
                eddc: rg_ddc,
					      tval:     imem.tval};
	 output_stage1.data_to_stage2 = data_to_stage2;
      end

      // ALU outputs: pipe (straight/branch)
      // and non-pipe (CSRR_W, CSRR_S_or_C, FENCE.I, FENCE, SFENCE_VMA, xRET, WFI, TRAP)
      else begin
	 let ostatus = (  (   (alu_outputs.control == CONTROL_STRAIGHT)
			   || (alu_outputs.control == CONTROL_BRANCH)
			   || (alu_outputs.control == CONTROL_CAPBRANCH))
			? OSTATUS_PIPE
			: OSTATUS_NONPIPE);

	 // Compute MTVAL in case of traps
	 let tval = 0;
	 if (alu_outputs.exc_code == exc_code_ILLEGAL_INSTRUCTION) begin
	    // The instruction
	    tval = zeroExtend(instr_or_instr_C);
	 end
	 else if (alu_outputs.exc_code == exc_code_INSTR_ADDR_MISALIGNED)
	    tval = alu_outputs.addr;                           // The branch target pc
	 else if (alu_outputs.exc_code == exc_code_BREAKPOINT)
	    tval = pc;                                         // The faulting virtual address

	 let trap_info = Trap_Info_Pipe {
				    exc_code: alu_outputs.exc_code,
`ifdef ISA_CHERI
            cheri_exc_code: alu_outputs.cheri_exc_code,
            cheri_exc_reg: alu_outputs.cheri_exc_reg,
            epcc: rg_pcc,
            eddc: rg_ddc,
`else
            epc:  pc,
`endif
				    tval: tval};

	 output_stage1.ostatus        = ostatus;
	 output_stage1.control        = alu_outputs.control;
	 output_stage1.trap_info      = trap_info;
`ifdef ISA_CHERI
   output_stage1.next_pcc       = next_pcc_local;
   output_stage1.next_ddc       = next_ddc_local;
`else
	 output_stage1.next_pc        = next_pc_local;
`endif
	 output_stage1.data_to_stage2 = data_to_stage2;

      end

      return output_stage1;
   endfunction: fv_out

   // ================================================================
   // INTERFACE

   // ---- Reset
   interface server_reset = toGPServer (f_reset_reqs, f_reset_rsps);

   // ---- Output
   method Output_Stage1 out;
      return fv_out;
   endmethod

   method Action deq ();
   endmethod

   // ---- Input
   method Action enq (
`ifdef ISA_CHERI
                                                    PCC_T next_pcc
                                                  , CapPipe next_ddc
`else
                                                    Addr next_pc
`endif
                                                  , Priv_Mode priv
`ifdef RVFI_DII
                                                  , Dii_Id seq_req
`endif
                                                  , Bit #(1) sstatus_SUM, Bit #(1) mstatus_MXR, WordXL satp);
      imem.req (f3_LW,
`ifdef ISA_CHERI
                      getAddr(next_pcc),
`else
                      next_pc,
`endif
                               priv, sstatus_SUM, mstatus_MXR, satp
`ifdef RVFI_DII
                                                                    , seq_req
`endif
                                                                             );

`ifdef ISA_CHERI
      rg_pcc <= next_pcc;
      rg_pcc_top <= getTop(next_pcc);
      rg_ddc <= next_ddc;
`endif

      if (verbosity > 1)
	 $display ("    CPU_Stage1.enq: 0x%08h",
`ifdef ISA_CHERI
                                          getPC(next_pcc)
`else
                                          next_pc
`endif
            );
   endmethod

   method Action set_full (Bool full);
      rg_full <= full;
   endmethod
endmodule

// ================================================================

endpackage
