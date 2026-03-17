package AxiLiteControllerUser;

interface AxiLiteControllerUserPinsIfc#(numeric type addrSz, numeric type dataSz);
	(* always_ready, always_enabled, prefix = "" *)
	method Action write_address((* port = "awaddr" *) Bit#(addrSz) awaddr);
	(* always_ready, always_enabled, prefix = "" *)
	method Action write_address_valid((* port = "awvalid" *) Bool awvalid);
	(* always_ready, result = "awready" *)
	method Bool awready;

	(* always_ready, always_enabled, prefix = "" *)
	method Action write_data((* port = "wdata" *) Bit#(dataSz) wdata);
	(* always_ready, always_enabled, prefix = "" *)
	method Action write_data_valid((* port = "wvalid" *) Bool wvalid);
	(* always_ready, always_enabled, prefix = "" *)
	method Action write_data_strb((* port = "wstrb" *) Bit#(TDiv#(dataSz, 8)) wstrb);
	(* always_ready, result = "wready" *)
	method Bool wready;

	(* always_ready, result = "bvalid" *)
	method Bool bvalid;
	(* always_ready, result = "bresp" *)
	method Bit#(2) bresp;
	(* always_ready, always_enabled, prefix = "" *)
	method Action write_response_ready((* port = "bready" *) Bool bready);

	(* always_ready, always_enabled, prefix = "" *)
	method Action read_address((* port = "araddr" *) Bit#(addrSz) araddr);
	(* always_ready, always_enabled, prefix = "" *)
	method Action read_address_valid((* port = "arvalid" *) Bool arvalid);
	(* always_ready, result = "arready" *)
	method Bool arready;

	(* always_ready, result = "rvalid" *)
	method Bool rvalid;
	(* always_ready, result = "rresp" *)
	method Bit#(2) rresp;
	(* always_ready, result = "rdata" *)
	method Bit#(dataSz) rdata;
	(* always_ready, always_enabled, prefix = "" *)
	method Action read_data_ready((* port = "rready" *) Bool rready);
endinterface

interface AxiLiteControllerUserIfc#(numeric type addrSz, numeric type dataSz);
	interface AxiLiteControllerUserPinsIfc#(addrSz, dataSz) pins;
	(* always_ready, result = "interrupt" *)
	method Bool interrupt;
	method Bit#(32) echo_in;
	method Bool echo_write_pulse;
	method Bool counter_read_pulse;
	(* always_ready, prefix = "" *)
	method Action drive_echo_out(Bit#(32) value);
	(* always_ready, prefix = "" *)
	method Action drive_counter(Bit#(32) value);
	(* always_ready, prefix = "" *)
	method Action drive_status(Bit#(32) value);
	(* always_ready, prefix = "" *)
	method Action drive_magic(Bit#(32) value);
endinterface

import "BVI" s_axi_control_user =
module mkAxiLiteControllerUser#(Clock aclk, Reset arst) (AxiLiteControllerUserIfc#(addrSz, dataSz));
	default_clock no_clock;
	default_reset no_reset;

	input_clock (ACLK) = aclk;
	input_reset (ARESET_N) = arst;

	parameter C_S_AXI_ADDR_WIDTH = valueOf(addrSz);
	parameter C_S_AXI_DATA_WIDTH = valueOf(dataSz);

	interface AxiLiteControllerUserPinsIfc pins;
		method write_address(AWADDR) enable((* inhigh *) write_address_en) clocked_by(aclk) reset_by(arst);
		method write_address_valid(AWVALID) enable((* inhigh *) write_address_valid_en) clocked_by(aclk) reset_by(arst);
		method AWREADY awready() clocked_by(aclk) reset_by(arst);

		method write_data(WDATA) enable((* inhigh *) write_data_en) clocked_by(aclk) reset_by(arst);
		method write_data_valid(WVALID) enable((* inhigh *) write_data_valid_en) clocked_by(aclk) reset_by(arst);
		method write_data_strb(WSTRB) enable((* inhigh *) write_data_strb_en) clocked_by(aclk) reset_by(arst);
		method WREADY wready() clocked_by(aclk) reset_by(arst);

		method BVALID bvalid() clocked_by(aclk) reset_by(arst);
		method BRESP bresp() clocked_by(aclk) reset_by(arst);
		method write_response_ready(BREADY) enable((* inhigh *) write_response_ready_en) clocked_by(aclk) reset_by(arst);

		method read_address(ARADDR) enable((* inhigh *) read_address_en) clocked_by(aclk) reset_by(arst);
		method read_address_valid(ARVALID) enable((* inhigh *) read_address_valid_en) clocked_by(aclk) reset_by(arst);
		method ARREADY arready() clocked_by(aclk) reset_by(arst);

		method RVALID rvalid() clocked_by(aclk) reset_by(arst);
		method RRESP rresp() clocked_by(aclk) reset_by(arst);
		method RDATA rdata() clocked_by(aclk) reset_by(arst);
		method read_data_ready(RREADY) enable((* inhigh *) read_data_ready_en) clocked_by(aclk) reset_by(arst);
	endinterface

	method interrupt interrupt() clocked_by(aclk) reset_by(arst);
	method echo_in echo_in() clocked_by(aclk) reset_by(arst);
	method echo_write_pulse echo_write_pulse() clocked_by(aclk) reset_by(arst);
	method counter_read_pulse counter_read_pulse() clocked_by(aclk) reset_by(arst);
	method drive_echo_out(echo_out) enable((* inhigh *) drive_echo_out_en) clocked_by(aclk) reset_by(arst);
	method drive_counter(counter) enable((* inhigh *) drive_counter_en) clocked_by(aclk) reset_by(arst);
	method drive_status(status) enable((* inhigh *) drive_status_en) clocked_by(aclk) reset_by(arst);
	method drive_magic(magic) enable((* inhigh *) drive_magic_en) clocked_by(aclk) reset_by(arst);

	schedule (
		pins_write_address, pins_write_address_valid, pins_awready,
		pins_write_data, pins_write_data_valid, pins_write_data_strb, pins_wready,
		pins_bvalid, pins_bresp, pins_write_response_ready,
		pins_read_address, pins_read_address_valid, pins_arready,
		pins_rvalid, pins_rresp, pins_rdata, pins_read_data_ready,
		interrupt, echo_in, echo_write_pulse, counter_read_pulse,
		drive_echo_out, drive_counter, drive_status, drive_magic
	) CF (
		pins_write_address, pins_write_address_valid, pins_awready,
		pins_write_data, pins_write_data_valid, pins_write_data_strb, pins_wready,
		pins_bvalid, pins_bresp, pins_write_response_ready,
		pins_read_address, pins_read_address_valid, pins_arready,
		pins_rvalid, pins_rresp, pins_rdata, pins_read_data_ready,
		interrupt, echo_in, echo_write_pulse, counter_read_pulse,
		drive_echo_out, drive_counter, drive_status, drive_magic
	);
endmodule

endpackage