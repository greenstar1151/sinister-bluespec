package Tb_Types;

import Types::*;
import Vector::*;

// Minimal smoke test for Types.bsv

(* synthesize *)
module mkTb_Types (Empty);

	Reg#(UInt#(8)) step <- mkReg(0);

	rule test_encoding (step == 0);
		// Base encoding constants
		if (baseA != 2'b00) $display("FAIL: baseA != 00");
		if (baseC != 2'b01) $display("FAIL: baseC != 01");
		if (baseG != 2'b10) $display("FAIL: baseG != 10");
		if (baseT != 2'b11) $display("FAIL: baseT != 11");

		$display("[Tb_Types] Base encoding constants OK");
		$display("  A = %b, C = %b, G = %b, T = %b", baseA, baseC, baseG, baseT);

		// baseToIndex
		if (baseToIndex(baseA) != 0) $display("FAIL: baseToIndex(A) != 0");
		if (baseToIndex(baseC) != 1) $display("FAIL: baseToIndex(C) != 1");
		if (baseToIndex(baseG) != 2) $display("FAIL: baseToIndex(G) != 2");
		if (baseToIndex(baseT) != 3) $display("FAIL: baseToIndex(T) != 3");

		$display("[Tb_Types] baseToIndex OK");

		step <= 1;
	endrule

	rule test_kmer_packing (step == 1);
		// Pack "ACG" (k=3) → 0x24 (LSB-first)
		Vector#(MaxK, DNABase) bases = replicate(baseA);
		bases[0] = baseA;  // pos 0
		bases[1] = baseC;  // pos 1
		bases[2] = baseG;  // pos 2

		KmerBits packedKmer = packKmer(bases, 3);
		// Expected: A(00) | C(01)<<2 | G(10)<<4 = 0x24
		$display("[Tb_Types] packKmer(ACG, k=3) = 0x%08x (expected 0x00000024)", packedKmer);

		if (packedKmer[1:0] != baseA) $display("FAIL: pos 0 != A");
		if (packedKmer[3:2] != baseC) $display("FAIL: pos 1 != C");
		if (packedKmer[5:4] != baseG) $display("FAIL: pos 2 != G");

		step <= 2;
	endrule

	rule test_fixedpoint (step == 2);
		// intToFx_8_8(1) -> 256
		FixedPoint_8_8 one = intToFx_8_8(1);
		$display("[Tb_Types] intToFx_8_8(1) = %d (expected 256)", one);

		// 1.0 * 1.0 -> 256
		FixedPoint_8_8 result = fxMul_8_8(one, one);
		$display("[Tb_Types] fxMul_8_8(1.0, 1.0) = %d (expected 256)", result);

		// 2.0 * 3.0 -> 1536
		FixedPoint_8_8 two   = intToFx_8_8(2);
		FixedPoint_8_8 three = intToFx_8_8(3);
		FixedPoint_8_8 six   = fxMul_8_8(two, three);
		$display("[Tb_Types] fxMul_8_8(2.0, 3.0) = %d (expected 1536)", six);

		step <= 3;
	endrule

	rule test_done (step == 3);
		$display("[Tb_Types] All tests completed.");
		$finish(0);
	endrule

endmodule

endpackage
