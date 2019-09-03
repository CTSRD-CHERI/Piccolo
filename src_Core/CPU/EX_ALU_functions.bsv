// Copyright (c) 2016-2019 Bluespec, Inc. All Rights Reserved

//-
// RVFI_DII + CHERI modifications:
//     Copyright (c) 2018 Jack Deeley (RVFI_DII)
//     Copyright (c) 2018 Peter Rugg (RVFI_DII + CHERI)
//     All rights reserved.
//
//     This software was developed by SRI International and the University of
//     Cambridge Computer Laboratory (Department of Computer Science and
//     Technology) under DARPA contract HR0011-18-C-0016 ("ECATS"), as part of the
//     DARPA SSITH research programme.
//-

package EX_ALU_functions;

// ================================================================
// These are the "ALU" functions in the EX stage of the "Piccolo" CPU.
// EX stands for "Execution".

// ================================================================
// Exports

export
ALU_Inputs (..),
ALU_Outputs (..),
fv_ALU;

// ================================================================
// BSV library imports

import Vector :: *;

// ----------------
// BSV additional libs

// None

// ================================================================
// Project imports

import ISA_Decls   :: *;
import CPU_Globals :: *;
import TV_Info     :: *;
`ifdef ISA_CHERI
import CHERICap :: *;
import CHERICC_Fat :: *;
`endif

// ================================================================
// ALU inputs

typedef struct {
   Priv_Mode      cur_priv;
`ifdef ISA_CHERI
   CapPipe        pcc;
   CapPipe        ddc;
   Bit#(5)        rs1_idx;
   Bit#(5)        rs2_idx;
`endif
   Addr           pc;
   Bool           is_i32_not_i16;
   Instr          instr;
`ifdef ISA_C
   Instr_C        instr_C;
`endif
   Decoded_Instr  decoded_instr;
   WordXL         rs1_val;
   WordXL         rs2_val;
   WordXL         mstatus;
`ifdef ISA_F
   Bit #(3)       fcsr_frm;
   WordFL         frs1_val;
   WordFL         frs2_val;
   WordFL         frs3_val;
`endif
`ifdef ISA_CHERI
   CapPipe        cap_rs1_val;
   CapPipe        cap_rs2_val;
`endif
   MISA           misa;
   } ALU_Inputs
deriving (Bits, FShow);

// ----------------
// These functions pick the instruction size and instruction bits to
// be sent in the trace to a tandem verifier

function ISize  fv_trace_isize (ALU_Inputs  inputs);
   return (inputs.is_i32_not_i16 ? ISIZE32BIT : ISIZE16BIT);
endfunction

function Bit #(32)  fv_trace_instr (ALU_Inputs  inputs);
   Bit #(32) result = inputs.instr;
`ifdef ISA_C
   if (! inputs.is_i32_not_i16)
      result = zeroExtend (inputs.instr_C);
`endif
   return result;
endfunction

// ================================================================
// ALU outputs

