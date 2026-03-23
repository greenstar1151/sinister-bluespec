#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <experimental/xrt_ip.h>
#include <xrt/xrt_device.h>

// ============================================================
// Register map (matches s_axi_control_markov.v)
// ============================================================
namespace reg {
constexpr uint32_t DNA_DATA     = 0x000;
constexpr uint32_t COMMAND      = 0x004;
constexpr uint32_t STATUS       = 0x008;
constexpr uint32_t TOTAL_BASES  = 0x00C;
constexpr uint32_t MAGIC        = 0x010;
constexpr uint32_t CYCLE_LO     = 0x014;
constexpr uint32_t CYCLE_HI     = 0x018;
constexpr uint32_t BASE_PROB    = 0x100; // +0,4,8,C for A,C,G,T
constexpr uint32_t TRANS_PROB   = 0x200; // +index*4, index=ctx*4+base

constexpr uint32_t CMD_RESET     = 0x01;
constexpr uint32_t CMD_NORMALIZE = 0x02;

constexpr uint32_t ST_IDLE        = 0;
constexpr uint32_t ST_TRAINING    = 1;
constexpr uint32_t ST_NORMALIZING = 2;
constexpr uint32_t ST_DONE        = 3;
}  // namespace reg

// DNA encoding: A=0, C=1, G=2, T=3
static int encode_base(char c) {
	switch (c) {
	case 'A': case 'a': return 0;
	case 'C': case 'c': return 1;
	case 'G': case 'g': return 2;
	case 'T': case 't': return 3;
	default: return -1; // N or invalid
	}
}

static const char* BASE_CHARS = "ACGT";

static double q16_16_to_double(uint32_t val) {
	return static_cast<double>(val) / 65536.0;
}

// ============================================================
// Software golden model for comparison
// ============================================================
struct MarkovGolden {
	double base_counts[4];
	double trans_counts[64][4];

	void reset() {
		for (int i = 0; i < 4; i++) base_counts[i] = 1.0; // pseudocount
		for (int c = 0; c < 64; c++)
			for (int b = 0; b < 4; b++)
				trans_counts[c][b] = 1.0; // pseudocount
	}

	void train(const std::vector<std::string>& sequences) {
		reset();
		for (const auto& seq : sequences) {
			int pos = 0;
			int ctx_b[3] = {-1, -1, -1};
			for (char ch : seq) {
				int b = encode_base(ch);
				if (b < 0) {
					// Invalid — reset context
					ctx_b[0] = ctx_b[1] = ctx_b[2] = -1;
					pos = 0;
					continue;
				}
				base_counts[b] += 1.0;
				if (pos >= 3 && ctx_b[0] >= 0 && ctx_b[1] >= 0 && ctx_b[2] >= 0) {
					int ctx = (ctx_b[0] * 4 + ctx_b[1]) * 4 + ctx_b[2];
					trans_counts[ctx][b] += 1.0;
				}
				ctx_b[0] = ctx_b[1];
				ctx_b[1] = ctx_b[2];
				ctx_b[2] = b;
				pos++;
			}
		}
	}

	double base_prob(int b) const {
		double total = base_counts[0] + base_counts[1] + base_counts[2] + base_counts[3];
		return base_counts[b] / total;
	}

	double trans_prob(int ctx, int b) const {
		double total = trans_counts[ctx][0] + trans_counts[ctx][1] +
		               trans_counts[ctx][2] + trans_counts[ctx][3];
		return trans_counts[ctx][b] / total;
	}
};

// ============================================================
// Send sequences to FPGA
// ============================================================
static void send_sequences(xrt::ip& ip, const std::vector<std::string>& sequences) {
	for (size_t s = 0; s < sequences.size(); s++) {
		const std::string& seq = sequences[s];
		for (size_t i = 0; i < seq.size(); i++) {
			int b = encode_base(seq[i]);
			uint32_t data = 0;
			if (b >= 0) {
				data = (b & 0x3) | (1 << 2); // base + valid=1
			} else {
				data = 0; // valid=0
			}
			// Mark last base in sequence
			if (i == seq.size() - 1)
				data |= (1 << 3); // seq_last=1
			ip.write_register(reg::DNA_DATA, data);
		}
	}
}

static void wait_for_done(xrt::ip& ip) {
	for (int i = 0; i < 100000; i++) {
		uint32_t st = ip.read_register(reg::STATUS);
		if (st == reg::ST_DONE) return;
		// Small busy-wait (FPGA normalizer takes ~2K cycles ≈ 8µs at 250MHz)
	}
	std::fprintf(stderr, "ERROR: Timed out waiting for normalization to complete\n");
}

