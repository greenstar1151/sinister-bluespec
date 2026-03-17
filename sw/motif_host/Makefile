.PHONY: all clean

CXXFLAGS := -std=c++17 -Wall -O2 -g
LDFLAGS  := -L$(XILINX_XRT)/lib -lxrt_coreutil -pthread -lm
INCLUDES := -I$(XILINX_XRT)/include

all:
	mkdir -p obj
	g++ $(CXXFLAGS) $(INCLUDES) main.cpp -o ./obj/main $(LDFLAGS)

clean:
	rm -rf obj
