package KernelMain;

interface KernelMainIfc;
	method Action hostWrite(Bit#(32) data);
	method Action counterRead;
	method Bit#(32) echoData;
	method Bit#(32) status;
	method Bit#(32) counter;
	method Bit#(32) magic;
endinterface

module mkKernelMain(KernelMainIfc);
	Reg#(Bit#(32)) echoDataReg <- mkReg(0);
	Reg#(Bool) echoValid <- mkReg(False);
	Reg#(Bit#(32)) hwCounter <- mkReg(0);

	method Action hostWrite(Bit#(32) data);
		echoDataReg <= data;
		echoValid <= True;
	endmethod

	method Action counterRead;
		hwCounter <= hwCounter + 1;
	endmethod

	method Bit#(32) echoData = echoDataReg;
	method Bit#(32) status = echoValid ? 1 : 0;
	method Bit#(32) counter = hwCounter;
	method Bit#(32) magic = 32'hDEADBEEF;
endmodule

endpackage