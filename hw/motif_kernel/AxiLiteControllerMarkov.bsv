package AxiLiteControllerMarkov;

// ============================================================
// Pins interface — directly maps to AXI4-Lite signals
// ============================================================
interface AxiLiteMarkovPinsIfc#(numeric type addrSz, numeric type dataSz);
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

// ============================================================
// Internal interface — BSV-side methods
// ============================================================
interface AxiLiteMarkovIfc#(numeric type addrSz, numeric type dataSz);
	interface AxiLiteMarkovPinsIfc#(addrSz, dataSz) pins;

	(* always_ready, result = "interrupt" *)
	method Bool interrupt;

	// DNA data written by host
	method Bit#(32) dna_data;
	method Bool dna_write_pulse;

	// Command written by host
	method Bit#(32) command;
	method Bool command_write_pulse;

	// Status driven by BSV
	(* always_ready, prefix = "" *)
	method Action drive_status(Bit#(32) value);
	(* always_ready, prefix = "" *)
	method Action drive_total_bases(Bit#(32) value);
	(* always_ready, prefix = "" *)
	method Action drive_magic(Bit#(32) value);
	(* always_ready, prefix = "" *)
	method Action drive_cycle_lo(Bit#(32) value);
	(* always_ready, prefix = "" *)
	method Action drive_cycle_hi(Bit#(32) value);

	// Base probabilities driven by BSV
	(* always_ready, prefix = "" *)
	method Action drive_base_prob_0(Bit#(32) value);
	(* always_ready, prefix = "" *)
	method Action drive_base_prob_1(Bit#(32) value);
	(* always_ready, prefix = "" *)
	method Action drive_base_prob_2(Bit#(32) value);
	(* always_ready, prefix = "" *)
	method Action drive_base_prob_3(Bit#(32) value);

	// Transition probability indexed read (from BRAM)
	method Bit#(8)  trans_prob_raddr;
	method Bool     trans_prob_ren;
	(* always_ready, prefix = "" *)
	method Action   drive_trans_prob_rdata(Bit#(32) value);
endinterface

// ============================================================
// BVI import of the Verilog module
// ============================================================
import "BVI" s_axi_control_markov =
module mkAxiLiteControllerMarkov#(Clock aclk, Reset arst) (AxiLiteMarkovIfc#(addrSz, dataSz));
	default_clock no_clock;
	default_reset no_reset;

	input_clock (ACLK) = aclk;
	input_reset (ARESET_N) = arst;

	parameter C_S_AXI_ADDR_WIDTH = valueOf(addrSz);
	parameter C_S_AXI_DATA_WIDTH = valueOf(dataSz);

	interface AxiLiteMarkovPinsIfc pins;
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

	method dna_data dna_data() clocked_by(aclk) reset_by(arst);
	method dna_write_pulse dna_write_pulse() clocked_by(aclk) reset_by(arst);
	method command command() clocked_by(aclk) reset_by(arst);
	method command_write_pulse command_write_pulse() clocked_by(aclk) reset_by(arst);

	method drive_status(status) enable((* inhigh *) drive_status_en) clocked_by(aclk) reset_by(arst);
	method drive_total_bases(total_bases) enable((* inhigh *) drive_total_bases_en) clocked_by(aclk) reset_by(arst);
	method drive_magic(magic) enable((* inhigh *) drive_magic_en) clocked_by(aclk) reset_by(arst);
	method drive_cycle_lo(cycle_lo) enable((* inhigh *) drive_cycle_lo_en) clocked_by(aclk) reset_by(arst);
	method drive_cycle_hi(cycle_hi) enable((* inhigh *) drive_cycle_hi_en) clocked_by(aclk) reset_by(arst);

	method drive_base_prob_0(base_prob_0) enable((* inhigh *) drive_base_prob_0_en) clocked_by(aclk) reset_by(arst);
	method drive_base_prob_1(base_prob_1) enable((* inhigh *) drive_base_prob_1_en) clocked_by(aclk) reset_by(arst);
	method drive_base_prob_2(base_prob_2) enable((* inhigh *) drive_base_prob_2_en) clocked_by(aclk) reset_by(arst);
	method drive_base_prob_3(base_prob_3) enable((* inhigh *) drive_base_prob_3_en) clocked_by(aclk) reset_by(arst);

	method trans_prob_raddr trans_prob_raddr() clocked_by(aclk) reset_by(arst);
	method trans_prob_ren trans_prob_ren() clocked_by(aclk) reset_by(arst);
	method drive_trans_prob_rdata(trans_prob_rdata) enable((* inhigh *) drive_trans_prob_rdata_en) clocked_by(aclk) reset_by(arst);

	schedule (
		pins_write_address, pins_write_address_valid, pins_awready,
		pins_write_data, pins_write_data_valid, pins_write_data_strb, pins_wready,
		pins_bvalid, pins_bresp, pins_write_response_ready,
		pins_read_address, pins_read_address_valid, pins_arready,
		pins_rvalid, pins_rresp, pins_rdata, pins_read_data_ready,
		interrupt,
		dna_data, dna_write_pulse, command, command_write_pulse,
		drive_status, drive_total_bases, drive_magic,
		drive_cycle_lo, drive_cycle_hi,
		drive_base_prob_0, drive_base_prob_1, drive_base_prob_2, drive_base_prob_3,
		trans_prob_raddr, trans_prob_ren, drive_trans_prob_rdata
	) CF (
		pins_write_address, pins_write_address_valid, pins_awready,
		pins_write_data, pins_write_data_valid, pins_write_data_strb, pins_wready,
		pins_bvalid, pins_bresp, pins_write_response_ready,
		pins_read_address, pins_read_address_valid, pins_arready,
		pins_rvalid, pins_rresp, pins_rdata, pins_read_data_ready,
		interrupt,
		dna_data, dna_write_pulse, command, command_write_pulse,
		drive_status, drive_total_bases, drive_magic,
		drive_cycle_lo, drive_cycle_hi,
		drive_base_prob_0, drive_base_prob_1, drive_base_prob_2, drive_base_prob_3,
		trans_prob_raddr, trans_prob_ren, drive_trans_prob_rdata
	);
endmodule

endpackage
