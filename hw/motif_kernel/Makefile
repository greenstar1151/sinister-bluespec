# ============================================================
# Motif Kernel — self-contained build
# ============================================================
PROJECT     := motif
ROOT_DIR    := ../..
PLATFORM    ?= xilinx_u50_gen3x16_xdma_5_202210_1
TARGET      ?= hw

# Paths
SCRIPTS_DIR := ../scripts
BLIB_DIR    := $(ROOT_DIR)/libs/bluelib/src
CONFIGDIR   := ../configs
HOSTDIR     := $(ROOT_DIR)/sw/motif_host
BUILD_DIR   := ../build/$(PROJECT)

# BSC
BSCFLAGS       = -show-schedule -aggressive-conditions
BSCFLAGS_SYNTH = -bdir ./obj -vdir ./obj/verilog -simdir ./obj -info-dir ./obj -fdir ./obj

# Vivado / v++
VIVADO   := $(XILINX_VIVADO)/bin/vivado
JOBS     := 8
VPPFLAGS := --vivado.param general.maxThreads=$(JOBS) \
            --vivado.impl.jobs $(JOBS) --vivado.synth.jobs $(JOBS) \
            --temp_dir $(BUILD_DIR) --log_dir $(BUILD_DIR) \
            --report_dir $(BUILD_DIR) --report_level 2

# ============================================================
.PHONY: all verilog xo xclbin host emconfig package clean distclean

all: package

# --- BSV -> Verilog ---
verilog: $(wildcard *.bsv) $(wildcard *.v)
	mkdir -p obj/verilog
	bsc $(BSCFLAGS) $(BSCFLAGS_SYNTH) -remove-dollar -p +:$(BLIB_DIR) \
		-verilog -u -g kernel KernelTop.bsv
	cd obj/verilog && bash $(CURDIR)/$(SCRIPTS_DIR)/verilogcopy.sh
	cp *.v ./obj/verilog/

# --- .xo (Vivado IP packaging) ---
xo: verilog $(BUILD_DIR)/kernel.xo

$(BUILD_DIR)/kernel.xo: kernel.xml package_kernel.tcl $(SCRIPTS_DIR)/gen_xo.tcl \
                         $(SCRIPTS_DIR)/verilogcopy.sh $(wildcard *.bsv) $(wildcard *.v)
	mkdir -p obj $(BUILD_DIR)
	$(VIVADO) -mode batch -tempDir obj \
		-source $(SCRIPTS_DIR)/gen_xo.tcl \
		-tclargs $(BUILD_DIR)/kernel.xo kernel hw $(PLATFORM)

# --- .xclbin (v++ link) ---
xclbin: $(BUILD_DIR)/kernel.xclbin

$(BUILD_DIR)/kernel.xclbin: $(BUILD_DIR)/kernel.xo $(CONFIGDIR)/u50.cfg
	v++ -l -t $(TARGET) --platform $(PLATFORM) \
		--config $(CONFIGDIR)/u50.cfg $(VPPFLAGS) \
		$(BUILD_DIR)/kernel.xo -o $(BUILD_DIR)/kernel.xclbin

# --- Host ---
host: $(HOSTDIR)/obj/main

$(HOSTDIR)/obj/main: $(HOSTDIR)/main.cpp $(HOSTDIR)/Makefile
	$(MAKE) -C $(HOSTDIR)

# --- emconfig ---
emconfig: $(BUILD_DIR)/emconfig.json

$(BUILD_DIR)/emconfig.json:
	mkdir -p $(BUILD_DIR)
	emconfigutil --platform $(PLATFORM) --od $(BUILD_DIR) --nd 1

# --- Package ---
package: host emconfig xclbin
	mkdir -p $(BUILD_DIR)/package
	cp $(HOSTDIR)/obj/main $(BUILD_DIR)/package/
	cp $(BUILD_DIR)/kernel.xclbin $(BUILD_DIR)/package/
	cp $(BUILD_DIR)/emconfig.json $(BUILD_DIR)/package/
	cp $(CONFIGDIR)/xrt.ini $(BUILD_DIR)/package/
	cd $(BUILD_DIR) && tar czf package.tgz package

# --- Clean ---
clean:
	rm -rf obj *.log *.jou .Xil .ipcache
	$(MAKE) -C $(HOSTDIR) clean

distclean: clean
	rm -rf $(BUILD_DIR)