// ============================================================
// Main
// ============================================================
int main(int argc, char** argv)
{
	if (argc < 2) {
		std::fprintf(stderr, "Usage: %s <path-to-kernel.xclbin>\n", argv[0]);
		return EXIT_FAILURE;
	}
	const std::string xclbin_path = argv[1];

	std::printf("[Motif Markov Trainer] xclbin: %s\n", xclbin_path.c_str());

	xrt::device device{0};
	auto uuid = device.load_xclbin(xclbin_path);
	auto ip = xrt::ip(device, uuid, "kernel:{kernel_1}");

	// --- Check magic ---
	uint32_t magic = ip.read_register(reg::MAGIC);
	std::printf("Magic: 0x%08X (expected 0x4D4B0003)\n", magic);
	if (magic != 0x4D4B0003u) {
		std::fprintf(stderr, "FAIL: Wrong magic — wrong kernel loaded?\n");
		return EXIT_FAILURE;
	}

	// --- Reset ---
	ip.write_register(reg::COMMAND, reg::CMD_RESET);

	uint32_t status = ip.read_register(reg::STATUS);
	std::printf("After reset: status=%u (expect 0=idle)\n", status);

	// Helper to read 64-bit cycle counter
	auto read_cycles = [&]() -> uint64_t {
		uint32_t lo = ip.read_register(reg::CYCLE_LO);
		uint32_t hi = ip.read_register(reg::CYCLE_HI);
		return (static_cast<uint64_t>(hi) << 32) | lo;
	};

	// ============================================================
	// Test 1: Simple uniform sequence — "ACGTACGTACGT..."
	// ============================================================
	std::printf("\n=== Test 1: Uniform ACGT repeats ===\n");

	ip.write_register(reg::COMMAND, reg::CMD_RESET);

	std::vector<std::string> test_seqs;
	for (int i = 0; i < 100; i++) {
		std::string seq;
		for (int j = 0; j < 100; j++)
			seq += BASE_CHARS[j % 4]; // ACGTACGTACGT...
		test_seqs.push_back(seq);
	}

	// Send to FPGA
	uint64_t cyc_before_train = read_cycles();
	send_sequences(ip, test_seqs);
	uint64_t cyc_after_train = read_cycles();

	// Check training status
	status = ip.read_register(reg::STATUS);
	uint32_t total = ip.read_register(reg::TOTAL_BASES);
	std::printf("After sending: status=%u, total_bases=%u (expect %zu)\n",
	            status, total, test_seqs.size() * test_seqs[0].size());

	// Trigger normalization
	uint64_t cyc_before_norm = read_cycles();
	ip.write_register(reg::COMMAND, reg::CMD_NORMALIZE);
	wait_for_done(ip);
	uint64_t cyc_after_norm = read_cycles();

	status = ip.read_register(reg::STATUS);
	std::printf("After normalize: status=%u (expect 3=done)\n", status);

	// --- Cycle counter report ---
	uint64_t train_cycles = cyc_after_train - cyc_before_train;
	uint64_t norm_cycles  = cyc_after_norm - cyc_before_norm;
	std::printf("\nCycle counts (FPGA @ 256MHz):\n");
	std::printf("  Training:      %lu cycles (%.3f ms)\n", train_cycles, train_cycles / 256000.0);
	std::printf("  Normalization: %lu cycles (%.3f ms)\n", norm_cycles, norm_cycles / 256000.0);
	std::printf("  Total:         %lu cycles (%.3f ms)\n", train_cycles + norm_cycles, (train_cycles + norm_cycles) / 256000.0);

	// --- Read base probabilities ---
	std::printf("\nBase probabilities (Q16.16 -> double):\n");
	MarkovGolden golden;
	golden.train(test_seqs);

	int base_pass = 0;
	for (int b = 0; b < 4; b++) {
		uint32_t raw = ip.read_register(reg::BASE_PROB + b * 4);
		double hw_val = q16_16_to_double(raw);
		double sw_val = golden.base_prob(b);
		double err = std::fabs(hw_val - sw_val);
		bool ok = err < 0.001;
		std::printf("  P(%c): HW=%.6f  SW=%.6f  err=%.6f  %s\n",
		            BASE_CHARS[b], hw_val, sw_val, err, ok ? "PASS" : "FAIL");
		if (ok) base_pass++;
	}

	// --- Read transition probabilities (spot check) ---
	std::printf("\nTransition probabilities (spot check, first 8 contexts):\n");
	int trans_pass = 0;
	int trans_total = 0;
	for (int ctx = 0; ctx < 8; ctx++) {
		for (int b = 0; b < 4; b++) {
			uint32_t idx = ctx * 4 + b;
			uint32_t raw = ip.read_register(reg::TRANS_PROB + idx * 4);
			double hw_val = q16_16_to_double(raw);
			double sw_val = golden.trans_prob(ctx, b);
			double err = std::fabs(hw_val - sw_val);
			bool ok = err < 0.002;
			trans_total++;
			if (ok) trans_pass++;
			if (ctx < 4) { // Print first 4 contexts fully
				char c0 = BASE_CHARS[(ctx >> 4) & 3];
				char c1 = BASE_CHARS[(ctx >> 2) & 3];
				char c2 = BASE_CHARS[ctx & 3];
				std::printf("  P(%c|%c%c%c): HW=%.6f  SW=%.6f  err=%.6f  %s\n",
				            BASE_CHARS[b], c0, c1, c2, hw_val, sw_val, err,
				            ok ? "PASS" : "FAIL");
			}
		}
	}
	std::printf("Transition spot check: %d/%d passed\n", trans_pass, trans_total);

	// --- Full scan of all 256 transition probs ---
	std::printf("\nFull transition probability check (all 256 entries):\n");
	int full_pass = 0;
	double max_err = 0;
	for (int ctx = 0; ctx < 64; ctx++) {
		for (int b = 0; b < 4; b++) {
			uint32_t idx = ctx * 4 + b;
			uint32_t raw = ip.read_register(reg::TRANS_PROB + idx * 4);
			double hw_val = q16_16_to_double(raw);
			double sw_val = golden.trans_prob(ctx, b);
			double err = std::fabs(hw_val - sw_val);
			if (err > max_err) max_err = err;
			if (err < 0.002) full_pass++;
		}
	}
	std::printf("  %d/256 passed (max error = %.6f)\n", full_pass, max_err);

	// ============================================================
	// Test 2: Biased sequence — mostly A's
	// ============================================================
	std::printf("\n=== Test 2: A-biased sequences ===\n");

	ip.write_register(reg::COMMAND, reg::CMD_RESET);

	std::vector<std::string> biased_seqs;
	for (int i = 0; i < 50; i++) {
		std::string seq;
		for (int j = 0; j < 200; j++) {
			// 70% A, 10% each C/G/T
			if (j % 10 < 7) seq += 'A';
			else if (j % 10 == 7) seq += 'C';
			else if (j % 10 == 8) seq += 'G';
			else seq += 'T';
		}
		biased_seqs.push_back(seq);
	}

	send_sequences(ip, biased_seqs);
	ip.write_register(reg::COMMAND, reg::CMD_NORMALIZE);
	wait_for_done(ip);

	MarkovGolden golden2;
	golden2.train(biased_seqs);

	std::printf("Base probabilities (biased):\n");
	for (int b = 0; b < 4; b++) {
		uint32_t raw = ip.read_register(reg::BASE_PROB + b * 4);
		double hw_val = q16_16_to_double(raw);
		double sw_val = golden2.base_prob(b);
		double err = std::fabs(hw_val - sw_val);
		std::printf("  P(%c): HW=%.6f  SW=%.6f  err=%.6f  %s\n",
		            BASE_CHARS[b], hw_val, sw_val, err, err < 0.001 ? "PASS" : "FAIL");
	}
	// P(A) should be ~0.70
	{
		uint32_t raw = ip.read_register(reg::BASE_PROB + 0);
		double hw_pa = q16_16_to_double(raw);
		std::printf("  P(A) = %.4f — expected ~0.70: %s\n", hw_pa,
		            (hw_pa > 0.65 && hw_pa < 0.75) ? "PASS" : "FAIL");
	}

	// ============================================================
	// Summary
	// ============================================================
	std::printf("\n=== Summary ===\n");
	std::printf("Base probs (test 1):   %d/4 passed\n", base_pass);
	std::printf("Trans probs (test 1):  %d/256 passed (max err=%.6f)\n", full_pass, max_err);

	bool overall = (base_pass == 4) && (full_pass >= 250); // allow a few rounding differences
	std::printf("Overall: %s\n", overall ? "PASS" : "FAIL");

	return overall ? EXIT_SUCCESS : EXIT_FAILURE;
}
