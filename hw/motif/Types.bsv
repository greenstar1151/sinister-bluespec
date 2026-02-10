package Types;

import Vector::*;

// DNA encoding: A=00, C=01, G=10, T=11

typedef Bit#(2) DNABase;

DNABase baseA = 2'b00;
DNABase baseC = 2'b01;
DNABase baseG = 2'b10;
DNABase baseT = 2'b11;

// Base + valid flag (for masking N's)
typedef struct {
	DNABase base;
	Bool    valid;
} DNABaseValid deriving (Bits, Eq, FShow);


// K-mer parameters

typedef 16 MaxK;
typedef Bit#(TMul#(MaxK, 2)) KmerBits;  // Bit#(32) — packed k-mer

typedef 4 AlphabetSize;  // DNA = {A, C, G, T}


// Sequence parameters (morbius defaults)

typedef 1000 MaxSeqLength;
typedef Bit#(TMul#(MaxSeqLength, 2)) SeqBits;  // 2000 bits per sequence

// 2048-bit boundary for DRAM alignment
typedef 2048 SeqStoredBits;


// Fixed-point number types

// Q8.8
typedef Int#(16) FixedPoint_8_8;

// Q4.12 (higher precision)
typedef Int#(16) FixedPoint_4_12;


// Per-kmer count (ZOOPS: max = number of sequences)
typedef UInt#(16) KmerCount;


// PWM (matrix[position][base], transposed from SW)

typedef 32 MaxMotifWidth;

// One position → 4 base weights
typedef Vector#(AlphabetSize, FixedPoint_8_8) PWMColumn;

// Full PWM
typedef Vector#(MaxMotifWidth, PWMColumn) PWM;


// Pipeline stage tags

typedef enum {
	Stage_Idle,
	Stage_Loading,
	Stage_KmerCounting,
	Stage_Enrichment,
	Stage_PWMBuild,
	Stage_PWMScore,
	Stage_Masking,
	Stage_Done
} PipelineStage deriving (Bits, Eq, FShow);


// Utility functions

// 2-bit base to index (0..3)
function UInt#(2) baseToIndex(DNABase b);
	return unpack(b);
endfunction

// Pack k bases into KmerBits (LSB-first)
function KmerBits packKmer(Vector#(MaxK, DNABase) bases, UInt#(5) k);
	KmerBits result = 0;
	for (Integer i = 0; i < valueOf(MaxK); i = i + 1) begin
		if (fromInteger(i) < k)
			result = result | (zeroExtend(bases[i]) << (2 * fromInteger(i)));
	end
	return result;
endfunction

// Q8.8 multiply
function FixedPoint_8_8 fxMul_8_8(FixedPoint_8_8 a, FixedPoint_8_8 b);
	Int#(32) prod = signExtend(a) * signExtend(b);
	return truncate(prod >> 8);
endfunction

// int -> Q8.8
function FixedPoint_8_8 intToFx_8_8(Int#(8) v);
	return signExtend(v) << 8;
endfunction

endpackage
