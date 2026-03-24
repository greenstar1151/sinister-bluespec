package KernelTop;

import AxiLiteControllerMarkovHbm::*;
import Axi4MemoryMaster::*;
import MarkovTrainer::*;

import FIFO::*;
import FIFOF::*;
import Vector::*;

// ============================================================
// Top-level interface
// ============================================================
interface KernelTopIfc;
	(* always_ready *)
	interface AxiLiteMarkovHbmPinsIfc#(12, 32) s_axi_control;
	(* always_ready *)
	interface Axi4MemoryMasterPinsIfc#(64, 512) m_axi_gmem;
endinterface

// ============================================================
// Commands (match host register writes)
// ============================================================
typedef Bit#(32) Command;
Command cmdReset = 32'h01;
Command cmdStart = 32'h02;

// ============================================================
// States for the top-level FSM
// ============================================================
typedef enum {
	TOP_IDLE,         // 0 — waiting for start command
	TOP_READING,      // 1 — reading DNA from HBM + training
	TOP_NORMALIZING,  // 2 — normalizing counters (divider running)
	TOP_DONE          // 3 — results ready
} TopState deriving (Bits, Eq, FShow);

(* synthesize *)
(* default_reset = "ap_rst_n", default_clock_osc = "ap_clk" *)
module kernel(KernelTopIfc);
	Clock defaultClock <- exposeCurrentClock;
	Reset defaultReset <- exposeCurrentReset;

	// --- Sub-modules ---
	AxiLiteMarkovHbmIfc#(12, 32) axiControl <- mkAxiLiteControllerMarkovHbm(defaultClock, defaultReset);
	MarkovTrainerIfc trainer <- mkMarkovTrainer;
	Axi4MemoryMasterIfc#(64, 512) axi4mem <- mkAxi4MemoryMaster;

	// --- Top-level state ---
	Reg#(TopState) topState <- mkReg(TOP_IDLE);

	// --- Internal performance counters (jitter-free) ---
	Reg#(UInt#(64)) perfTotal <- mkReg(0);      // start → done
	Reg#(UInt#(64)) perfRead  <- mkReg(0);      // start → normalize begin
	Reg#(UInt#(64)) perfNorm  <- mkReg(0);      // normalize begin → done
	Reg#(Bool) perfRunning <- mkReg(False);      // total counter active
	Reg#(Bool) perfReadPhase <- mkReg(False);    // read+train phase active
	Reg#(Bool) perfNormPhase <- mkReg(False);    // normalize phase active

	rule countPerfTotal(perfRunning);
		perfTotal <= perfTotal + 1;
	endrule

	rule countPerfRead(perfReadPhase);
		perfRead <= perfRead + 1;
	endrule

	rule countPerfNorm(perfNormPhase);
		perfNorm <= perfNorm + 1;
	endrule

	// --- HBM reader state ---
	// Counts remaining 512-bit words to fetch from the AXI read response
	Reg#(Bit#(512)) wordBuf <- mkReg(0);
	Reg#(UInt#(7)) bytesInBuf <- mkReg(0);   // 0..64
	Reg#(UInt#(32)) entriesLeft <- mkReg(0);  // total entries still to process
	Reg#(Bool) readReqSent <- mkReg(False);
	Reg#(Bool) triggerNormalize <- mkReg(False);

	// ============================================================
	// Command handling from host
	// ============================================================
	rule handleCommand(axiControl.command_write_pulse);
		Bit#(32) cmd = axiControl.command;
		if (cmd == cmdReset) begin
			topState <= TOP_IDLE;
			bytesInBuf <= 0;
			entriesLeft <= 0;
			readReqSent <= False;
			triggerNormalize <= False;
			perfRunning <= False;
			perfReadPhase <= False;
			perfNormPhase <= False;
			trainer.putCommand(32'h01); // reset trainer
		end else if (cmd == cmdStart && topState == TOP_IDLE) begin
			// Read HBM pointer and entry count from AXI-Lite registers
			Bit#(64) dnaPtr = {axiControl.dna_ptr_hi, axiControl.dna_ptr_lo};
			Bit#(32) numEntries = axiControl.num_entries;

			// Compute byte-aligned read size (round up to 64-byte boundary)
			// Each entry = 1 byte, AXI beat = 64 bytes
			Bit#(64) readBytes = zeroExtend(numEntries);
			// Round up to next multiple of 64
			Bit#(64) readBytesAligned = ((readBytes + 63) >> 6) << 6;

			axi4mem.readReq(dnaPtr, readBytesAligned);
			entriesLeft <= unpack(numEntries);
			readReqSent <= True;
			bytesInBuf <= 0;
			topState <= TOP_READING;
			// Start perf counters
			perfTotal <= 0;
			perfRead  <= 0;
			perfNorm  <= 0;
			perfRunning <= True;
			perfReadPhase <= True;
			perfNormPhase <= False;
		end
	endrule

	// ============================================================
	// HBM Read → Unpack → Feed to MarkovTrainer
	// ============================================================

	// Fetch a 512-bit word when the byte buffer is empty
	rule fetchWord(topState == TOP_READING && bytesInBuf == 0 && entriesLeft > 0);
		let word <- axi4mem.read;
		wordBuf <= word;
		// How many valid bytes in this word?
		UInt#(7) validBytes = (entriesLeft >= 64) ? 64 : truncate(entriesLeft);
		bytesInBuf <= validBytes;
	endrule

	// Extract one byte at a time and feed to trainer
	rule feedTrainer(topState == TOP_READING && bytesInBuf > 0);
		Bit#(8) byte_val = wordBuf[7:0];
		wordBuf <= wordBuf >> 8;
		bytesInBuf <= bytesInBuf - 1;
		entriesLeft <= entriesLeft - 1;

		// Decode: bits [1:0]=base, bit[2]=valid, bit[3]=seqLast
		Bit#(2) base = byte_val[1:0];
		Bool valid = unpack(byte_val[2]);
		Bool seqLast = unpack(byte_val[3]);
		trainer.putBase(base, valid, seqLast);

		// If this was the last entry, trigger normalization next cycle
		if (entriesLeft == 1) begin
			triggerNormalize <= True;
		end
	endrule

	// Start normalization after all entries consumed
	rule doNormalize(triggerNormalize);
		trainer.putCommand(32'h02); // CMD_NORMALIZE
		triggerNormalize <= False;
		topState <= TOP_NORMALIZING;
		// Switch perf phase: read→norm
		perfReadPhase <= False;
		perfNormPhase <= True;
	endrule

	// Watch for trainer to finish normalizing
	rule watchDone(topState == TOP_NORMALIZING);
		// MarkovTrainer status: 3 = ST_DONE
		if (trainer.getStatus == 32'h03) begin
			topState <= TOP_DONE;
			// Stop all perf counters
			perfRunning <= False;
			perfNormPhase <= False;
		end
	endrule

	// ============================================================
	// Drive AXI-Lite readback registers
	// ============================================================
	rule driveStatusRegs;
		axiControl.drive_status(pack(zeroExtend(pack(topState))));
		axiControl.drive_total_bases(trainer.getTotalBases);
		axiControl.drive_magic(trainer.getMagic);
		axiControl.drive_cycle_lo(trainer.getCycleLo);
		axiControl.drive_cycle_hi(trainer.getCycleHi);
	endrule

	rule drivePerfRegs;
		axiControl.drive_perf_total_lo(pack(perfTotal)[31:0]);
		axiControl.drive_perf_total_hi(pack(perfTotal)[63:32]);
		axiControl.drive_perf_read_lo(pack(perfRead)[31:0]);
		axiControl.drive_perf_read_hi(pack(perfRead)[63:32]);
		axiControl.drive_perf_norm_lo(pack(perfNorm)[31:0]);
		axiControl.drive_perf_norm_hi(pack(perfNorm)[63:32]);
	endrule

	rule driveBaseProbs;
		axiControl.drive_base_prob_0(trainer.getBaseProb(0));
		axiControl.drive_base_prob_1(trainer.getBaseProb(1));
		axiControl.drive_base_prob_2(trainer.getBaseProb(2));
		axiControl.drive_base_prob_3(trainer.getBaseProb(3));
	endrule

	rule driveTransProb;
		axiControl.drive_trans_prob_rdata(
			trainer.getTransProb(axiControl.trans_prob_raddr)
		);
	endrule

	// ============================================================
	// Interfaces
	// ============================================================
	interface s_axi_control = axiControl.pins;
	interface m_axi_gmem = axi4mem.pins;
endmodule

endpackage
