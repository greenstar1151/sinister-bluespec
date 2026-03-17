import AxiLiteControllerUser::*;
import KernelMain::*;

interface KernelTopIfc;
	(* always_ready *)
	interface AxiLiteControllerUserPinsIfc#(12, 32) s_axi_control;
endinterface

(* synthesize *)
(* default_reset = "ap_rst_n", default_clock_osc = "ap_clk" *)
module kernel(KernelTopIfc);
	Clock defaultClock <- exposeCurrentClock;
	Reset defaultReset <- exposeCurrentReset;

	AxiLiteControllerUserIfc#(12, 32) axiControl <- mkAxiLiteControllerUser(defaultClock, defaultReset);
	KernelMainIfc kernelMain <- mkKernelMain;

	rule handleHostWrite(axiControl.echo_write_pulse);
		kernelMain.hostWrite(axiControl.echo_in);
	endrule

	rule handleCounterRead(axiControl.counter_read_pulse);
		kernelMain.counterRead;
	endrule

	rule driveReadbackRegisters;
		axiControl.drive_echo_out(kernelMain.echoData);
		axiControl.drive_counter(kernelMain.counter);
		axiControl.drive_status(kernelMain.status);
		axiControl.drive_magic(kernelMain.magic);
	endrule

	interface s_axi_control = axiControl.pins;
endmodule