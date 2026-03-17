package KernelTop;

import AxiLiteControllerMarkov::*;
import MarkovTrainer::*;

interface KernelTopIfc;
	(* always_ready *)
	interface AxiLiteMarkovPinsIfc#(12, 32) s_axi_control;
endinterface

(* synthesize *)
(* default_reset = "ap_rst_n", default_clock_osc = "ap_clk" *)
module kernel(KernelTopIfc);
	Clock defaultClock <- exposeCurrentClock;
	Reset defaultReset <- exposeCurrentReset;

	AxiLiteMarkovIfc#(12, 32) axiControl <- mkAxiLiteControllerMarkov(defaultClock, defaultReset);
	MarkovTrainerIfc trainer <- mkMarkovTrainer;

	// --- DNA data from host → trainer ---
	rule handleDnaWrite(axiControl.dna_write_pulse);
		Bit#(32) data = axiControl.dna_data;
		Bit#(2) base = data[1:0];
		Bool valid = unpack(data[2]);
		Bool seqLast = unpack(data[3]);
		trainer.putBase(base, valid, seqLast);
	endrule

	// --- Command from host → trainer ---
	rule handleCommand(axiControl.command_write_pulse);
		trainer.putCommand(axiControl.command);
	endrule

	// --- Drive readback registers ---
	rule driveStatusRegs;
		axiControl.drive_status(trainer.getStatus);
		axiControl.drive_total_bases(trainer.getTotalBases);
		axiControl.drive_magic(trainer.getMagic);
		axiControl.drive_cycle_lo(trainer.getCycleLo);
		axiControl.drive_cycle_hi(trainer.getCycleHi);
	endrule

	rule driveBaseProbs;
		axiControl.drive_base_prob_0(trainer.getBaseProb(0));
		axiControl.drive_base_prob_1(trainer.getBaseProb(1));
		axiControl.drive_base_prob_2(trainer.getBaseProb(2));
		axiControl.drive_base_prob_3(trainer.getBaseProb(3));
	endrule

	// --- Transition probability indexed read ---
	rule driveTransProb;
		axiControl.drive_trans_prob_rdata(
			trainer.getTransProb(axiControl.trans_prob_raddr)
		);
	endrule

	interface s_axi_control = axiControl.pins;
endmodule

endpackage