typedef struct {
   Control    control;
   Exc_Code   exc_code;        // Relevant if control == CONTROL_TRAP
`ifdef ISA_CHERI
   CHERI_Exc_Code cheri_exc_code; //Relevant if control == CONTROL_TRAP && exc_code == exc_code_CHERI
   Bit#(6)        cheri_exc_reg;
`endif

   Op_Stage2  op_stage2;
   RegName    rd;
   Addr       addr;     // Branch, jump: newPC
		        // Mem ops and AMOs: mem addr

   Bit#(3) mem_width_code;
   Bool    mem_unsigned;

`ifdef ISA_CHERI
   Bool    mem_allow_cap; //Whether load/store is allowed to preserve cap tag

   CapPipe pcc;
   CapPipe ddc;

   Bool ddc_written;
`endif

`ifdef ISA_D
   WordFL     val1;     // OP_Stage2_FD: arg1
   WordFL     val2;     // OP_Stage2_FD: arg2
`else
   WordXL     val1;     // OP_Stage2_ALU: result for Rd (ALU ops: result, JAL/JALR: return PC)
                        // CSRRx: rs1_val
                        // OP_Stage2_M, OP_Stage2_FD: arg1
                        // OP_Stage2_AMO: funct7

   WordXL     val2;     // Branch: branch target (for Tandem Verification)
		        // OP_Stage2_ST: store-val
                        // OP_Stage2_M, OP_Stage2_FD: arg2
`endif
`ifdef ISA_F
   WordFL     val3;     // OP_Stage2_FD: arg3
   Bool       rd_in_fpr;// result to be written to fpr
   Bit #(3)   rm;       // rounding mode
`endif

`ifdef ISA_CHERI
   CapPipe    cap_val1;
   CapPipe    cap_val2;
   Bool       val1_cap_not_int;
   Bool       val2_cap_not_int;

   Bool                check_enable;
   CapPipe             check_authority;
   Bit #(6)            check_authority_idx;
   Bit#(XLEN)          check_address_low;
   Bit#(TAdd#(XLEN,1)) check_address_high;
   Bool                check_inclusive;
`endif

   Trace_Data trace_data;
   } ALU_Outputs
deriving (Bits, FShow);

ALU_Outputs alu_outputs_base
= ALU_Outputs {control   : CONTROL_STRAIGHT,
	       exc_code  : exc_code_ILLEGAL_INSTRUCTION,
`ifdef ISA_CHERI
         cheri_exc_code: exc_code_CHERI_None,
         cheri_exc_reg:  ?,
`endif
	       op_stage2 : ?,
	       rd        : ?,
	       addr      : ?,
	       val1      : ?,
	       val2      : ?,
`ifdef ISA_F
	       val3      : ?,
	       rd_in_fpr : False,
	       rm        : ?,
`endif
`ifdef ISA_CHERI
	       cap_val1  : ?,
	       cap_val2  : ?,
	       val1_cap_not_int: False,
	       val2_cap_not_int: False,

         pcc : ?,
         ddc : ?,

         ddc_written : False,

         check_enable       : False,
         check_authority    : ?,
         check_authority_idx : ?,
         check_address_low  : ?,
         check_address_high : ?,
         check_inclusive    : ?,

         mem_allow_cap      : False,
`endif

         mem_width_code     : ?,
         mem_unsigned       : False,

	       trace_data: ?};

// ================================================================
// The fall-through PC is PC+4 for normal 32b instructions,
// and PC+2 for 'C' (16b compressed) instructions.

function Addr fall_through_pc (ALU_Inputs  inputs);
   Addr next_pc = inputs.pc + 4;
`ifdef ISA_C
   if (! inputs.is_i32_not_i16)
      next_pc = inputs.pc + 2;
`endif
   return next_pc;
endfunction

// ================================================================
// Alternate implementation of shifts using multiplication in DSPs

// ----------------------------------------------------------------
/* TODO: DELETE? 'factor' RegFile for shift ops

// ----------------------------------------------------------------
// The following is a lookup table of multiplication factors used by the "shift" ops
RegFile #(Bit #(TLog #(XLEN)), Bit #(XLEN))  rf_sh_factors <- mkRegFileFull;
// The following is used during reset to initialize rf_sh_factors
Reg #(Bool)                                  rg_resetting  <- mkReg (False);
Reg #(Bit #(TAdd #(1, TLog #(XLEN))))        rg_j          <- mkRegU;
Reg #(WordXL)                                rg_factor     <- mkRegU;
*/

// ----------------------------------------------------------------
// The following functions implement the 'shift' operators SHL, SHRL and SHRA
// using multiplication instead of actual shifts,
// thus using DSPs (multiplication) and LUTRAMs (rf_sh_factors) instead of LUTs

// Shift-left
// Instead of '>>' operator, uses '*', using DSPs instead of LUTs.
// To SHL(n), do a multiplication by 2^n.
// The 2^n factor is looked up in a RegFile (used as a ROM), which uses a LUTRAM instead of LUTs
function WordXL fn_shl (WordXL x, Bit #(TLog #(XLEN)) shamt);
   IntXL  x_signed = unpack (x);

   // IntXL y_signed = unpack (rf_sh_factors.sub (shamt));
   IntXL  y_signed = unpack ('b1 << shamt);

   IntXL  z_signed = x_signed * y_signed;
   WordXL z        = pack (z_signed);
   return z;
endfunction

// Shift-right-arithmetic
// Instead of '>>' operator, uses '*', using DSPs instead of LUTs
// To SHR(n), do a 2*XLEN-wide multiplication by 2^(32-n), and take upper XLEN bits
// The 2^(32-n) factor is looked up in a RegFile (used as a ROM), which uses a LUTRAM instead of LUTs
function WordXL fn_shra (WordXL x, Bit #(TLog #(XLEN)) shamt);
   // Bit #(TAdd #(1, XLEN)) y = { reverseBits (rf_sh_factors.sub (shamt)), 1'b0 };
   Bit #(TAdd #(1, XLEN)) y = { reverseBits ('b1 << shamt), 1'b0 };

   Int #(XLEN_2) xx_signed = extend (unpack (x));
   Int #(XLEN_2) yy_signed = unpack (extend (y));
   Int #(XLEN_2) zz_signed = xx_signed * yy_signed;
   Bit #(XLEN_2) zz        = pack (zz_signed);
   WordXL        z         = truncateLSB (zz);
   return z;
endfunction

// Shift-right-logical
// Instead of '>>' operator, uses '*', using DSPs instead of LUTs
// To SHR(n), do a 2*XLEN-wide multiplication by 2^(32-n), and take upper XLEN bits
// The 2^(32-n) factor is looked up in a RegFile (used as a ROM), which uses a LUTRAM instead of LUTs
function WordXL fn_shrl (WordXL x, Bit #(TLog #(XLEN)) shamt);
   // Bit #(TAdd #(1, XLEN)) y = { reverseBits (rf_sh_factors.sub (shamt)), 1'b0 };
   Bit #(TAdd #(1, XLEN)) y = { reverseBits ('b1 << shamt), 1'b0 };

   Bit #(XLEN_2) xx = extend (x);
   Bit #(XLEN_2) yy = extend (y);
   Bit #(XLEN_2) zz = xx * yy;
   WordXL        z  = truncateLSB (zz);
   return z;
endfunction

// ================================================================
// BRANCH

function ALU_Outputs fv_BRANCH (ALU_Inputs inputs);
   let rs1_val = inputs.rs1_val;
   let rs2_val = inputs.rs2_val;

   // Signed versions of rs1_val and rs2_val
   IntXL s_rs1_val = unpack (inputs.rs1_val);
   IntXL s_rs2_val = unpack (inputs.rs2_val);

   IntXL offset        = extend (unpack (inputs.decoded_instr.imm13_SB));
   Addr  branch_target = pack (unpack (inputs.pc) + offset);
   Bool  branch_taken  = False;
   Bool  trap          = False;

   let funct3 = inputs.decoded_instr.funct3;
   if      (funct3 == f3_BEQ)  branch_taken = (rs1_val  == rs2_val);
   else if (funct3 == f3_BNE)  branch_taken = (rs1_val  != rs2_val);
   else if (funct3 == f3_BLT)  branch_taken = (s_rs1_val <  s_rs2_val);
   else if (funct3 == f3_BGE)  branch_taken = (s_rs1_val >= s_rs2_val);
   else if (funct3 == f3_BLTU) branch_taken = (rs1_val  <  rs2_val);
   else if (funct3 == f3_BGEU) branch_taken = (rs1_val  >= rs2_val);
   else                        trap = True;

   Bool misaligned_target = (branch_target [1] == 1'b1);
`ifdef ISA_C
   misaligned_target = False;
`endif

   Exc_Code exc_code = exc_code_ILLEGAL_INSTRUCTION;
   if ((! trap) && branch_taken && misaligned_target) begin
      trap = True;
      exc_code = exc_code_INSTR_ADDR_MISALIGNED;
   end

   let alu_outputs = alu_outputs_base;
   let next_pc     = (branch_taken ? branch_target : fall_through_pc (inputs));
   alu_outputs.control   = (trap ? CONTROL_TRAP : (branch_taken ? CONTROL_BRANCH : CONTROL_STRAIGHT));
   alu_outputs.exc_code  = exc_code;
   alu_outputs.op_stage2 = OP_Stage2_ALU;
   alu_outputs.rd        = 0;
   // Gives a defined value when in verification mode.
   `ifdef RVFI
   alu_outputs.val1      = 0;
   `endif
   alu_outputs.addr      = next_pc;
`ifdef ISA_D
   // TODO: is this ifdef needed? Can't we always use 'extend()'?
   alu_outputs.val2      = extend (branch_target);    // For tandem verifier only
`else
   alu_outputs.val2      = branch_target;    // For tandem verifier only
`endif

`ifdef ISA_CHERI
   alu_outputs = checkValidJump(alu_outputs, branch_taken, inputs.pcc, {1,scr_addr_PCC}, getBase(inputs.pcc) + next_pc);
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_OTHER (next_pc,
					   fv_trace_isize (inputs),
					   fv_trace_instr (inputs));
   return alu_outputs;
endfunction

// ----------------------------------------------------------------
// JAL

function ALU_Outputs fv_JAL (ALU_Inputs inputs);
   IntXL offset  = extend (unpack (inputs.decoded_instr.imm21_UJ));
   Addr  next_pc = pack (unpack (inputs.pc) + offset);
   Addr  ret_pc  = fall_through_pc (inputs);

   Bool misaligned_target = (next_pc [1] == 1'b1);
`ifdef ISA_C
   misaligned_target = False;
`endif

   let alu_outputs = alu_outputs_base;
   alu_outputs.control   = (misaligned_target ? CONTROL_TRAP : CONTROL_BRANCH);
   alu_outputs.exc_code  = exc_code_INSTR_ADDR_MISALIGNED;
   alu_outputs.op_stage2 = OP_Stage2_ALU;
   alu_outputs.rd        = inputs.decoded_instr.rd;
   alu_outputs.addr      = next_pc;
`ifdef ISA_D
   alu_outputs.val1      = extend (ret_pc);
`else
   alu_outputs.val1      = ret_pc;
`endif

`ifdef ISA_CHERI
   alu_outputs = checkValidJump(alu_outputs, True, inputs.pcc, {1,scr_addr_PCC}, getBase(inputs.pcc) + next_pc);
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_I_RD (next_pc,
					  fv_trace_isize (inputs),
					  fv_trace_instr (inputs),
					  inputs.decoded_instr.rd,
					  ret_pc);
   return alu_outputs;
endfunction

// ----------------------------------------------------------------
// JALR

function ALU_Outputs fv_JALR (ALU_Inputs inputs);
   let rs1_val = inputs.rs1_val;
   let rs2_val = inputs.rs2_val;

   // Signed versions of rs1_val and rs2_val
   IntXL s_rs1_val = unpack (rs1_val);
   IntXL s_rs2_val = unpack (rs2_val);
   IntXL offset    = extend (unpack (inputs.decoded_instr.imm12_I));
   Addr  next_pc   = pack (s_rs1_val + offset);
   Addr  ret_pc    = fall_through_pc (inputs);

   // next_pc [0] should be cleared
   next_pc [0] = 1'b0;

   Bool misaligned_target = (next_pc [1] == 1'b1);
`ifdef ISA_C
   misaligned_target = False;
`endif

   let alu_outputs = alu_outputs_base;
   alu_outputs.control   = (misaligned_target ? CONTROL_TRAP : CONTROL_BRANCH);
   alu_outputs.exc_code  = exc_code_INSTR_ADDR_MISALIGNED;
   alu_outputs.op_stage2 = OP_Stage2_ALU;
   alu_outputs.rd        = inputs.decoded_instr.rd;
   alu_outputs.addr      = next_pc;
`ifdef ISA_D
   alu_outputs.val1      = extend (ret_pc);
`else
   alu_outputs.val1      = ret_pc;
`endif

`ifdef ISA_CHERI
   alu_outputs = checkValidJump(alu_outputs, True, inputs.pcc, {1,scr_addr_PCC}, getBase(inputs.pcc) + next_pc);
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_I_RD (next_pc,
					  fv_trace_isize (inputs),
					  fv_trace_instr (inputs),
					  inputs.decoded_instr.rd,
					  ret_pc);
   return alu_outputs;
endfunction

// ----------------------------------------------------------------
// Integer Register-Register and Register-Immediate Instructions

// ----------------
// Shifts (funct3 == f3_SLLI/ f3_SRLI/ f3_SRAI)

function ALU_Outputs fv_OP_and_OP_IMM_shifts (ALU_Inputs inputs);
   let rs1_val = inputs.rs1_val;
   let rs2_val = inputs.rs2_val;

   IntXL s_rs1_val = unpack (rs1_val);    // Signed version of rs1, for SRA

   Bit #(TLog #(XLEN)) shamt = (  (inputs.decoded_instr.opcode == op_OP_IMM)
				? truncate (inputs.decoded_instr.imm12_I)
				: truncate (rs2_val));
   WordXL   rd_val    = ?;
   let      funct3    = inputs.decoded_instr.funct3;
   Bit #(1) instr_b30 = inputs.instr [30];

`ifdef SHIFT_BARREL
   // Shifts implemented by Verilog synthesis,
   // mapping to barrel shifters
   if (funct3 == f3_SLLI)
      rd_val = (rs1_val << shamt);
   else begin // assert: (funct3 == f3_SRxI)
      if (instr_b30 == 1'b0)
	 // SRL/SRLI
	 rd_val = (rs1_val >> shamt);
      else
	 // SRA/SRAI
	 rd_val = pack (s_rs1_val >> shamt);
   end
`endif

`ifdef SHIFT_MULT
   // Shifts implemented using multiplication by 2^shamt,
   // mapping to DSPs in FPGA
   if (funct3 == f3_SLLI)
      rd_val = fn_shl (rs1_val, shamt);  // in LUTRAMs/DSPs
   else begin // assert: (funct3 == f3_SRxI)
      if (instr_b30 == 1'b0) begin
	 // SRL/SRLI
	 rd_val = fn_shrl (rs1_val, shamt);  // in LUTRAMs/DSPs
      else
	 // SRA/SRAI
	 rd_val = fn_shra (rs1_val, shamt);     // in LUTRAMs/DSPs
   end
`endif

   // Trap in RV32 if shamt > 31, i.e., if imm12_I [5] is 1
   Bool trap = ((rv_version == RV32) && (inputs.decoded_instr.imm12_I [5] == 1));

   let alu_outputs       = alu_outputs_base;
   alu_outputs.control   = (trap ? CONTROL_TRAP : CONTROL_STRAIGHT);
   alu_outputs.rd        = inputs.decoded_instr.rd;

`ifndef SHIFT_SERIAL
   alu_outputs.op_stage2 = OP_Stage2_ALU;
`ifdef ISA_D
   alu_outputs.val1      = extend (rd_val);
`else
   alu_outputs.val1      = rd_val;
`endif
`else
   // Will be executed in serial Shifter_Box later
   alu_outputs.op_stage2 = OP_Stage2_SH;
   alu_outputs.val1      = rs1_val;
   // Encode 'arith-shift' in bit [7] of val2
`ifdef ISA_D
   WordFL val2 = extend (shamt);
`else
   WordXL val2 = extend (shamt);
`endif
   val2 = (val2 | { 0, instr_b30, 7'b0});
   alu_outputs.val2 = val2;
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_I_RD (fall_through_pc (inputs),
					  fv_trace_isize (inputs),
					  fv_trace_instr (inputs),
					  inputs.decoded_instr.rd,
					  rd_val);
   return alu_outputs;
endfunction: fv_OP_and_OP_IMM_shifts

// ----------------
// Remaining OP and OP_IMM (excluding shifts, M ops MUL/DIV/REM)

function ALU_Outputs fv_OP_and_OP_IMM (ALU_Inputs inputs);
   let rs1_val = inputs.rs1_val;
   let rs2_val = inputs.rs2_val;

   // Signed versions of rs1_val and rs2_val
   IntXL  s_rs1_val = unpack (rs1_val);
   IntXL  s_rs2_val = unpack (rs2_val);

   IntXL  s_rs2_val_local = s_rs2_val;
   WordXL rs2_val_local   = rs2_val;

   Bit #(1) instr_b30  = inputs.instr [30];
   Bool     subtract   = ((inputs.decoded_instr.opcode == op_OP) && (instr_b30 == 1'b1));

   if (inputs.decoded_instr.opcode == op_OP_IMM) begin
      s_rs2_val_local = extend (unpack (inputs.decoded_instr.imm12_I));
      rs2_val_local   = pack (s_rs2_val_local);
   end

   let  funct3 = inputs.decoded_instr.funct3;
   Bool trap   = False;
   WordXL rd_val = ?;

   if      ((funct3 == f3_ADDI) && (! subtract)) rd_val = pack (s_rs1_val + s_rs2_val_local);
   else if ((funct3 == f3_ADDI) && (subtract))   rd_val = pack (s_rs1_val - s_rs2_val_local);

   else if (funct3 == f3_SLTI)  rd_val = ((s_rs1_val < s_rs2_val_local) ? 1 : 0);
   else if (funct3 == f3_SLTIU) rd_val = ((rs1_val  < rs2_val_local)  ? 1 : 0);
   else if (funct3 == f3_XORI)  rd_val = pack (s_rs1_val ^ s_rs2_val_local);
   else if (funct3 == f3_ORI)   rd_val = pack (s_rs1_val | s_rs2_val_local);
   else if (funct3 == f3_ANDI)  rd_val = pack (s_rs1_val & s_rs2_val_local);
   else
      trap = True;

   let alu_outputs       = alu_outputs_base;
   alu_outputs.control   = (trap ? CONTROL_TRAP : CONTROL_STRAIGHT);
   alu_outputs.op_stage2 = OP_Stage2_ALU;
   alu_outputs.rd        = inputs.decoded_instr.rd;
`ifdef ISA_D
   alu_outputs.val1      = extend (rd_val);
`else
   alu_outputs.val1      = rd_val;
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_I_RD (fall_through_pc (inputs),
					  fv_trace_isize (inputs),
					  fv_trace_instr (inputs),
					  inputs.decoded_instr.rd,
					  rd_val);
   return alu_outputs;
endfunction: fv_OP_and_OP_IMM

// ----------------
// OP_IMM_32 (ADDIW, SLLIW, SRxIW)

function ALU_Outputs fv_OP_IMM_32 (ALU_Inputs inputs);
   WordXL   rs1_val     = inputs.rs1_val;
   IntXL    s_rs1_val   = unpack (rs1_val);

   Bit #(5) shamt       = truncate (inputs.decoded_instr.imm12_I);
   Bool     shamt5_is_0 = (inputs.instr [25] == 1'b0);

   let    funct3 = inputs.decoded_instr.funct3;
   Bool   trap   = False;
   WordXL rd_val = ?;

   if (funct3 == f3_ADDIW) begin
      IntXL  s_rs2_val = extend (unpack (inputs.decoded_instr.imm12_I));
      IntXL  sum       = s_rs1_val + s_rs2_val;
      WordXL tmp       = pack (sum);
      rd_val           = signExtend (tmp [31:0]);
   end
   else if ((funct3 == f3_SLLIW) && shamt5_is_0) begin
      Bit #(32) tmp = truncate (rs1_val);
      rd_val = signExtend (tmp << shamt);
   end
   else if ((funct3 == f3_SRxIW) && shamt5_is_0) begin
      Bit #(1) instr_b30 = inputs.instr [30];
      if (instr_b30 == 1'b0) begin
	 // SRLIW
	 Bit #(32) tmp = truncate (rs1_val);
	 rd_val = signExtend (tmp >> shamt);
      end
      else begin
	 // SRAIW
	 Int #(32) s_tmp = unpack (rs1_val [31:0]);
	 Bit #(32) tmp   = pack (s_tmp >> shamt);
	 rd_val = signExtend (tmp);
      end
   end
   else
      trap = True;

   let alu_outputs       = alu_outputs_base;
   alu_outputs.control   = (trap ? CONTROL_TRAP : CONTROL_STRAIGHT);
   alu_outputs.op_stage2 = OP_Stage2_ALU;
   alu_outputs.rd        = inputs.decoded_instr.rd;
`ifdef ISA_D
   alu_outputs.val1      = extend (rd_val);
`else
   alu_outputs.val1      = rd_val;
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_I_RD (fall_through_pc (inputs),
					  fv_trace_isize (inputs),
					  fv_trace_instr (inputs),
					  inputs.decoded_instr.rd,
					  rd_val);
   return alu_outputs;
endfunction: fv_OP_IMM_32

// ----------------
// OP_32 (excluding 'M' ops: MULW/ DIVW/ DIVUW/ REMW/ REMUW)

function ALU_Outputs fv_OP_32 (ALU_Inputs inputs);
   Bit #(32) rs1_val = inputs.rs1_val [31:0];
   Bit #(32) rs2_val = inputs.rs2_val [31:0];

   // Signed version of rs1_val and rs2_val
   Int #(32) s_rs1_val = unpack (rs1_val);
   Int #(32) s_rs2_val = unpack (rs2_val);

   let    funct10 = inputs.decoded_instr.funct10;
   Bool   trap   = False;
   WordXL rd_val = ?;

   if      (funct10 == f10_ADDW) begin
      rd_val = pack (signExtend (s_rs1_val + s_rs2_val));
   end
   else if (funct10 == f10_SUBW) begin
      rd_val = pack (signExtend (s_rs1_val - s_rs2_val));
   end
   else if (funct10 == f10_SLLW) begin
      rd_val = pack (signExtend (rs1_val << (rs2_val [4:0])));
   end
   else if (funct10 == f10_SRLW) begin
      rd_val = pack (signExtend (rs1_val >> (rs2_val [4:0])));
   end
   else if (funct10 == f10_SRAW) begin
      rd_val = pack (signExtend (s_rs1_val >> (rs2_val [4:0])));
   end
   else
      trap = True;

   let alu_outputs       = alu_outputs_base;
   alu_outputs.control   = (trap ? CONTROL_TRAP : CONTROL_STRAIGHT);
   alu_outputs.op_stage2 = OP_Stage2_ALU;
   alu_outputs.rd        = inputs.decoded_instr.rd;
`ifdef ISA_D
   alu_outputs.val1      = extend (rd_val);
`else
   alu_outputs.val1      = rd_val;
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_I_RD (fall_through_pc (inputs),
					  fv_trace_isize (inputs),
					  fv_trace_instr (inputs),
					  inputs.decoded_instr.rd,
					  rd_val);
   return alu_outputs;
endfunction: fv_OP_32

// ----------------------------------------------------------------
// Upper Immediates

function ALU_Outputs fv_LUI (ALU_Inputs inputs);
   Bit #(32)  v32    = { inputs.decoded_instr.imm20_U, 12'h0 };
   IntXL      iv     = extend (unpack (v32));
   let        rd_val = pack (iv);

   let alu_outputs       = alu_outputs_base;
   alu_outputs.op_stage2 = OP_Stage2_ALU;
   alu_outputs.rd        = inputs.decoded_instr.rd;
`ifdef ISA_D
   alu_outputs.val1      = extend (rd_val);
`else
   alu_outputs.val1      = rd_val;
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_I_RD (fall_through_pc (inputs),
					  fv_trace_isize (inputs),
					  fv_trace_instr (inputs),
					  inputs.decoded_instr.rd,
					  rd_val);
   return alu_outputs;
endfunction

function ALU_Outputs fv_AUIPC (ALU_Inputs inputs);
   IntXL  iv     = extend (unpack ({ inputs.decoded_instr.imm20_U, 12'b0}));
   IntXL  pc_s   = unpack (inputs.pc);
   WordXL rd_val = pack (pc_s + iv);

   let alu_outputs       = alu_outputs_base;
   alu_outputs.op_stage2 = OP_Stage2_ALU;
   alu_outputs.rd        = inputs.decoded_instr.rd;
`ifdef ISA_D
   alu_outputs.val1      = extend (rd_val);
`else
`ifdef ISA_CHERI
   if (getFlags(inputs.pcc)[0] == 1'b1) begin
       let result = setOffset(inputs.pcc, rd_val); //TODO Factor this out.
       alu_outputs.cap_val1 = result.value;
       alu_outputs.val1 = getAddr(result.value);
       alu_outputs.val1_cap_not_int = result.exact;
   end else
`endif
   begin
       alu_outputs.val1      = rd_val;
   end
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_I_RD (fall_through_pc (inputs),
					  fv_trace_isize (inputs),
					  fv_trace_instr (inputs),
					  inputs.decoded_instr.rd,
					  rd_val);
   return alu_outputs;
endfunction

// ----------------------------------------------------------------
// LOAD

function ALU_Outputs fv_LD (ALU_Inputs inputs, Maybe#(Bit#(3)) size);
   // Signed versions of rs1_val and rs2_val
   let opcode = inputs.decoded_instr.opcode;
   IntXL s_rs1_val = unpack (inputs.rs1_val);
   IntXL s_rs2_val = unpack (inputs.rs2_val);

   IntXL  imm_s = extend (unpack (inputs.decoded_instr.imm12_I));
`ifdef ISA_CHERI
   if (valueOf(XLEN) == 32 && inputs.decoded_instr.funct3 == f3_LD) size = Valid(w_SIZE_D);

   let authority = getFlags(inputs.pcc)[0] == 1'b0 ? inputs.ddc : inputs.cap_rs1_val;
   let authorityIdx = getFlags(inputs.pcc)[0] == 1'b0 ? {1,scr_addr_PCC} : {0,inputs.rs1_idx};
   WordXL eaddr = getFlags(inputs.pcc)[0] == 1'b0 ? getAddr(inputs.ddc) + inputs.rs1_val + pack(imm_s) : getAddr(inputs.cap_rs1_val) + pack(imm_s); //TODO DDC base should be cached
`else
   WordXL eaddr = pack (s_rs1_val + imm_s);
`endif

   let funct3 = inputs.decoded_instr.funct3;

   Bool legal_LD = (
           isValid(size)
        || (funct3 == f3_LB) || (funct3 == f3_LBU)
		    || (funct3 == f3_LH) || (funct3 == f3_LHU)
		    || (funct3 == f3_LW)
`ifdef RV64
		    || (funct3 == f3_LWU)
		    || (funct3 == f3_LD)
`endif
`ifdef ISA_F
		    || (funct3 == f3_FLW)
`endif
`ifdef ISA_D
		    || (funct3 == f3_FLD)
`endif
		    );

   Bool legal_FP_LD = True;
`ifdef ISA_F
   if (opcode == op_LOAD_FP)
      legal_FP_LD = (fv_mstatus_fs (inputs.mstatus) != fs_xs_off);
`endif

   let alu_outputs = alu_outputs_base;

   let width_code = fromMaybe({0,funct3[1:0]}, size);

   alu_outputs.control   = ((legal_LD && legal_FP_LD) ? CONTROL_STRAIGHT
                                                      : CONTROL_TRAP);
   alu_outputs.op_stage2 = OP_Stage2_LD;
   alu_outputs.rd        = inputs.decoded_instr.rd;
   alu_outputs.addr      = eaddr;
   alu_outputs.mem_width_code = width_code;
   alu_outputs.mem_unsigned = unpack(funct3[2]);
`ifdef ISA_F
   alu_outputs.rd_in_fpr = (opcode == op_LOAD_FP);
`endif

`ifdef ISA_CHERI
   alu_outputs = checkValidDereference(alu_outputs, authority, authorityIdx, eaddr, width_code, False, ?);
`endif

   // Normal trace output (if no trap)
`ifdef ISA_F
   if (alu_outputs.rd_in_fpr)
      alu_outputs.trace_data = mkTrace_F_LOAD (fall_through_pc (inputs),
					       fv_trace_isize (inputs),
					       fv_trace_instr (inputs),
					       inputs.decoded_instr.rd,
					       ?,
					       eaddr);
   else
`endif
      alu_outputs.trace_data = mkTrace_I_LOAD (fall_through_pc (inputs),
					       fv_trace_isize (inputs),
					       fv_trace_instr (inputs),
					       inputs.decoded_instr.rd,
					       ?,
					       eaddr);
   return alu_outputs;
endfunction

// ----------------------------------------------------------------
// STORE

function ALU_Outputs fv_ST (ALU_Inputs inputs);
   // Signed version of rs1_val
   IntXL  s_rs1_val = unpack (inputs.rs1_val);
   IntXL  imm_s     = extend (unpack (inputs.decoded_instr.imm12_S));
`ifdef ISA_CHERI
   let authority = getFlags(inputs.pcc)[0] == 1'b0 ? inputs.ddc : inputs.cap_rs1_val;
   let authorityIdx = getFlags(inputs.pcc)[0] == 1'b0 ? {1,scr_addr_PCC} : {0,inputs.rs1_idx};
   WordXL eaddr = getFlags(inputs.pcc)[0] == 1'b0 ? getAddr(inputs.ddc) + inputs.rs1_val + pack(imm_s) : getAddr(inputs.cap_rs1_val) + pack(imm_s); //TODO DDC base should be cached
`else
   WordXL eaddr = pack (s_rs1_val + imm_s);
`endif

   let opcode = inputs.decoded_instr.opcode;
   let funct3 = inputs.decoded_instr.funct3;
   Bool legal_ST = (   (funct3 == f3_SB)
		    || (funct3 == f3_SH)
		    || (funct3 == f3_SW)
`ifdef ISA_CHERI
`ifdef RV64
        || (funct3 == f3_SQ)
`else
        || (funct3 == f3_SD)
`endif
`endif
`ifdef RV64
		    || (funct3 == f3_SD)
`endif
`ifdef ISA_F
		    || (funct3 == f3_FSW)
`endif
`ifdef ISA_D
		    || (funct3 == f3_FSD)
`endif
		    );

   Bool legal_FP_ST = True;
`ifdef ISA_F
   if (opcode == op_STORE_FP)
      legal_FP_ST = (fv_mstatus_fs (inputs.mstatus) != fs_xs_off);
`endif

   let alu_outputs = alu_outputs_base;

   let width_code = funct3;

   alu_outputs.control   = ((legal_ST && legal_FP_ST) ? CONTROL_STRAIGHT
                                                      : CONTROL_TRAP);
   alu_outputs.op_stage2 = OP_Stage2_ST;
   alu_outputs.addr      = eaddr;
   alu_outputs.mem_width_code = width_code;
   alu_outputs.mem_unsigned = False;

`ifdef ISA_CHERI
   alu_outputs = checkValidDereference(alu_outputs, authority, authorityIdx, eaddr, width_code, True, inputs.cap_rs2_val);
`endif

   // The rs2_val would depend on the combination F/D-RV32/64 when FD is enabled
`ifdef ISA_F
`ifdef ISA_D
`ifdef RV64
   alu_outputs.val2      = (opcode == op_STORE_FP) ? inputs.frs2_val
                                                   : inputs.rs2_val;
`else
   alu_outputs.val2      = (opcode == op_STORE_FP) ? inputs.frs2_val
                                                   : extend (inputs.rs2_val);
`endif
`else
`ifdef RV32
   alu_outputs.val2      = (opcode == op_STORE_FP) ? inputs.frs2_val
                                                   : inputs.rs2_val;
`else
   alu_outputs.val2      = (opcode == op_STORE_FP) ? extend (inputs.frs2_val)
                                                   : inputs.rs2_val;
`endif
`endif
`else
`ifdef ISA_CHERI
   alu_outputs.cap_val2      = inputs.cap_rs2_val;
   alu_outputs.val2_cap_not_int = width_code == w_SIZE_CAP;
`else
   alu_outputs.val2      = inputs.rs2_val;
`endif
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_STORE (fall_through_pc (inputs),
					   fv_trace_isize (inputs),
					   fv_trace_instr (inputs),
                                           // XXX TODO Revisit. Need to size
                                           // appropriately for FP
`ifdef ISA_D
					   truncate(alu_outputs.val2),
`else
					   (alu_outputs.val2),
`endif
					   eaddr);
   return alu_outputs;
endfunction

// ----------------------------------------------------------------
// MISC_MEM (FENCE and FENCE.I)
// No-ops, for now

function ALU_Outputs fv_MISC_MEM (ALU_Inputs inputs);
`ifdef ISA_CHERI
   if (valueOf(XLEN) == 64 && inputs.decoded_instr.funct3 == f3_LQ) begin
       return fv_LD(inputs, Valid(w_SIZE_Q));
   end else
`endif
   begin
       let alu_outputs = alu_outputs_base;
       alu_outputs.control  = (  (inputs.decoded_instr.funct3 == f3_FENCE_I)
			       ? CONTROL_FENCE_I
			       : (  (inputs.decoded_instr.funct3 == f3_FENCE)
			          ? CONTROL_FENCE
			          : CONTROL_TRAP));

       // Normal trace output (if no trap)
       alu_outputs.trace_data = mkTrace_OTHER (fall_through_pc (inputs),
					       fv_trace_isize (inputs),
					       fv_trace_instr (inputs));
       return alu_outputs;
   end
endfunction

// ----------------------------------------------------------------
// System instructions

function ALU_Outputs fv_SYSTEM (ALU_Inputs inputs);
   let funct3      = inputs.decoded_instr.funct3;
   let alu_outputs = alu_outputs_base;

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_OTHER (fall_through_pc (inputs),
					   fv_trace_isize (inputs),
					   fv_trace_instr (inputs));

   if (funct3  == f3_PRIV) begin
`ifdef ISA_PRIV_S
      // SFENCE.VMA instruction
      if (   (inputs.decoded_instr.rd  == 0)
	  && (   (inputs.cur_priv == m_Priv_Mode)
	      || (   (inputs.cur_priv == s_Priv_Mode)
		  && (inputs.mstatus [mstatus_tvm_bitpos] == 0)))
	  && (inputs.decoded_instr.funct7 == f7_SFENCE_VMA))
	 begin
	    alu_outputs.control = CONTROL_SFENCE_VMA;
	 end
      else
`endif
      if (   (inputs.decoded_instr.rd  == 0)
	  && (inputs.decoded_instr.rs1 == 0))
	 begin
	    // ECALL instructions
	    if (inputs.decoded_instr.imm12_I == f12_ECALL) begin
	       alu_outputs.control  = CONTROL_TRAP;
	       alu_outputs.exc_code = ((inputs.cur_priv == u_Priv_Mode)
				       ? exc_code_ECALL_FROM_U
				       : ((inputs.cur_priv == s_Priv_Mode)
					  ? exc_code_ECALL_FROM_S
					  : exc_code_ECALL_FROM_M));
	    end

	    // EBREAK instruction
	    else if (inputs.decoded_instr.imm12_I == f12_EBREAK) begin
	       alu_outputs.control  = CONTROL_TRAP;
	       alu_outputs.exc_code = exc_code_BREAKPOINT;
	    end

	    // MRET instruction
	    else if (   (inputs.cur_priv >= m_Priv_Mode)
		     && (inputs.decoded_instr.imm12_I == f12_MRET)
`ifdef ISA_CHERI
         && getHardPerms(inputs.pcc).accessSysRegs
`endif
                                               )
	       begin
		  alu_outputs.control = CONTROL_MRET;
	       end

	    // SRET instruction
	    else if (   (   (inputs.cur_priv == m_Priv_Mode)
			 || (   (inputs.cur_priv == s_Priv_Mode)
			     && (inputs.mstatus [mstatus_tsr_bitpos] == 0)))
		     && (inputs.decoded_instr.imm12_I == f12_SRET))
	       begin
		  alu_outputs.control = CONTROL_SRET;
	       end


	    /*
	    // URET instruction (future: Piccolo does not support 'N' extension)
	    else if (   (inputs.cur_priv >= u_Priv_Mode)
		     && (inputs.decoded_instr.imm12_I == f12_URET))
	       begin
		  alu_outputs.control = CONTROL_URET;
	       end
	    */

	    // WFI instruction
	    else if (   (   (inputs.cur_priv == m_Priv_Mode)
			 || (   (inputs.cur_priv == s_Priv_Mode)
			     && (inputs.mstatus [mstatus_tw_bitpos] == 0))
			 || (   (inputs.cur_priv == u_Priv_Mode)
			     && (inputs.misa.n == 1)))
		     && (inputs.decoded_instr.imm12_I == f12_WFI))
	       begin
		  alu_outputs.control = CONTROL_WFI;
	       end

	    else begin
	       alu_outputs.control = CONTROL_TRAP;
	    end
	 end

      else begin
	 alu_outputs.control = CONTROL_TRAP;
      end
   end    // funct3 is f3_PRIV

   // CSRRW, CSRRWI
   else if (f3_is_CSRR_W (funct3)) begin
      WordXL rs1_val = (  (funct3 [2] == 1)
			? extend (inputs.decoded_instr.rs1)    // Immediate zimm
			: inputs.rs1_val);                     // From rs1 reg

      alu_outputs.control   = CONTROL_CSRR_W;
`ifdef ISA_D
      alu_outputs.val1      = extend (rs1_val);
`else
      alu_outputs.val1      = rs1_val;
`endif
   end

   // CSRRS, CSRRSI, CSRRC, CSRRCI
   else if (f3_is_CSRR_S_or_C (funct3)) begin
      WordXL rs1_val = (  (funct3 [2] == 1)
			? extend (inputs.decoded_instr.rs1)    // Immediate zimm
			: inputs.rs1_val);                     // From rs1 reg

      alu_outputs.control   = CONTROL_CSRR_S_or_C;
`ifdef ISA_D
      alu_outputs.val1      = extend (rs1_val);
`else
      alu_outputs.val1      = rs1_val;
`endif
   end

   // funct3 is not f3_PRIV
   else begin // (funct3 == f3_SYSTEM_ILLEGAL)
      alu_outputs.control = CONTROL_TRAP;
   end

   return alu_outputs;
endfunction: fv_SYSTEM

// ----------------------------------------------------------------
// FP Ops
// Just pass through to the FP stage

`ifdef ISA_F
function ALU_Outputs fv_FP (ALU_Inputs inputs);
   let opcode = inputs.decoded_instr.opcode;
   let funct3 = inputs.decoded_instr.funct3;
   let funct7 = inputs.decoded_instr.funct7;
   let rs2    = inputs.decoded_instr.rs2;

   // Check instruction legality
   // Is the rounding mode legal
   match {.rm, .rm_is_legal} = fv_rmode_check  (funct3, inputs.fcsr_frm);

   // Is the instruction legal -- if MSTATUS.FS = fs_xs_off, FP instructions
   // are always illegal
   let inst_is_legal = (  (fv_mstatus_fs (inputs.mstatus) == fs_xs_off)
			? False
			: fv_is_fp_instr_legal (funct7,
						rm,
						rs2,
						opcode));

   let alu_outputs = alu_outputs_base;
   alu_outputs.control   = ((inst_is_legal && rm_is_legal)  ? CONTROL_STRAIGHT
                                                            : CONTROL_TRAP);
   alu_outputs.op_stage2 = OP_Stage2_FD;
   alu_outputs.rd        = inputs.decoded_instr.rd;
   alu_outputs.rm        = rm;

   // Operand values
   // The first operand may be from the FPR or GPR
   let val1_from_gpr     = fv_fp_val1_from_gpr (opcode, funct7, rs2);

`ifdef ISA_D
`ifdef RV64
   alu_outputs.val1      = val1_from_gpr  ? inputs.rs1_val
                                          : inputs.frs1_val;
`else
   alu_outputs.val1      = val1_from_gpr  ? extend (inputs.rs1_val)
                                          : inputs.frs1_val;
`endif
`else
`ifdef RV32
   alu_outputs.val1      = val1_from_gpr  ? inputs.rs1_val
                                          : inputs.frs1_val;
`else
   alu_outputs.val1      = val1_from_gpr  ? inputs.rs1_val
                                          : extend (inputs.frs1_val);
`endif
`endif

   // Second and third operands (when used) are always from the FPR
`ifdef ISA_D
   alu_outputs.val2      = inputs.frs2_val;
`else
`ifdef RV32
   alu_outputs.val2      = inputs.frs2_val;
`else
   alu_outputs.val2      = extend (inputs.frs2_val);
`endif
`endif

   alu_outputs.val3      = inputs.frs3_val;

`ifdef ISA_F
   alu_outputs.rd_in_fpr = !fv_is_rd_in_GPR (funct7, rs2);
`endif

   // Normal trace output (if no trap)
`ifdef ISA_F
   if (alu_outputs.rd_in_fpr)
      alu_outputs.trace_data = mkTrace_F_RD (fall_through_pc (inputs),
					     fv_trace_isize (inputs),
					     fv_trace_instr (inputs),
					     inputs.decoded_instr.rd,
					     ?);
   else
`endif
      alu_outputs.trace_data = mkTrace_I_RD (fall_through_pc (inputs),
					     fv_trace_isize (inputs),
					     fv_trace_instr (inputs),
					     inputs.decoded_instr.rd,
					     ?);

   return alu_outputs;
endfunction
`endif

// ----------------------------------------------------------------
// AMO
// Just pass through to the memory stage

`ifdef ISA_A
function ALU_Outputs fv_AMO (ALU_Inputs inputs);
   IntXL  s_rs1_val = unpack (inputs.rs1_val);
`ifdef ISA_CHERI
   let authority = getFlags(inputs.pcc)[0] == 1'b0 ? inputs.ddc : inputs.cap_rs1_val;
   let authorityIdx = getFlags(inputs.pcc)[0] == 1'b0 ? {1,scr_addr_PCC} : {0,inputs.rs1_idx};
   WordXL eaddr = getFlags(inputs.pcc)[0] == 1'b0 ? getAddr(inputs.ddc) + inputs.rs1_val : getAddr(inputs.cap_rs1_val); //TODO DDC base should be cached
`else
   WordXL eaddr = pack (s_rs1_val);
`endif

   let funct3 = inputs.decoded_instr.funct3;
   let funct5 = inputs.decoded_instr.funct5;
   let funct7 = inputs.decoded_instr.funct7;

   Bool legal_f5 = (   (funct5 == f5_AMO_LR)   || (funct5 == f5_AMO_SC)

		    || (funct5 == f5_AMO_ADD)
		    || (funct5 == f5_AMO_SWAP)

		    || (funct5 == f5_AMO_AND)  || (funct5 == f5_AMO_OR) || (funct5 == f5_AMO_XOR)

		    || (funct5 == f5_AMO_MIN)  || (funct5 == f5_AMO_MINU)
		    || (funct5 == f5_AMO_MAX)  || (funct5 == f5_AMO_MAXU));

   // TODO: Cap width
   Bool legal_width = (   (funct3 == f3_AMO_W)
		       || ((xlen == 64) && (funct3 == f3_AMO_D)) );

   let alu_outputs = alu_outputs_base;

   let width_code = funct3;

   alu_outputs.control   = ((legal_f5 && legal_width) ? CONTROL_STRAIGHT : CONTROL_TRAP);
   alu_outputs.op_stage2 = OP_Stage2_AMO;
   alu_outputs.addr      = eaddr;
   alu_outputs.mem_width_code = width_code;
   alu_outputs.mem_unsigned = False;

   alu_outputs = checkValidDereference(alu_outputs, authority, authorityIdx, eaddr, width_code, True, inputs.cap_rs2_val);

   alu_outputs.val1      = zeroExtend (inputs.decoded_instr.funct7);
`ifdef ISA_D
   alu_outputs.val2      = extend (inputs.rs2_val);
`else
`ifdef ISA_CHERI
   alu_outputs.cap_val2      = inputs.cap_rs2_val;
   alu_outputs.val2_cap_not_int = width_code == w_SIZE_CAP;
`else
   alu_outputs.val2      = inputs.rs2_val;
`endif
`endif

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_AMO (fall_through_pc (inputs),
					 fv_trace_isize (inputs),
					 fv_trace_instr (inputs),
					 inputs.decoded_instr.rd, ?,
					 inputs.rs2_val,
					 eaddr);
   return alu_outputs;
endfunction
`endif

// ----------------------------------------------------------------
// CHERI
// Capability operations

`ifdef ISA_CHERI

function ALU_Outputs fv_CHERI_exc(ALU_Outputs outputs, Bit#(6) regIdx, CHERI_Exc_Code exc_code);
  outputs.exc_code = exc_code_CHERI;
  outputs.cheri_exc_code = exc_code;
  outputs.cheri_exc_reg = regIdx;
  outputs.control = CONTROL_TRAP;
  return outputs;
endfunction

function ALU_Outputs fv_CJALR (ALU_Inputs inputs);
   let rs1_val = inputs.cap_rs1_val;

   Addr  next_pc   = getOffset(rs1_val);
   Addr  ret_pc    = fall_through_pc (inputs);

   next_pc [0] = 1'b0;

   let alu_outputs = alu_outputs_base;
   alu_outputs.control   = CONTROL_CAPBRANCH;
   alu_outputs.op_stage2 = OP_Stage2_ALU;
   alu_outputs.rd        = inputs.decoded_instr.rd;

   if (!isValidCap(rs1_val)) begin
       alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Tag);
   end else if (isSealed(rs1_val)) begin
       alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
   end else if (!getHardPerms(rs1_val).permitExecute) begin
       alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_XPerm);
   end else begin
       alu_outputs.addr      = next_pc;
       alu_outputs.pcc       = setOffset(rs1_val, next_pc).value;
`ifdef ISA_D
       alu_outputs.val1      = extend (ret_pc);
`else
       alu_outputs.cap_val1  = setOffset(inputs.pcc, ret_pc).value; //TODO factor this out. Note that ret_pc must be representable
       alu_outputs.val1_cap_not_int = True;
`endif
       alu_outputs = checkValidJump(alu_outputs, True, rs1_val, {0,inputs.rs1_idx}, getBase(rs1_val) + next_pc);
   end

   // Normal trace output (if no trap)
   alu_outputs.trace_data = mkTrace_I_RD (next_pc,
					  fv_trace_isize (inputs),
					  fv_trace_instr (inputs),
					  inputs.decoded_instr.rd,
					  ret_pc);
   return alu_outputs;
endfunction

//TODO make this an instance of single-instance function?
function ALU_Outputs setBoundsCommon(ALU_Outputs alu_outputs, CapPipe cap, Bit#(5) regIdx, Bool tag, Bool sealed,  WordXL length, Bool exactRequired);
    if (!tag) begin
       alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(regIdx), exc_code_CHERI_Tag);
    end else if (sealed) begin
       alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(regIdx), exc_code_CHERI_Seal);
    end else if (!isInBounds(cap, True)) begin
       alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(regIdx), exc_code_CHERI_Length);
    end else begin
       alu_outputs.check_enable = True;
       alu_outputs.check_authority = cap;
       alu_outputs.check_authority_idx  = zeroExtend(regIdx);
       alu_outputs.check_inclusive = True;
       let result = setBounds(cap, length);
       alu_outputs.cap_val1 = result.value;
       alu_outputs.val1_cap_not_int = True;
       //Since the result of the setBounds is smaller than the original pointer, and the rounding
       //of the top and bottom does not depend on the other, this is safe, i.e. the result of
       //rounding cannot take you outside of the authorising capability if the request was not.
       //alu_outputs.check_address_low = getBase(alu_outputs.cap_val1);
       alu_outputs.check_address_low = getAddr(cap); //TODO repeated computation
       //alu_outputs.check_address_high = getTop(alu_outputs.cap_val1);
       alu_outputs.check_address_high = zeroExtend(getAddr(cap)) + zeroExtend(length); //TODO much repeated computation
       if (exactRequired && !result.exact) begin
           alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(regIdx), exc_code_CHERI_Precision);
       end
    end
    return alu_outputs;
endfunction

function ALU_Outputs checkValidDereference(ALU_Outputs alu_outputs, CapPipe authority, Bit#(6) authIdx, WordXL base, Bit#(3) widthCode, Bool isStoreNotLoad, CapPipe data);
   if (!isValidCap(authority)) begin
       alu_outputs = fv_CHERI_exc(alu_outputs, authIdx, exc_code_CHERI_Tag);
   end else if (isSealed(authority)) begin
       alu_outputs = fv_CHERI_exc(alu_outputs, authIdx, exc_code_CHERI_Seal);
   end else if ((isStoreNotLoad ? !getHardPerms(authority).permitStore : !getHardPerms(authority).permitLoad)) begin
       alu_outputs = fv_CHERI_exc(alu_outputs, authIdx, isStoreNotLoad ? exc_code_CHERI_WPerm : exc_code_CHERI_RPerm);
   end
   alu_outputs.check_enable = True;
   alu_outputs.check_authority = authority;
   alu_outputs.check_authority_idx = authIdx;
   alu_outputs.check_address_low = base;
   alu_outputs.check_address_high = zeroExtend(base) + (1 << widthCode);
   alu_outputs.check_inclusive = True;

   //TODO check alignment?
   if (widthCode == w_SIZE_CAP) begin //May be loading/storing caps
       if (isStoreNotLoad) begin
           if (getHardPerms(authority).permitStoreCap && (getHardPerms(data).global || getHardPerms(authority).permitStoreLocalCap)) begin
               alu_outputs.mem_allow_cap = True;
           end
       end else begin
           if (getHardPerms(authority).permitLoadCap) begin
               alu_outputs.mem_allow_cap = True;
           end
       end
   end
   return alu_outputs;
endfunction

function ALU_Outputs checkValidJump(ALU_Outputs alu_outputs, Bool branchTaken, CapPipe authority, Bit#(6) authIdx, WordXL target);
   //Note that we only check the first two bytes of the target instruction are in bounds in the jump.
`ifdef ISA_C
   Bool misaligned_target = getBase(authority)[0] != 1'b0;
`else
   Bool misaligned_target = (target [1] == 1'b1) || (getBase(authority)[1:0] != 2'b0);
`endif
   if (misaligned_target && branchTaken) begin
       alu_outputs.control = CONTROL_TRAP;
       alu_outputs.exc_code = exc_code_INSTR_ADDR_MISALIGNED;
   end
   alu_outputs.check_enable = branchTaken;
   alu_outputs.check_authority = authority;
   alu_outputs.check_authority_idx = authIdx;
   alu_outputs.check_address_low = target;
   alu_outputs.check_address_high = zeroExtend(target) + 2;
   alu_outputs.check_inclusive = True;
   return alu_outputs;
endfunction

function ALU_Outputs memCommon(ALU_Outputs alu_outputs, Bool isStoreNotLoad, Bool isUnsignedNotSigned, Bool useDDC, Bit#(3) widthCode, CapPipe ddc, CapPipe addr, Bit#(5) addrIdx, CapPipe data);
   let eaddr = getAddr(addr) + (useDDC ? getAddr(ddc) : 0);

   //width code must be checked externally

   alu_outputs.op_stage2      = isStoreNotLoad ? OP_Stage2_ST : OP_Stage2_LD;
   alu_outputs.addr           = eaddr;
   alu_outputs.mem_width_code = widthCode;
   alu_outputs.mem_unsigned   = isStoreNotLoad ? False : isUnsignedNotSigned;
   alu_outputs.val2           = getAddr(data); //for stores
   alu_outputs.cap_val2       = data;
   alu_outputs.val2_cap_not_int = widthCode == w_SIZE_CAP;

   let authority = useDDC ? ddc : addr;
   let authorityIdx = useDDC ? {1,scr_addr_PCC} : {0,addrIdx};

   //TODO store cap: also check store cap/store local/global cap permissions

   alu_outputs = checkValidDereference(alu_outputs, authority, authorityIdx, eaddr, widthCode, isStoreNotLoad, data);

   return alu_outputs;
endfunction

function ALU_Outputs incOffsetCommon(ALU_Outputs alu_outputs, CapPipe cap, Bit#(5) regIdx, Bool tag, Bool sealed, Bit#(XLEN) increment);
    if (tag && sealed) begin
        alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(regIdx), exc_code_CHERI_Seal);
    end else begin
        let result = setOffset(cap, getOffset(cap) + increment);
        alu_outputs.cap_val1 = result.value;
        alu_outputs.val1 = getAddr(result.value);
        alu_outputs.val1_cap_not_int = result.exact;
    end
    return alu_outputs;
endfunction

function ALU_Outputs sealCommon(ALU_Outputs alu_outputs, CapPipe sealee, Bit#(5) sealeeIdx, CapPipe sealer, Bit#(5) sealerIdx, Bool conditional);
    let sealee_tag = isValidCap(sealee);
    let sealee_sealed = isSealed(sealee);
    let sealer_tag = isValidCap(sealer);
    let sealer_sealed = isSealed(sealer);
    let sealer_addr = getAddr(sealer);
    if (!sealee_tag) begin
        alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(sealeeIdx), exc_code_CHERI_Tag);
    end else if (!conditional && !sealer_tag) begin
        alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(sealerIdx), exc_code_CHERI_Tag);
    end else if (conditional && (!sealer_tag || sealer_addr == -1)) begin
        alu_outputs.cap_val1 = sealee;
        alu_outputs.val1_cap_not_int = True;
    end else if (sealee_sealed) begin
        alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(sealeeIdx), exc_code_CHERI_Seal);
    end else if (sealer_sealed) begin
        alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(sealerIdx), exc_code_CHERI_Seal);
    end else if (!getHardPerms(sealer).permitSeal) begin
        alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(sealerIdx), exc_code_CHERI_SealPerm);
    end else if (!validAsType(sealee, truncate(sealer_addr))) begin
        alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(sealerIdx), exc_code_CHERI_Length);
    end else begin
        let result = setType(sealee, truncate(sealer_addr));
        if (!result.exact) begin
            alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(sealerIdx), exc_code_CHERI_Precision);
        end else begin
            alu_outputs.check_enable = True;
            alu_outputs.check_authority = sealer;
            alu_outputs.check_authority_idx = {0,sealerIdx};
            alu_outputs.check_address_low = sealer_addr;
            alu_outputs.check_address_high = zeroExtend(sealer_addr);
            alu_outputs.check_inclusive = False;
            alu_outputs.cap_val1 = result.value;
            alu_outputs.val1_cap_not_int = True;
        end
    end
    return alu_outputs;
