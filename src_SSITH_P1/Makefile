###  -*-Makefile-*-

# ================================================================

.PHONY: help
help:
	@echo '    make  compile      Recompile Core (CPU, caches) into Verilog_RTL'
	@echo '                           NOTE: needs Bluespec bsc compiler'
	@echo '    make  tagsparams   Generates the CHERI tag controller parameters source file'
	@echo ''
	@echo '    make  clean        Remove intermediate build-files'
	@echo '    make  full_clean   Restore this directory to pristine state'

.PHONY: all
all: compile

# ================================================================

REPO ?= ..
ARCH ?= RV32ACIMUxCHERI

# ================================================================
# RISC-V config macros passed into Bluespec 'bsc' compiler

BSC_COMPILATION_FLAGS += \
	-D RV32 \
	-D ISA_PRIV_M  -D ISA_PRIV_U  \
	-D RISCV \
	-D CAP64 \
	-D CapWidth=64 -D CheriBusBytes=8 \
	-D CheriMasterIDWidth=1 -D CheriTransactionIDWidth=5 \
	-D ISA_I  -D ISA_M  -D ISA_A  -D ISA_C -D ISA_CHERI \
	-D PERFORMANCE_MONITORING \
	-D CapWidth=128 -D CheriBusBytes=64 \
	-D SHIFT_BARREL    \
	-D MULT_SYNTH    \
	-D Near_Mem_Caches    \
	-D FABRIC64 \
	-D INCLUDE_GDB_CONTROL \
	-D BRVF_TRACE \
	-D XILINX_BSCAN  -D XILINX_XCVU9P  -D JTAG_TAP

# CHERI parameters
CAPSIZE = 64
TAGS_STRUCT = 0 64
TAGS_ALIGN = 32

# ================================================================
# Search path for bsc for .bsv files
CONTRIB_DIRS ?= %/Libraries/Bus

BSV_LIBS = $(REPO)/libs
BLUESTUFF = $(BSV_LIBS)/BlueStuff

CORE_DIRS = $(REPO)/src_Core/CPU:$(REPO)/src_Core/ISA:$(REPO)/src_Core/RegFiles:$(REPO)/src_Core/Core:$(REPO)/src_Core/Near_Mem_VM:$(REPO)/src_Core/PLIC:$(REPO)/src_Core/Near_Mem_IO:$(REPO)/src_Core/Debug_Module:$(REPO)/src_Core/BSV_Additional_Libs:$(BLUESTUFF)/BlueUtils:$(REPO)/src_Verifier:

# Paths for Tag Controller
TAG_CONTROLLER_DIRS = $(CONTRIB_DIRS):$(BSV_LIBS)/TagController/TagController:$(BSV_LIBS)/TagController/TagController/CacheCore:

# Path for CHERI
CHERI_DIR = $(BSV_LIBS)/cheri-cap-lib:

# XXX
# Specify the path to the BlueStuff library (https://github.com/CTSRD-CHERI/BlueStuff)
# What is the best way to distribute this code?
# XXX

AXI_DIRS = $(BLUESTUFF)/AXI:$(BLUESTUFF)/BlueBasics:$(BLUESTUFF):

BSC_PATH = -p $(CORE_DIRS)src_BSV:$(AXI_DIRS)$(CHERI_DIR)$(TAG_CONTROLLER_DIRS)+

# ----------------
# Top-level file and module

TOPFILE   = src_BSV/P1_Core.bsv
TOPMODULE = mkP1_Core

# ================================================================
# bsc compilation flags

# XXX
# Using '-no-show-timestamps' with
# Bluespec Compiler, version 2017.07.A (build 1da80f1, 2017-07-21)
# results in
# Error: Command line: (S0008)
#   Unrecognized flag: -no-show-timestamps
# XXX
BSC_COMPILATION_FLAGS += \
	-keep-fires -aggressive-conditions -no-warn-action-shadowing \
	-suppress-warnings G0020    \
	+RTS -K128M -RTS  -show-range-conflict \
    -unspecified-to X -opt-undetermined-vals

# ================================================================
# Generate Bluespec CHERI tag controller source file

.PHONY: tagsparams
tagsparams: src_BSV/TagTableStructure.bsv
src_BSV/TagTableStructure.bsv: $(REPO)/libs/TagController/tagsparams.py
	@echo "INFO: Re-generating CHERI tag controller parameters"
	$^ -v -c $(CAPSIZE) -s $(TAGS_STRUCT:"%"=%) -a $(TAGS_ALIGN) --data-store-base-addr 0xc0000000  -b $@ 0x3fffc000 0xfffff000
	@echo "INFO: Re-generated CHERI tag controller parameters"

# ================================================================
# Generate Verilog RTL from BSV sources (needs Bluespec 'bsc' compiler)

RTL_GEN_DIRS = -vdir Verilog_RTL  -bdir build_dir  -info-dir build_dir

build_dir:
	mkdir -p $@

Verilog_RTL:
	mkdir -p $@

.PHONY: compile
compile:  build_dir  Verilog_RTL tagsparams
	@echo  "INFO: Generating RTL into Verilog_RTL ..."
	bsc -u -elab -verilog  $(RTL_GEN_DIRS)  $(BSC_COMPILATION_FLAGS)  $(BSC_PATH)  $(TOPFILE) && sed -i 's/^module/(* keep_hierarchy = "yes" *) module/g' Verilog_RTL/*.v
	@echo  "INFO: Generated RTL into Verilog_RTL"

# ================================================================

.PHONY: clean
clean:
	rm -r -f  *~  Makefile_*  build_dir
	rm -f src_BSV/TagTableStructure.bsv

.PHONY: full_clean
full_clean: clean
	rm -r -f  *.log  Verilog_RTL

# ================================================================
