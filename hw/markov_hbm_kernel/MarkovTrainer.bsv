package MarkovTrainer;

import Vector::*;
import BRAM::*;
import FIFO::*;
import FIFOF::*;

// ============================================================
// Types
// ============================================================
typedef Bit#(2) DNABase;
typedef Bit#(6) ContextIdx;  // 4^3 = 64 possible 3-base contexts
typedef UInt#(32) Count;

typedef enum {
	ST_IDLE,        // 0 — waiting
	ST_TRAINING,    // 1 — receiving DNA bases
	ST_NORMALIZING, // 2 — running divider over counters
	ST_DONE         // 3 — results ready
} MarkovState deriving (Bits, Eq, FShow);

// Commands from host
typedef Bit#(32) Command;
Command cmdReset     = 32'h01; 
Command cmdNormalize = 32'h02;

// ============================================================
// Interface
// ============================================================
interface MarkovTrainerIfc;
	// DNA base input from host (1 base at a time)
	method Action putBase(Bit#(2) base, Bool valid, Bool seqLast);

	// Command input
	method Action putCommand(Bit#(32) cmd);

	// Status readback
	method Bit#(32) getStatus;
	method Bit#(32) getTotalBases;
	method Bit#(32) getMagic;
	method Bit#(32) getCycleLo;
	method Bit#(32) getCycleHi;

	// Base probabilities (Q16.16)
	method Bit#(32) getBaseProb(UInt#(2) idx);

	// Transition probability indexed read (for AXI readback)
	method Bit#(32) getTransProb(Bit#(8) addr);
endinterface

// ============================================================
// Implementation
// ============================================================
module mkMarkovTrainer(MarkovTrainerIfc);

	// --- State ---
	Reg#(MarkovState) state <- mkReg(ST_IDLE);
	Reg#(UInt#(32)) totalBases <- mkReg(0);

	// --- Free-running 64-bit cycle counter ---
	Reg#(UInt#(64)) cycleCounter <- mkReg(0);

	rule countCycles;
		cycleCounter <= cycleCounter + 1;
	endrule

	// --- Context tracking ---
	// Shift register for last 3 bases
	Reg#(DNABase) ctx0 <- mkReg(0); // oldest (pos-3)
	Reg#(DNABase) ctx1 <- mkReg(0); // middle  (pos-2)
	Reg#(DNABase) ctx2 <- mkReg(0); // newest  (pos-1)
	Reg#(Bool)    ctx0v <- mkReg(False);
	Reg#(Bool)    ctx1v <- mkReg(False);
	Reg#(Bool)    ctx2v <- mkReg(False);
	Reg#(UInt#(3)) posInSeq <- mkReg(0); // saturates at 3+

	// --- Counters ---
	// base_counts[4] — small enough for registers
	Vector#(4, Reg#(Count)) baseCounts <- replicateM(mkReg(1)); // pseudocount=1

	// transition_counts[64][4] = 256 counters
	// Use a Vector of registers (fits in LUTs/registers at 256×32 = 8KB)
	Vector#(256, Reg#(Count)) transCounts <- replicateM(mkReg(1)); // pseudocount=1

	// --- Result storage ---
	// base_probs[4] as Q16.16
	Vector#(4, Reg#(Bit#(32))) baseProbs <- replicateM(mkReg(0));
	// trans_probs[256] as Q16.16
	Vector#(256, Reg#(Bit#(32))) transProbs <- replicateM(mkReg(0));

	// --- Normalizer state ---
	Reg#(Bool) normBaseDone <- mkReg(False);
	Reg#(UInt#(7)) normCtx <- mkReg(0);       // 0..63 for transition rows
	Reg#(UInt#(2)) normBase <- mkReg(0);       // 0..3 within a row
	Reg#(UInt#(32)) normRowTotal <- mkReg(0);  // sum of row
	Reg#(Bool) normComputingSum <- mkReg(True);

	// --- Divider ---
	// Compute (numer << 16) / denom → Q16.16 fixed-point result.
	// Uses restoring binary long division. The dividend has up to 48 bits,
	// so we run 48 steps consuming all dividend bits, MSB first.
	// The quotient is at most 32 bits for our probability values (≤ 1.0 → max 0x10000).
	Reg#(Bool) divBusy <- mkReg(False);
	Reg#(UInt#(64)) divPartial <- mkReg(0);   // partial remainder (upper bits)
	Reg#(UInt#(64)) divDivisor <- mkReg(1);
	Reg#(Bit#(48)) divDividend <- mkReg(0);   // remaining dividend bits to shift in
	Reg#(Bit#(48)) divQuotient48 <- mkReg(0);
	Reg#(UInt#(6))  divBitIdx <- mkReg(0);    // 0..47
	FIFOF#(Bit#(32)) divResult <- mkFIFOF;

	rule doDivStep(divBusy);
		// Shift partial left by 1 and bring in the next dividend bit (MSB first)
		UInt#(64) p = (divPartial << 1) | zeroExtend(unpack(divDividend[47]));
		Bit#(48) dd = divDividend << 1;
		Bit#(48) q = divQuotient48;

		if (p >= divDivisor) begin
			p = p - divDivisor;
			q[47 - divBitIdx] = 1;
		end

		if (divBitIdx == 47) begin
			divBusy <= False;
			divResult.enq(q[31:0]); // lower 32 bits of quotient
		end else begin
			divPartial <= p;
			divDividend <= dd;
			divQuotient48 <= q;
			divBitIdx <= divBitIdx + 1;
		end
	endrule

	// Start: computes (numerator << 16) / denominator as Q16.16
	function Action startDiv(UInt#(32) numer, UInt#(32) denom);
		action
			Bit#(48) dividend = zeroExtend(pack(numer)) << 16;
			divPartial <= 0;
			divDividend <= dividend;
			divDivisor <= zeroExtend(denom);
			divQuotient48 <= 0;
			divBitIdx <= 0;
			divBusy <= True;
		endaction
	endfunction

	// --- Normalization FSM ---
	// Phase 1: normalize base_probs[0..3]
	// Phase 2: for each of 64 contexts, normalize 4 transition probs

	Reg#(UInt#(2)) normBaseIdx <- mkReg(0);
	Reg#(Bool) normDivPending <- mkReg(False);

	rule normalizeBaseProbs(state == ST_NORMALIZING && !normBaseDone && !divBusy && !normDivPending);
		// First compute base total
		UInt#(32) baseTotal = baseCounts[0] + baseCounts[1] + baseCounts[2] + baseCounts[3];
		// Start dividing baseCounts[normBaseIdx] / baseTotal
		startDiv(baseCounts[normBaseIdx], baseTotal);
		normDivPending <= True;
	endrule

	rule normalizeBaseCollect(state == ST_NORMALIZING && !normBaseDone && normDivPending && divResult.notEmpty);
		baseProbs[normBaseIdx] <= divResult.first;
		divResult.deq;
		normDivPending <= False;
		if (normBaseIdx == 3) begin
			normBaseDone <= True;
			normCtx <= 0;
			normBase <= 0;
			normComputingSum <= True;
		end else begin
			normBaseIdx <= normBaseIdx + 1;
		end
	endrule

	// Phase 2: transition probs
	rule normalizeTransSum(state == ST_NORMALIZING && normBaseDone && normComputingSum && !divBusy && !normDivPending);
		// Compute row total for context normCtx
		UInt#(7) ctx7 = zeroExtend(normCtx);
		UInt#(32) rowTotal = transCounts[{pack(ctx7), 2'b00}]
		                   + transCounts[{pack(ctx7), 2'b01}]
		                   + transCounts[{pack(ctx7), 2'b10}]
		                   + transCounts[{pack(ctx7), 2'b11}];
		normRowTotal <= rowTotal;
		normComputingSum <= False;
		normBase <= 0;
	endrule

	rule normalizeTransDiv(state == ST_NORMALIZING && normBaseDone && !normComputingSum && !divBusy && !normDivPending);
		UInt#(7) ctx7 = zeroExtend(normCtx);
		Bit#(8) idx = {pack(ctx7)[5:0], pack(normBase)};
		startDiv(transCounts[idx], normRowTotal);
		normDivPending <= True;
	endrule

	rule normalizeTransCollect(state == ST_NORMALIZING && normBaseDone && !normComputingSum && normDivPending && divResult.notEmpty);
		UInt#(7) ctx7 = zeroExtend(normCtx);
		Bit#(8) idx = {pack(ctx7)[5:0], pack(normBase)};
		transProbs[idx] <= divResult.first;
		divResult.deq;
		normDivPending <= False;

		if (normBase == 3) begin
			if (normCtx == 63) begin
				state <= ST_DONE;
			end else begin
				normCtx <= normCtx + 1;
				normComputingSum <= True;
			end
		end else begin
			normBase <= normBase + 1;
		end
	endrule

	// --- Reset logic ---
	function Action doReset();
		action
			state <= ST_IDLE;
			totalBases <= 0;
			ctx0 <= 0; ctx1 <= 0; ctx2 <= 0;
			ctx0v <= False; ctx1v <= False; ctx2v <= False;
			posInSeq <= 0;
			normBaseDone <= False;
			normBaseIdx <= 0;
			normDivPending <= False;
			normCtx <= 0;
			normBase <= 0;
			normComputingSum <= True;
			for (Integer i = 0; i < 4; i = i + 1) begin
				baseCounts[i] <= 1;  // pseudocount
				baseProbs[i] <= 0;
			end
			for (Integer i = 0; i < 256; i = i + 1) begin
				transCounts[i] <= 1;  // pseudocount
				transProbs[i] <= 0;
			end
		endaction
	endfunction

	// ============================================================
	// Methods
	// ============================================================
	method Action putBase(Bit#(2) base, Bool valid, Bool seqLast) if (state == ST_IDLE || state == ST_TRAINING);
		// Transition to training on first base
		if (state == ST_IDLE)
			state <= ST_TRAINING;

		// Compute new context values (unified single write per register)
		DNABase new_ctx0;
		DNABase new_ctx1;
		DNABase new_ctx2;
		Bool new_ctx0v;
		Bool new_ctx1v;
		Bool new_ctx2v;
		UInt#(3) new_pos;

		if (seqLast) begin
			// Sequence boundary — reset context for next sequence
			new_ctx0 = 0; new_ctx1 = 0; new_ctx2 = 0;
			new_ctx0v = False; new_ctx1v = False; new_ctx2v = False;
			new_pos = 0;
		end else if (valid) begin
			// Valid base — shift context
			new_ctx0 = ctx1;
			new_ctx0v = ctx1v;
			new_ctx1 = ctx2;
			new_ctx1v = ctx2v;
			new_ctx2 = base;
			new_ctx2v = True;
			new_pos = (posInSeq < 7) ? posInSeq + 1 : 7;
		end else begin
			// Invalid base (N) — invalidate context chain
			new_ctx0 = ctx0;
			new_ctx0v = False;
			new_ctx1 = ctx1;
			new_ctx1v = False;
			new_ctx2 = ctx2;
			new_ctx2v = False;
			new_pos = 0;
		end

		ctx0 <= new_ctx0;
		ctx1 <= new_ctx1;
		ctx2 <= new_ctx2;
		ctx0v <= new_ctx0v;
		ctx1v <= new_ctx1v;
		ctx2v <= new_ctx2v;
		posInSeq <= new_pos;

		if (valid) begin
			// Update base count
			baseCounts[base] <= baseCounts[base] + 1;
			totalBases <= totalBases + 1;

			// Update transition count if we have enough context
			if (posInSeq >= 3 && ctx0v && ctx1v && ctx2v) begin
				ContextIdx ctx = {ctx0, ctx1, ctx2};
				Bit#(8) idx = {ctx, base};
				transCounts[idx] <= transCounts[idx] + 1;
			end
		end
	endmethod

	method Action putCommand(Bit#(32) cmd);
		if (cmd == cmdReset) begin
			doReset;
		end else if (cmd == cmdNormalize && (state == ST_TRAINING || state == ST_IDLE)) begin
			state <= ST_NORMALIZING;
			normBaseDone <= False;
			normBaseIdx <= 0;
			normDivPending <= False;
			normCtx <= 0;
			normBase <= 0;
			normComputingSum <= True;
		end
	endmethod

	method Bit#(32) getStatus;
		return pack(zeroExtend(pack(state)));
	endmethod

	method Bit#(32) getTotalBases;
		return pack(totalBases);
	endmethod

	method Bit#(32) getMagic;
		return 32'h4D480003; // "MH" + markov order 3 (HBM version)
	endmethod

	method Bit#(32) getCycleLo;
		return pack(cycleCounter)[31:0];
	endmethod

	method Bit#(32) getCycleHi;
		return pack(cycleCounter)[63:32];
	endmethod

	method Bit#(32) getBaseProb(UInt#(2) idx);
		return baseProbs[idx];
	endmethod

	method Bit#(32) getTransProb(Bit#(8) addr);
		return transProbs[addr];
	endmethod
endmodule

endpackage
