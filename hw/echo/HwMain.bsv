import FIFO::*;
import FIFOF::*;
import Vector::*;

import PcieCtrl::*;


interface HwMainIfc;
endinterface

module mkHwMain#(PcieUserIfc pcie) (HwMainIfc);

	// Cycle counter (for debug messages)
	Reg#(Bit#(32)) cycleCount <- mkReg(0);
	rule incCycleCounter;
		cycleCount <= cycleCount + 1;
	endrule

	// Echo-back storage
	Reg#(Bit#(32)) echoData  <- mkReg(0);
	Reg#(Bool)     echoValid <- mkReg(False);

	// Simple counter for testing — increments every time host reads offset 2
	Reg#(Bit#(32)) hwCounter <- mkReg(0);

	//--------------------------------------------------------------------------------------------
	// Receive data from host via PCIe
	//--------------------------------------------------------------------------------------------
	rule pcieDataWriter;
		let w <- pcie.dataReceive;

		let d = w.data;
		let a = w.addr;
		let off = (a >> 2);

		if ( off == 0 ) begin
			// offset 0: store data for echo-back
			echoData  <= d;
			echoValid <= True;
			$display("[HwMain] Cycle %0d: received echo data = 0x%08x", cycleCount, d);
		end
	endrule

	//--------------------------------------------------------------------------------------------
	// Send data back to host via PCIe
	//--------------------------------------------------------------------------------------------
	rule pcieDataReader;
		let r <- pcie.dataReq;

		Bit#(4) a = truncate(r.addr >> 2);

		if ( a == 0 ) begin
			// offset 0: echo back the stored data
			pcie.dataSend(r, echoData);
			$display("[HwMain] Cycle %0d: echo reply = 0x%08x", cycleCount, echoData);
		end else if ( a == 1 ) begin
			// offset 1: return echoValid status (1 = data received, 0 = no data yet)
			pcie.dataSend(r, echoValid ? 1 : 0);
		end else if ( a == 2 ) begin
			// offset 2: hardware counter (increments on each read)
			pcie.dataSend(r, hwCounter);
			hwCounter <= hwCounter + 1;
		end else begin
			// unknown offset: return magic number so host knows HW is alive
			pcie.dataSend(r, 32'hDEADBEEF);
		end
	endrule

endmodule
