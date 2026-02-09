# sinister-bluespec


## Prerequisites

- **Bluespec Compiler (`bsc`)**
- **Vivado** — Xilinx FPGA synthesis and IP generation
- **g++** — Host software build
- **Linux**

## Dependencies

| Repository       | URL                                        |
| ---------------- | ------------------------------------------ |
| **bluespecpcie** | https://github.com/sangwoojun/bluespecpcie |
| **bluelib**      | https://github.com/sangwoojun/bluelib      |
## Setup

```bash
# Clone dependencies (any location)
git clone https://github.com/sangwoojun/bluespecpcie ~/bluespecpcie
git clone https://github.com/sangwoojun/bluelib ~/bluelib

# Create symlinks under libs/
cd sinister-bluespec
mkdir -p libs
ln -s ~/bluespecpcie libs/bluespecpcie
ln -s ~/bluelib libs/bluelib
```

## Directory Layout

```
sinister-bluespec/
├── libs/
│   ├── bluespecpcie -> ~/bluespecpcie   (symlink)
│   └── bluelib -> ~/bluelib            (symlink)
└── hw/
```

## Makefile Configuration

**HW Makefile** (`hw/<design>/Makefile`):
```makefile
LIBPATH=../../libs/bluespecpcie
BLIBPATH=../../libs/bluelib/src/
BUILDTOOLS=$(LIBPATH)/buildtools/

CUSTOMBSV= -p +:$(LIBPATH)/src/:$(LIBPATH)/dram/src:$(BLIBPATH)/:$(BLIBPATH)/msfp/:<local-modules>
CUSTOMCPP_BSIM= $(BLIBPATH)/bdpi.cpp

include $(BUILDTOOLS)/Makefile.base
```

**SW Makefile** (`hw/<design>/cpp/Makefile`):
```makefile
LIBPATH=../../../libs/bluespecpcie

BDBMPCIEINCLUDE= -I$(LIBPATH)/cpp/
BDBMPCIECPP= $(LIBPATH)/cpp/bdbmpcie.cpp $(LIBPATH)/cpp/ShmFifo.cpp $(LIBPATH)/cpp/DRAMHostDMA.cpp
LIB= -lrt

all:
    mkdir -p obj
    g++ main.cpp $(BDBMPCIECPP) $(BDBMPCIEINCLUDE) -o obj/main $(LIB) -pedantic -g
bsim:
    mkdir -p obj
    g++ main.cpp $(BDBMPCIECPP) $(BDBMPCIEINCLUDE) -o obj/bsim $(LIB) -DBLUESIM -g -pedantic
```

## Build

### Generate Xilinx IP (once)

```bash
cd hw/<design>
make core BOARD=vc707
```

### FPGA Synthesis

```bash
make BOARD=vc707
```

### Bluesim Simulation

```bash
# Build HW simulator
make bsim

# Build SW (simulation mode)
cd cpp && make bsim && cd ..

# Create sw symlink (once)
ln -s cpp/obj/bsim sw

# Run
./run.sh
```

> **Note:** Shared memory files may persist after a run. Clean up with `rm /dev/shm/bdbm*`.


## PCIe Driver (on-board execution only)

```bash
# Driver
cd libs/bluespecpcie/distribute/driver && make && sudo make install

# bsrescan (re-discover PCIe device without reboot after reprogramming)
cd libs/bluespecpcie/distribute/bsrescan && make && sudo make install
```
