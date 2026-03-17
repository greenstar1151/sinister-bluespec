# sinister-bluespec

FPGA acceleration using Bluespec SystemVerilog and the Vitis RTL-kernel flow.
Each kernel is written in BSV, compiled to Verilog, packaged as a Vitis `.xo`,
and linked into an `.xclbin` that runs on the card via XRT.

The build scaffolding (AXI-Lite controller wrappers, packaging scripts, Makefiles)
is adapted from [bluespec-vitis-core](https://github.com/sangwoojun/bluespec-vitis-core).

> Currently tested on Alveo U50 (platform `xilinx_u50_gen3x16_xdma_5_202210_1`).
> Other Vitis-supported boards can be targeted by changing the `PLATFORM` variable
> and supplying an appropriate config file under `hw/configs/`.


## Prerequisites

- **Bluespec Compiler (`bsc`)**
- **Vitis** (includes Vivado) — kernel synthesis, packaging, and linking
- **XRT** (Xilinx Runtime) — host ↔ FPGA communication
- **g++** (C++17) — host software build
- **Linux**


## Dependencies

| Repository  | URL                                   | Notes |
| ----------- | ------------------------------------- | ----- |
| **bluelib** | https://github.com/sangwoojun/bluelib | BSV utility library (Serializer, BLShifter, etc.) |


## Setup

```bash
git clone https://github.com/sangwoojun/bluelib ~/bluelib

cd sinister-bluespec
mkdir -p libs
ln -s ~/bluelib libs/bluelib
```


## Directory Layout

```
sinister-bluespec/
├── hw/
│   ├── Makefile               # top-level dispatcher (delegates to per-kernel Makefiles)
│   ├── configs/
│   │   ├── u50.cfg            # v++ connectivity / frequency config
│   │   └── xrt.ini            # XRT runtime settings
│   ├── scripts/
│   │   ├── gen_xo.tcl         # shared: drive Vivado to produce .xo
│   │   └── verilogcopy.sh     # shared: post-process BSC-generated Verilog
│   ├── echo_kernel/           # simple register-echo example
│   ├── <name>_kernel/         # additional kernels follow the same pattern
│   └── build/                 # (generated) per-project build output
│       └── echo/
├── sw/
│   ├── echo_host/             # XRT host app for echo kernel
│   └── <name>_host/           # one host app per kernel
├── docs/                      # design documents, handoff specs
├── libs/
│   └── bluelib -> ~/bluelib   # (symlink)
└── hw/echo/                   # (legacy VC707 design — see below)
```


## Build

The top-level `hw/Makefile` dispatches to per-kernel Makefiles via the `PROJECT` variable.

```bash
cd hw

# Build everything for the echo kernel (BSV→Verilog→xo→xclbin + host + package)
make PROJECT=echo

# Or step-by-step
make PROJECT=echo verilog      # BSV → Verilog
make PROJECT=echo xo           # Verilog → .xo (Vivado IP packaging)
make PROJECT=echo xclbin       # .xo → .xclbin (v++ link)
make PROJECT=echo host         # compile host app
make PROJECT=echo package      # bundle xclbin + host + emconfig into a tarball
```

Build output goes to `hw/build/<project>/`. The final deliverable is
`hw/build/<project>/package.tgz`.

To target a different board:

```bash
make PROJECT=echo PLATFORM=xilinx_u250_gen3x16_xdma_4_1_202210_1 xclbin
```

### Running

```bash
cd hw/build/echo/package
./main kernel.xclbin
```

### Cleaning

```bash
make PROJECT=echo clean        # remove obj/ and logs for one kernel
make clean-all                 # clean all kernels
make PROJECT=echo distclean    # also remove build/<project>
```


## Adding a New Kernel

To create a kernel called `foo`, add two directories:

```
hw/foo_kernel/
├── KernelTop.bsv              # Top-level BSV module — must synthesize as `kernel`
├── FooLogic.bsv               # Your core logic module(s)
├── AxiLiteControllerFoo.bsv   # BVI wrapper — imports the Verilog AXI-Lite slave into BSV
├── s_axi_control_foo.v        # Verilog AXI-Lite slave — defines the register map
├── kernel.xml                 # Vitis kernel descriptor (ports, args, offsets)
├── package_kernel.tcl         # Vivado IP-packaging script
└── Makefile                   # Per-kernel build; set PROJECT := foo

sw/foo_host/
├── main.cpp                   # XRT host application
└── Makefile
```

### File roles

| File | Role |
|------|------|
| `KernelTop.bsv` | Synthesize boundary. Instantiates the AXI-Lite controller, your logic module, and wires them. Module name **must** be `kernel`. Uses `ap_clk` / `ap_rst_n` as default clock/reset. |
| `FooLogic.bsv` | Where the actual computation lives. Communicates with `KernelTop` through start/done handshake and register reads. |
| `AxiLiteControllerFoo.bsv` | BVI import of `s_axi_control_foo.v`. Exposes `ap_start`, `ap_done`, `ap_idle`, `ap_ready` control signals and any user-defined scalar/address registers. |
| `s_axi_control_foo.v` | Standard AXI4-Lite slave implementing the register map. Modify address offsets here to add fields; keep the `0x00`–`0x0C` control registers as-is for Vitis compatibility. |
| `kernel.xml` | Declares the kernel's ports, arguments, their sizes and offsets. Must match the register map in the Verilog slave. |
| `package_kernel.tcl` | Collects generated Verilog from `obj/verilog/`, packages into a Vivado IP. Adjust `ipx::associate_bus_interfaces` if you add AXI-MM master ports. |
| `Makefile` | Copy from an existing kernel; change `PROJECT`, `HOSTDIR`, and optionally `BSCFLAGS`/`MODULEPATH`. |
| `sw/foo_host/main.cpp` | Uses XRT API (`xrt::device`, `xrt::kernel`, `xrt::ip`) to load the xclbin, write registers, launch the kernel, and read back results. |

### Quick start

The easiest path: copy `echo_kernel/` and `echo_host/`, rename, and modify. The echo
kernel is the minimal working example — it only uses AXI-Lite registers (no AXI-MM
memory). For a kernel that also needs host-memory DMA (AXI-MM), see the upstream
[bluespec-vitis-core example_kernel](https://github.com/sangwoojun/bluespec-vitis-core/tree/main/hw/example_kernel)
which includes `Axi4MemoryMaster.bsv` and HBM connectivity.



## .gitignore Policy

Source files (BSV, Verilog, Tcl, XML, Makefiles, C++) are tracked.
All build artifacts are ignored:

- `**/obj/` — BSC intermediate output, compiled host binaries
- `hw/build/` — v++ link output (`.xo`, `.xclbin`, reports, logs)
- `.Xil/`, `.ipcache/` — Vivado temporaries
- `*.log`, `*.jou`, `*.backup.*` — tool journals


<details>
<summary>Legacy VC707 / bluespecpcie Flow</summary>

The `hw/echo/` directory contains an older design targeting VC707 via the
[bluespecpcie](https://github.com/sangwoojun/bluespecpcie) library. This flow
uses PCIe shared-memory communication rather than the Vitis/XRT model.

### Additional dependency

```bash
git clone https://github.com/sangwoojun/bluespecpcie ~/bluespecpcie
ln -s ~/bluespecpcie libs/bluespecpcie
```

### Build

```bash
cd hw/echo
make core BOARD=vc707              # generate Xilinx IP (once)
make BOARD=vc707 TCLARGS=../../../libs/bluespecpcie   # FPGA synthesis
```

### Bluesim simulation

```bash
make bsim
cd cpp && make bsim && cd ..
ln -s cpp/obj/bsim sw
./run.sh
```

> Shared memory files may persist after a run. Clean up with `rm /dev/shm/bdbm*`.

### PCIe driver

```bash
cd libs/bluespecpcie/distribute/driver && make && sudo make install
cd libs/bluespecpcie/distribute/bsrescan && make && sudo make install
```

</details>