endfunction

function ALU_Outputs fv_CHERI (ALU_Inputs inputs);
    let funct3  = inputs.decoded_instr.funct3;
    let funct5rs2 = inputs.decoded_instr.funct5rs2;
    let funct5rd = inputs.decoded_instr.funct5rd;
    let funct7  = inputs.decoded_instr.funct7;

    let rt_val = inputs.rs2_val;

    let cb_val = inputs.cap_rs1_val;
    let cb_tag = isValidCap(cb_val);
    let cb_addr = getAddr(cb_val);
    let cb_sealed = isSealed(cb_val);

    let ct_val = inputs.cap_rs2_val;
    let ct_tag = isValidCap(ct_val);
    let ct_addr = getAddr(ct_val);
    let ct_sealed = isSealed(ct_val);

    CapPipe rd_val = ?; //TODO update this in all cases

    let alu_outputs = alu_outputs_base;
    alu_outputs.rd = inputs.decoded_instr.rd;
    alu_outputs.op_stage2 = OP_Stage2_ALU;

    case (funct3)
    f3_cap_CIncOffsetImmediate: begin
        alu_outputs = incOffsetCommon(alu_outputs, cb_val, inputs.rs1_idx, cb_tag, cb_sealed, signExtend(inputs.decoded_instr.imm12_I));
    end
    f3_cap_CSetBoundsImmediate: begin
        alu_outputs = setBoundsCommon(alu_outputs, cb_val, inputs.rs1_idx, cb_tag, cb_sealed, zeroExtend(inputs.decoded_instr.imm12_I), False);
    end
    f3_cap_ThreeOp: begin
       case (funct7)
       f7_cap_CSpecialRW: begin
           if (inputs.decoded_instr.rs2 == scr_addr_PCC && inputs.decoded_instr.rs1 == 0) begin
               alu_outputs.cap_val1 = setOffset(inputs.pcc, inputs.pc).value;
               alu_outputs.val1_cap_not_int = True;
           end else if (inputs.decoded_instr.rs2 == scr_addr_DDC) begin
               alu_outputs.cap_val1 = inputs.ddc;
               alu_outputs.val1_cap_not_int = True;
               if (inputs.decoded_instr.rs1 != 0) begin
                   alu_outputs.ddc = inputs.cap_rs1_val;
                   alu_outputs.ddc_written = True;
               end
           end else begin
               CapPipe rs1_val = inputs.cap_rs1_val;

               alu_outputs.control   = CONTROL_SCR_W;
               alu_outputs.cap_val1  = rs1_val;
               alu_outputs.val1_cap_not_int = True;
           end
       end
       f7_cap_CSetBounds: begin
           alu_outputs = setBoundsCommon(alu_outputs, cb_val, inputs.rs1_idx, cb_tag, cb_sealed, rt_val, False);
       end
       f7_cap_CSetBoundsExact: begin
           alu_outputs = setBoundsCommon(alu_outputs, cb_val, inputs.rs1_idx, cb_tag, cb_sealed, rt_val, True);
       end
       f7_cap_CSetOffset: begin
           if (cb_tag && cb_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
           end else begin
               let result = setOffset(cb_val, rt_val);
               alu_outputs.cap_val1 = result.value;
               alu_outputs.val1 = getAddr(result.value);
               alu_outputs.val1_cap_not_int = result.exact;
           end
       end
       f7_cap_CSetAddr: begin
           if (cb_tag && cb_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
           end else begin
               let result = setAddr(cb_val, rt_val);
               alu_outputs.cap_val1 = result.value;
               alu_outputs.val1 = getAddr(result.value);
               alu_outputs.val1_cap_not_int = result.exact;
           end
       end
       f7_cap_CIncOffset: begin
           alu_outputs = incOffsetCommon(alu_outputs, cb_val, inputs.rs1_idx, cb_tag, cb_sealed, rt_val);
       end
       f7_cap_CSeal: begin
         alu_outputs = sealCommon(alu_outputs, cb_val, inputs.rs1_idx, ct_val, inputs.rs2_idx, False);
       end
       f7_cap_CCSeal: begin
         alu_outputs = sealCommon(alu_outputs, cb_val, inputs.rs1_idx, ct_val, inputs.rs2_idx, True);
       end
       f7_cap_CCall: begin
           let isCCallFast = inputs.decoded_instr.rd == 5'b1;
           if (inputs.decoded_instr.rd != 5'b0 && inputs.decoded_instr.rd != 5'b1) begin
               alu_outputs.control = CONTROL_TRAP;
               alu_outputs.exc_code = exc_code_ILLEGAL_INSTRUCTION;
           end else if (!cb_tag) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Tag);
           end else if (!ct_tag) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs2_idx), exc_code_CHERI_Tag);
           end else if (!cb_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
           end else if (!ct_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs2_idx), exc_code_CHERI_Seal);
           end else if (getType(cb_val) != getType(ct_val)) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Type);
           end else if (isCCallFast && !getHardPerms(cb_val).permitCCall) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_CCallPerm);
           end else if (isCCallFast && !getHardPerms(ct_val).permitCCall) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs2_idx), exc_code_CHERI_CCallPerm);
           end else if (!getHardPerms(cb_val).permitExecute) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_XPerm);
           end else if (getHardPerms(ct_val).permitExecute) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs2_idx), exc_code_CHERI_XPerm);
           end else if (!isInBounds(cb_val, False)) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Length);
           end else if (!isCCallFast) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Call);
           end else begin
               let target = {truncateLSB(cb_addr), 1'b0};

               alu_outputs.val1_cap_not_int = True;
               alu_outputs.cap_val1 = setType(ct_val, -1).value;
               alu_outputs.rd = cCallRD;
               alu_outputs.pcc = setType(cb_val, -1).value;

               alu_outputs.control = CONTROL_CAPBRANCH;
               alu_outputs = checkValidJump(alu_outputs, True, cb_val, zeroExtend(inputs.rs1_idx), target);
           end
       end
       f7_cap_CUnseal: begin
           if (!cb_tag) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Tag);
           end else if (!ct_tag) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs2_idx), exc_code_CHERI_Tag);
           end else if (getKind(cb_val) != SEALED_WITH_TYPE) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
           end else if (ct_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs2_idx), exc_code_CHERI_Seal);
           end else if (ct_addr != zeroExtend(getType(cb_val))) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs2_idx), exc_code_CHERI_Type);
           end else if (!getHardPerms(ct_val).permitUnseal) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs2_idx), exc_code_CHERI_UnsealPerm);
           end else begin
               let result = setType(cb_val, -1);
               if (!result.exact) begin
                   //Should be impossible
                   alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Precision);
               end else begin
                   alu_outputs.check_enable = True;
                   alu_outputs.check_authority = ct_val;
                   alu_outputs.check_authority_idx = {0,inputs.rs2_idx};
                   alu_outputs.check_address_low = ct_addr;
                   alu_outputs.check_address_high = zeroExtend(ct_addr);
                   alu_outputs.check_inclusive = False;
                   alu_outputs.cap_val1 = result.value;
                   alu_outputs.val1_cap_not_int = True;
               end
           end
       end
       f7_cap_CTestSubset: begin
           //TODO make this a two-cycle instruction to reuse bounds check in next stage
           if (inputs.rs1_idx == 0) cb_val = inputs.ddc;
           let result = isValidCap(cb_val) == ct_tag && getBase(ct_val) >= getBase(cb_val) && getTop(ct_val) <= getTop(cb_val) && ((getPerms(ct_val) & getPerms(cb_val)) == getPerms(ct_val));
           alu_outputs.val1 = zeroExtend(pack(result));
       end
       f7_cap_CCopyType: begin
           if (!cb_tag) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Tag);
           end else if (cb_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
           end else if (ct_sealed) begin
               let result = setAddr(cb_val, zeroExtend(getType(ct_val)));
               if (!result.exact) begin
                   //Should be impossible
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Precision);
               end else begin
                   alu_outputs.check_enable = True;
                   alu_outputs.check_authority = cb_val;
                   alu_outputs.check_authority_idx = {0,inputs.rs1_idx};
                   alu_outputs.check_address_low = zeroExtend(getType(ct_val));
                   alu_outputs.check_address_high = zeroExtend(getType(ct_val));
                   alu_outputs.check_inclusive = False;
                   alu_outputs.cap_val1 = result.value;
                   alu_outputs.val1_cap_not_int = True;
               end
           end else begin
               alu_outputs.val1 = -1;
           end
       end
       f7_cap_CAndPerm: begin
           if (!cb_tag) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Tag);
           end else if (cb_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
           end else begin
               alu_outputs.cap_val1 = setPerms(cb_val, pack(getPerms(cb_val)) & truncate(rt_val));
               alu_outputs.val1_cap_not_int = True;
           end
       end
       f7_cap_CSetFlags: begin
           if (cb_tag && cb_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
           end else begin
               alu_outputs.cap_val1 = setFlags(cb_val, truncate(rt_val));
               alu_outputs.val1_cap_not_int = True;
           end
       end
       f7_cap_CToPtr: begin
           if (inputs.rs2_idx == 0) begin
               ct_val = inputs.ddc;
               ct_tag = isValidCap(ct_val);
               //TODO think about alternatives for this
           end
           if (!ct_tag) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, inputs.rs2_idx == 0 ? {1'b1,scr_addr_DDC} : zeroExtend(inputs.rs2_idx), exc_code_CHERI_Tag);
           end else if (cb_tag && cb_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
           end else begin
               alu_outputs.val1 = cb_tag ? getAddr(cb_val) - getBase(ct_val) : 0; //TODO long critical path
           end
       end
       f7_cap_CFromPtr: begin
           if (inputs.rs1_idx == 0) begin
               cb_val = inputs.ddc;
               cb_tag = isValidCap(cb_val);
               cb_sealed = isSealed(cb_val);
               //TODO think about alternatives for this
           end
           if (rt_val == 0) begin
               alu_outputs.val1 = 0;
           end else if (!cb_tag) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, inputs.rs1_idx == 0 ? {1'b1,scr_addr_DDC} : zeroExtend(inputs.rs1_idx), exc_code_CHERI_Tag);
           end else if (cb_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, inputs.rs1_idx == 0 ? {1'b1,scr_addr_DDC} : zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
           end else begin
               let result = setOffset(cb_val, rt_val);
               alu_outputs.cap_val1 = result.value;
               alu_outputs.val1 = getAddr(result.value);
               alu_outputs.val1_cap_not_int = result.exact;
           end
       end
       f7_cap_CSub: begin
           alu_outputs.val1 = getAddr(cb_val) - getAddr(ct_val);
       end
       f7_cap_CBuildCap: begin
           //TODO factor into subset test
           if (inputs.rs1_idx == 0) begin
               cb_val = inputs.ddc;
               cb_tag = isValidCap(cb_val);
               cb_sealed = isSealed(cb_val);
               //TODO think about alternatives for this
           end
           if (!cb_tag) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, inputs.rs1_idx == 0 ? {1'b1,scr_addr_DDC} : zeroExtend(inputs.rs1_idx), exc_code_CHERI_Tag);
           end else if (cb_sealed) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, inputs.rs1_idx == 0 ? {1'b1,scr_addr_DDC} : zeroExtend(inputs.rs1_idx), exc_code_CHERI_Seal);
           end else if ((getPerms(cb_val) & getPerms(ct_val)) != getPerms(ct_val)) begin
               alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs2_idx), exc_code_CHERI_Software);
           end else begin
               alu_outputs.check_enable = True;
               alu_outputs.check_authority = cb_val;
               alu_outputs.check_authority_idx = {0,inputs.rs1_idx};
               alu_outputs.check_address_low = getBase(ct_val);
               alu_outputs.check_address_high = getTop(ct_val);
               alu_outputs.check_inclusive = True;
               if (zeroExtend(getBase(ct_val)) > getTop(ct_val)) begin //TODO make more efficient
                   alu_outputs = fv_CHERI_exc(alu_outputs, zeroExtend(inputs.rs2_idx), exc_code_CHERI_Length);
               end
               //TODO representability check? Should be unneccessary because arg is already represented so must be representable.
               //Only question is whether there are representations that are usually unreachable, and whether cbuildcap should
               //allow these.
               let result = setValidCap(ct_val, True);
               alu_outputs.cap_val1 = setType(result, -1).value;
               alu_outputs.val1_cap_not_int = True;
           end
       end
       f7_cap_Loads: begin
           Bit#(3) widthCode = ?;
           alu_outputs.control = CONTROL_STRAIGHT;
           if (funct5rs2[4] == 1) begin
               if (funct5rs2[2:0] == 3'b111) begin
                   widthCode = w_SIZE_Q;
               end else begin
                   alu_outputs.control = CONTROL_TRAP;
                   alu_outputs.exc_code = exc_code_ILLEGAL_INSTRUCTION;
               end
           end else begin
               widthCode = zeroExtend(funct5rs2[1:0]);
               if (funct5rs2[2:0] == 3'b111) begin
                   alu_outputs.control = CONTROL_TRAP;
                   alu_outputs.exc_code = exc_code_ILLEGAL_INSTRUCTION;
               end
           end
           if (widthCode > w_SIZE_MAX) begin
               alu_outputs.control = CONTROL_TRAP;
               alu_outputs.exc_code = exc_code_ILLEGAL_INSTRUCTION;
           end else begin
               alu_outputs = memCommon(alu_outputs, False, funct5rs2[2] == cap_mem_unsigned, funct5rs2[3] == cap_mem_ddc, widthCode, inputs.ddc, inputs.cap_rs1_val, inputs.rs1_idx, ?);
           end
       end
       f7_cap_Stores: begin
           let widthCode = funct5rd[2:0];
           alu_outputs.control = CONTROL_STRAIGHT;
           if (funct5rd[4] == 1) alu_outputs.control = CONTROL_TRAP;
           if (widthCode > w_SIZE_MAX) begin
               alu_outputs.control = CONTROL_TRAP;
               alu_outputs.exc_code = exc_code_ILLEGAL_INSTRUCTION;
           end
           alu_outputs = memCommon(alu_outputs, True, ?, funct5rd[3] == cap_mem_ddc, widthCode, inputs.ddc, inputs.cap_rs1_val, inputs.rs1_idx, inputs.cap_rs2_val);
       end
       f7_cap_TwoOp: begin
           case (funct5rs2)
           f5rs2_cap_CGetLen: begin
               let length = getLength(cb_val);
               alu_outputs.val1 = truncate(length);
           end
           f5rs2_cap_CGetBase: begin
               alu_outputs.val1 = getBase(cb_val);
           end
           f5rs2_cap_CGetTag: begin
               alu_outputs.val1 = zeroExtend(pack(isValidCap(cb_val)));
           end
           f5rs2_cap_CGetSealed: begin
               alu_outputs.val1 = zeroExtend(pack(isSealed(cb_val)));
           end
           f5rs2_cap_CMove: begin
               alu_outputs.cap_val1 = cb_val;
               alu_outputs.val1_cap_not_int = True;
           end
           f5rs2_cap_CClearTag: begin
               alu_outputs.cap_val1 = setValidCap(cb_val, False);
               alu_outputs.val1_cap_not_int = True;
           end
           f5rs2_cap_CGetAddr: begin
               alu_outputs.val1 = getAddr(cb_val);
           end
           f5rs2_cap_CGetOffset: begin
               alu_outputs.val1 = getOffset(cb_val);
           end
           f5rs2_cap_CGetFlags: begin
               alu_outputs.val1 = zeroExtend(getFlags(cb_val));
           end
           f5rs2_cap_CGetPerm: begin
               alu_outputs.val1 = zeroExtend(getPerms(cb_val));
           end
           f5rs2_cap_CJALR: begin
               alu_outputs = fv_CJALR(inputs);
           end
           f5rs2_cap_CGetType: begin
               alu_outputs.val1 = isSealed(cb_val) ? zeroExtend(getType(cb_val)) : -1;
           end
           default: begin
               alu_outputs.control = CONTROL_TRAP;
               alu_outputs.exc_code = exc_code_ILLEGAL_INSTRUCTION;
           end
           endcase
       end
       default: begin
           alu_outputs.control = CONTROL_TRAP;
           alu_outputs.exc_code = exc_code_ILLEGAL_INSTRUCTION;
       end
       endcase
   end
   default: begin
       alu_outputs.control = CONTROL_TRAP;
       alu_outputs.exc_code = exc_code_ILLEGAL_INSTRUCTION;
   end
   endcase

   // Normal trace output (if no trap)
    alu_outputs.trace_data = mkTrace_I_RD (fall_through_pc (inputs),
					  fv_trace_isize (inputs),
					  fv_trace_instr (inputs),
					  inputs.decoded_instr.rd,
					  getAddr(rd_val));
   return alu_outputs;
endfunction
`endif

// ----------------------------------------------------------------
// Top-level ALU function

function ALU_Outputs fv_ALU (ALU_Inputs inputs);
   let alu_outputs = alu_outputs_base;

   if (inputs.decoded_instr.opcode == op_BRANCH)
      alu_outputs = fv_BRANCH (inputs);

   else if (inputs.decoded_instr.opcode == op_JAL)
      alu_outputs = fv_JAL (inputs);

   else if (inputs.decoded_instr.opcode == op_JALR)
      alu_outputs = fv_JALR (inputs);

`ifdef ISA_M
   // OP 'M' ops MUL/ MULH/ MULHSU/ MULHU/ DIV/ DIVU/ REM/ REMU
   else if (   (inputs.decoded_instr.opcode == op_OP)
	    && f7_is_OP_MUL_DIV_REM (inputs.decoded_instr.funct7))
      begin
	 // Will be executed in MBox in next stage
	 alu_outputs.op_stage2 = OP_Stage2_M;
	 alu_outputs.rd        = inputs.decoded_instr.rd;
`ifdef ISA_D
	 alu_outputs.val1      = extend (inputs.rs1_val);
	 alu_outputs.val2      = extend (inputs.rs2_val);
`else
	 alu_outputs.val1      = inputs.rs1_val;
	 alu_outputs.val2      = inputs.rs2_val;
`endif

	 // Normal trace output (if no trap)
	 alu_outputs.trace_data = mkTrace_I_RD (fall_through_pc (inputs),
						fv_trace_isize (inputs),
						fv_trace_instr (inputs),
						inputs.decoded_instr.rd,
						?);
      end

`ifdef RV64
   // OP 'M' ops MULW/ DIVW/ DIVUW/ REMW/ REMUW
   else if (   (inputs.decoded_instr.opcode == op_OP_32)
	    && f7_is_OP_MUL_DIV_REM (inputs.decoded_instr.funct7))
      begin
	 // Will be executed in MBox in next stage
	 alu_outputs.op_stage2 = OP_Stage2_M;
	 alu_outputs.rd        = inputs.decoded_instr.rd;
	 alu_outputs.val1      = inputs.rs1_val;
	 alu_outputs.val2      = inputs.rs2_val;

	 // Normal trace output (if no trap)
	 alu_outputs.trace_data = mkTrace_I_RD (fall_through_pc (inputs),
						fv_trace_isize (inputs),
						fv_trace_instr (inputs),
						inputs.decoded_instr.rd,
						?);
      end
`endif
`endif

   // OP_IMM and OP (shifts)
   else if (   (   (inputs.decoded_instr.opcode == op_OP_IMM)
		|| (inputs.decoded_instr.opcode == op_OP))
	    && (   (inputs.decoded_instr.funct3 == f3_SLLI)
		|| (inputs.decoded_instr.funct3 == f3_SRLI)
		|| (inputs.decoded_instr.funct3 == f3_SRAI)))
      alu_outputs = fv_OP_and_OP_IMM_shifts (inputs);

   // Remaining OP_IMM and OP (excluding shifts and 'M' ops MUL/DIV/REM)
   else if (   (inputs.decoded_instr.opcode == op_OP_IMM)
	    || (inputs.decoded_instr.opcode == op_OP))
      alu_outputs = fv_OP_and_OP_IMM (inputs);

`ifdef RV64
   else if (inputs.decoded_instr.opcode == op_OP_IMM_32)
      alu_outputs = fv_OP_IMM_32 (inputs);

   // Remaining op_OP_32 (excluding 'M' ops)
   else if (inputs.decoded_instr.opcode == op_OP_32)
      alu_outputs = fv_OP_32 (inputs);
`endif

   else if (inputs.decoded_instr.opcode == op_LUI)
      alu_outputs = fv_LUI (inputs);

   else if (inputs.decoded_instr.opcode == op_AUIPC)
      alu_outputs = fv_AUIPC (inputs);

   else if (inputs.decoded_instr.opcode == op_LOAD)
      alu_outputs = fv_LD (inputs, Invalid);

   else if (inputs.decoded_instr.opcode == op_STORE)
      alu_outputs = fv_ST (inputs);

   else if (inputs.decoded_instr.opcode == op_MISC_MEM)
      alu_outputs = fv_MISC_MEM (inputs);

   else if (inputs.decoded_instr.opcode == op_SYSTEM)
      alu_outputs = fv_SYSTEM (inputs);

`ifdef ISA_A
   else if (inputs.decoded_instr.opcode == op_AMO)
      alu_outputs = fv_AMO (inputs);
`endif

`ifdef ISA_F
   else if (   (inputs.decoded_instr.opcode == op_LOAD_FP))
      alu_outputs = fv_LD (inputs);

   else if (   (inputs.decoded_instr.opcode == op_STORE_FP))
      alu_outputs = fv_ST (inputs);

   else if (   (inputs.decoded_instr.opcode == op_FP)
            || (inputs.decoded_instr.opcode == op_FMADD)
            || (inputs.decoded_instr.opcode == op_FMSUB)
            || (inputs.decoded_instr.opcode == op_FNMSUB)
            || (inputs.decoded_instr.opcode == op_FNMADD))
      alu_outputs = fv_FP (inputs);
`endif

`ifdef ISA_CHERI
   else if (   (inputs.decoded_instr.opcode == op_cap_Manip))
      alu_outputs = fv_CHERI (inputs);
`endif

   else begin
      alu_outputs.control = CONTROL_TRAP;

      // Normal trace output (if no trap)
      alu_outputs.trace_data = mkTrace_TRAP (fall_through_pc (inputs),
					     fv_trace_isize (inputs),
					     fv_trace_instr (inputs),
					     ?,
					     ?,
					     ?,
					     ?,
					     ?);
   end

`ifdef ISA_CHERI
   if (!alu_outputs.ddc_written) alu_outputs.ddc = inputs.ddc;
`endif

   return alu_outputs;
endfunction

// ================================================================

endpackage
