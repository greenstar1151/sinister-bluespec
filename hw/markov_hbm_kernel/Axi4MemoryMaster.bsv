package Axi4MemoryMaster;

import FIFO::*;
import FIFOF::*;

interface Axi4MemoryMasterPinsIfc#(numeric type addrSz, numeric type dataSz);
	// Write address
	(* always_ready, result="awvalid" *)
	method Bool awvalid;
	(* always_ready, always_enabled, prefix = "" *)
	method Action address_write((* port="awready" *) Bool awready);
	(* always_ready, result="awaddr" *)
	method Bit#(addrSz) awaddr;
	(* always_ready, result="awlen" *)
	method Bit#(8) awlen;

	// Write data
	(* always_ready, result="wvalid" *)
	method Bool wvalid;
	(* always_ready, always_enabled, prefix = "" *)
	method Action data_write((* port="wready" *) Bool wready);
	(* always_ready, result="wdata" *)
	method Bit#(dataSz) wdata;
	(* always_ready, result="wstrb" *)
	method Bit#(TDiv#(dataSz, 8)) wstrb;
	(* always_ready, result="wlast" *)
	method Bool wlast;

	// Write response
	(* always_ready, always_enabled, prefix = "" *)
	method Action write_resp_valid((* port="bvalid" *) Bool bvalid);
	(* always_ready, result="bready" *)
	method Bool bready;

	// Read address
	(* always_ready, result="arvalid" *)
	method Bool arvalid;
	(* always_ready, always_enabled, prefix = "" *)
	method Action read_address_ready((* port="arready" *) Bool arready);
	(* always_ready, result="araddr" *)
	method Bit#(addrSz) araddr;
	(* always_ready, result="arlen" *)
	method Bit#(8) arlen;

	// Read data
	(* always_ready, always_enabled, prefix = "" *)
	method Action read_data_valid((* port="rvalid" *) Bool rvalid);
	(* always_ready, result="rready" *)
	method Bool rready;
	(* always_ready, always_enabled, prefix = "" *)
	method Action read_data((* port="rdata" *) Bit#(dataSz) rdata);
	(* always_ready, always_enabled, prefix = "" *)
	method Action read_data_last((* port="rlast" *) Bool rlast);
endinterface

interface Axi4MemoryMasterIfc#(numeric type addrSz, numeric type dataSz);
	interface Axi4MemoryMasterPinsIfc#(addrSz, dataSz) pins;

	method Action readReq(Bit#(addrSz) addr, Bit#(addrSz) size);
	method ActionValue#(Bit#(dataSz)) read;

	method Action writeReq(Bit#(addrSz) addr, Bit#(addrSz) size);
	method Action write(Bit#(dataSz) data);
endinterface

module mkAxi4MemoryMaster(Axi4MemoryMasterIfc#(addrSz, dataSz))
	provisos(
		Add#(a__, 8, addrSz),
		Add#(b__, 512, dataSz)
	);
	Reg#(Bit#(16)) writeWordInflightUp <- mkReg(0);
	Reg#(Bit#(16)) writeWordInflightDn <- mkReg(0);
	FIFOF#(Tuple2#(Bit#(addrSz), Bit#(addrSz))) writeBurstReqQ <- mkFIFOF;
	FIFOF#(Bit#(dataSz)) writeWordQ <- mkFIFOF;

	Integer maxBurstWords = min(256, (4096 / (valueOf(dataSz) / 8)));
	Integer maxBurstBytes = maxBurstWords * (valueOf(dataSz) / 8);
	Integer wordByteSzBits = valueOf(TLog#(dataSz)) - 3;

	// ---- Write burst generation ----
	Reg#(Bit#(addrSz)) writeBurstCurAddr <- mkReg(0);
	Reg#(Bit#(addrSz)) writeBurstBytesLeft <- mkReg(0);
	FIFOF#(Tuple2#(Bit#(addrSz), Bit#(8))) writeBurstSubQ <- mkFIFOF;

	rule genWriteBurst;
		if (writeBurstBytesLeft > 0) begin
			writeBurstCurAddr <= writeBurstCurAddr + fromInteger(maxBurstBytes);
			if (writeBurstBytesLeft > fromInteger(maxBurstBytes)) begin
				writeBurstBytesLeft <= writeBurstBytesLeft - fromInteger(maxBurstBytes);
				writeBurstSubQ.enq(tuple2(writeBurstCurAddr, fromInteger(maxBurstWords - 1)));
			end else begin
				writeBurstSubQ.enq(tuple2(writeBurstCurAddr, truncate((writeBurstBytesLeft >> wordByteSzBits) - 1)));
				writeBurstBytesLeft <= 0;
			end
		end else begin
			writeBurstReqQ.deq;
			let r = writeBurstReqQ.first;
			let raddr = tpl_1(r);
			let rsz = tpl_2(r);
			if (rsz > fromInteger(maxBurstBytes)) begin
				writeBurstSubQ.enq(tuple2(raddr, fromInteger(maxBurstWords - 1)));
				writeBurstBytesLeft <= rsz - fromInteger(maxBurstBytes);
				writeBurstCurAddr <= raddr + fromInteger(maxBurstBytes);
			end else begin
				writeBurstSubQ.enq(tuple2(raddr, truncate((rsz >> wordByteSzBits) - 1)));
			end
		end
	endrule

	RWire#(Tuple2#(Bit#(addrSz), Bit#(8))) addressWriteW <- mkRWire;
	PulseWire addressWriteReadyW <- mkPulseWire;
	FIFO#(Bit#(8)) writeBurstCounterQ <- mkFIFO;

	rule applyAddressWrite;
		if (addressWriteReadyW) begin
			writeBurstSubQ.deq;
			addressWriteW.wset(writeBurstSubQ.first);
			writeBurstCounterQ.enq(tpl_2(writeBurstSubQ.first));
		end
	endrule

	RWire#(Tuple2#(Bit#(dataSz), Bool)) dataWriteW <- mkRWire;
	PulseWire dataWriteReadyW <- mkPulseWire;
	Reg#(Bit#(8)) curBurstLeft <- mkReg(0);

	rule applyDataWrite;
		if (dataWriteReadyW) begin
			Bit#(8) nextBurstLeft = ?;
			if (curBurstLeft == 0) begin
				writeBurstCounterQ.deq;
				nextBurstLeft = writeBurstCounterQ.first;
			end else begin
				nextBurstLeft = curBurstLeft - 1;
			end
			curBurstLeft <= nextBurstLeft;
			writeWordQ.deq;
			dataWriteW.wset(tuple2(writeWordQ.first, nextBurstLeft == 0));
		end
	endrule

	// ---- Read burst generation ----
	FIFOF#(Tuple2#(Bit#(addrSz), Bit#(addrSz))) readBurstReqQ <- mkFIFOF;
	Reg#(Bit#(addrSz)) readBurstCurAddr <- mkReg(0);
	Reg#(Bit#(addrSz)) readBurstBytesLeft <- mkReg(0);
	FIFOF#(Tuple2#(Bit#(addrSz), Bit#(8))) readBurstSubQ <- mkFIFOF;

	rule genReadBurst;
		if (readBurstBytesLeft > 0) begin
			readBurstCurAddr <= readBurstCurAddr + fromInteger(maxBurstBytes);
			if (readBurstBytesLeft > fromInteger(maxBurstBytes)) begin
				readBurstBytesLeft <= readBurstBytesLeft - fromInteger(maxBurstBytes);
				readBurstSubQ.enq(tuple2(readBurstCurAddr, fromInteger(maxBurstWords - 1)));
			end else begin
				readBurstSubQ.enq(tuple2(readBurstCurAddr, truncate((readBurstBytesLeft >> wordByteSzBits) - 1)));
				readBurstBytesLeft <= 0;
			end
		end else begin
			readBurstReqQ.deq;
			let r = readBurstReqQ.first;
			let raddr = tpl_1(r);
			let rsz = tpl_2(r);
			if (rsz > fromInteger(maxBurstBytes)) begin
				readBurstSubQ.enq(tuple2(raddr, fromInteger(maxBurstWords - 1)));
				readBurstBytesLeft <= rsz - fromInteger(maxBurstBytes);
				readBurstCurAddr <= raddr + fromInteger(maxBurstBytes);
			end else begin
				readBurstSubQ.enq(tuple2(raddr, truncate((rsz >> wordByteSzBits) - 1)));
			end
		end
	endrule

	PulseWire readAddressReadyW <- mkPulseWire;
	RWire#(Tuple2#(Bit#(addrSz), Bit#(8))) readAddressW <- mkRWire;

	rule applyReadAddress;
		if (readAddressReadyW) begin
			readBurstSubQ.deq;
			readAddressW.wset(readBurstSubQ.first);
		end
	endrule

	PulseWire readDataValidW <- mkPulseWire;
	PulseWire readDataReadyW <- mkPulseWire;
	FIFOF#(Bit#(dataSz)) readWordQ <- mkFIFOF;
	RWire#(Bit#(dataSz)) readDataWordW <- mkRWire;

	rule handleReadWord;
		if (readWordQ.notFull) begin
			readDataReadyW.send;
			if (readDataValidW) begin
				readWordQ.enq(fromMaybe(?, readDataWordW.wget));
			end
		end
	endrule

	// ---- Pins interface ----
	interface Axi4MemoryMasterPinsIfc pins;
		method Bool awvalid;
			return isValid(addressWriteW.wget);
		endmethod
		method Action address_write(Bool awready);
			if (awready) addressWriteReadyW.send;
		endmethod
		method Bit#(addrSz) awaddr;
			let a = fromMaybe(?, addressWriteW.wget);
			return tpl_1(a);
		endmethod
		method Bit#(8) awlen;
			let a = fromMaybe(?, addressWriteW.wget);
			return tpl_2(a);
		endmethod

		method Bool wvalid;
			return isValid(dataWriteW.wget);
		endmethod
		method Action data_write(Bool wready);
			if (wready) dataWriteReadyW.send;
		endmethod
		method Bit#(dataSz) wdata;
			let d = fromMaybe(?, dataWriteW.wget);
			return tpl_1(d);
		endmethod
		method Bit#(TDiv#(dataSz, 8)) wstrb;
			return (-1);
		endmethod
		method Bool wlast;
			let d = fromMaybe(?, dataWriteW.wget);
			return tpl_2(d);
		endmethod

		method Action write_resp_valid(Bool bvalid);
			if (bvalid) writeWordInflightDn <= writeWordInflightDn + 1;
		endmethod
		method Bool bready;
			return True;
		endmethod

		// Read address
		method Bool arvalid;
			return isValid(readAddressW.wget);
		endmethod
		method Action read_address_ready(Bool arready);
			if (arready) readAddressReadyW.send;
		endmethod
		method Bit#(addrSz) araddr;
			let a = fromMaybe(?, readAddressW.wget);
			return tpl_1(a);
		endmethod
		method Bit#(8) arlen;
			let a = fromMaybe(?, readAddressW.wget);
			return tpl_2(a);
		endmethod

		// Read data
		method Action read_data_valid(Bool rvalid);
			if (rvalid) readDataValidW.send;
		endmethod
		method Bool rready;
			return readDataReadyW;
		endmethod
		method Action read_data(Bit#(dataSz) rdata);
			readDataWordW.wset(rdata);
		endmethod
		method Action read_data_last(Bool rlast);
		endmethod
	endinterface

	// ---- User interface ----
	method Action readReq(Bit#(addrSz) addr, Bit#(addrSz) size);
		readBurstReqQ.enq(tuple2(addr, size));
	endmethod
	method ActionValue#(Bit#(dataSz)) read;
		readWordQ.deq;
		return readWordQ.first;
	endmethod

	method Action writeReq(Bit#(addrSz) addr, Bit#(addrSz) size);
		writeBurstReqQ.enq(tuple2(addr, size));
	endmethod
	method Action write(Bit#(dataSz) data);
		writeWordQ.enq(data);
	endmethod
endmodule

endpackage
