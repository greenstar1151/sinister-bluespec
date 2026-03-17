#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <xrt/experimental/xrt_ip.h>
#include <xrt/xrt_bo.h>
#include <xrt/xrt_device.h>

// ============================================================
// Register map (matches s_axi_control_markov_hbm.v)
// ============================================================
namespace reg {
constexpr uint32_t COMMAND      = 0x000;
constexpr uint32_t STATUS       = 0x004;
constexpr uint32_t TOTAL_BASES  = 0x008;
constexpr uint32_t MAGIC        = 0x00C;
constexpr uint32_t CYCLE_LO     = 0x010;
constexpr uint32_t CYCLE_HI     = 0x014;
constexpr uint32_t DNA_PTR_LO   = 0x018;
constexpr uint32_t DNA_PTR_HI   = 0x01C;
constexpr uint32_t NUM_ENTRIES  = 0x020;
constexpr uint32_t BASE_PROB    = 0x100; // +0,4,8,C for A,C,G,T
constexpr uint32_t TRANS_PROB   = 0x200; // +index*4, index=ctx*4+base

constexpr uint32_t CMD_RESET = 0x01;
constexpr uint32_t CMD_START = 0x02;

constexpr uint32_t ST_IDLE        = 0;
constexpr uint32_t ST_READING     = 1;
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
	default: return -1;
	}
}

static const char* BASE_CHARS = "ACGT";

static double q16_16_to_double(uint32_t val) {
	return static_cast<double>(val) / 65536.0;
}

// ============================================================
// Pack DNA sequences into HBM buffer
// Each byte: bits[1:0]=base, bit[2]=valid, bit[3]=seq_last
// ============================================================
static size_t pack_sequences(const std::vector<std::string>& sequences, uint8_t* buf) {
	size_t offset = 0;
	for (size_t s = 0; s < sequences.size(); s++) {
		const std::string& seq = sequences[s];
		for (size_t i = 0; i < seq.size(); i++) {
			int b = encode_base(seq[i]);
			uint8_t byte = 0;
			if (b >= 0) {
				byte = (b & 0x3) | (1 << 2); // base + valid=1
			}
			if (i == seq.size() - 1)
				byte |= (1 << 3); // seq_last=1
			buf[offset++] = byte;
		}
	}
	return offset;
}

// ============================================================
// Software golden model for comparison
// ============================================================
struct MarkovGolden {
	double base_counts[4];
	double trans_counts[64][4];

	void reset() {
		for (int i = 0; i < 4; i++) base_counts[i] = 1.0;
		for (int c = 0; c < 64; c++)
			for (int b = 0; b < 4; b++)
				trans_counts[c][b] = 1.0;
	}

	void train(const std::vector<std::string>& sequences) {
		reset();
		for (const auto& seq : sequences) {
			int pos = 0;
			int ctx_b[3] = {-1, -1, -1};
			for (char ch : seq) {
				int b = encode_base(ch);
				if (b < 0) {
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
// Wait for kernel completion
// ============================================================
static bool wait_for_done(xrt::ip& ip, int max_iters = 1000000) {
	for (int i = 0; i < max_iters; i++) {
		uint32_t st = ip.read_register(reg::STATUS);
		if (st == reg::ST_DONE) return true;
	}
	std::fprintf(stderr, "ERROR: Timed out waiting for completion\n");
	return false;
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

	std::printf("[Markov HBM Trainer] xclbin: %s\n", xclbin_path.c_str());

	xrt::device device{0};
	auto uuid = device.load_xclbin(xclbin_path);
	auto ip = xrt::ip(device, uuid, "kernel:{kernel_1}");

	// --- Check magic ---
	uint32_t magic = ip.read_register(reg::MAGIC);
	std::printf("Magic: 0x%08X (expected 0x4D480003)\n", magic);
	if (magic != 0x4D480003u) {
		std::fprintf(stderr, "FAIL: Wrong magic\n");
		return EXIT_FAILURE;
	}

	// --- Reset ---
	ip.write_register(reg::COMMAND, reg::CMD_RESET);
	uint32_t status = ip.read_register(reg::STATUS);
	std::printf("After reset: status=%u (expect 0=idle)\n", status);

	auto read_cycles = [&]() -> uint64_t {
		uint32_t lo = ip.read_register(reg::CYCLE_LO);
		uint32_t hi = ip.read_register(reg::CYCLE_HI);
		return (static_cast<uint64_t>(hi) << 32) | lo;
	};

	// ============================================================
	// Test 1: Uniform ACGT repeats via HBM
	// ============================================================
	std::printf("\n=== Test 1: Uniform ACGT repeats (HBM DMA) ===\n");

	ip.write_register(reg::COMMAND, reg::CMD_RESET);

	std::vector<std::string> test_seqs;
	for (int i = 0; i < 100; i++) {
		std::string seq;
		for (int j = 0; j < 100; j++)
			seq += BASE_CHARS[j % 4];
		test_seqs.push_back(seq);
	}

	// Calculate total entries
	size_t total_entries = 0;
	for (const auto& s : test_seqs) total_entries += s.size();

	// Allocate HBM buffer (round up to 4K page)
	size_t buf_size = ((total_entries + 4095) / 4096) * 4096;
	// HBM[0] = memory group 0
	auto bo = xrt::bo(device, buf_size, xrt::bo::flags::normal, 0);
	auto bo_map = bo.map<uint8_t*>();
	std::memset(bo_map, 0, buf_size);

	// Pack sequences into buffer
	size_t packed = pack_sequences(test_seqs, bo_map);
	std::printf("Packed %zu entries into HBM buffer (%zu bytes allocated)\n", packed, buf_size);

	// DMA to device
	bo.sync(XCL_BO_SYNC_BO_TO_DEVICE);

	// Get HBM address
	uint64_t dna_addr = bo.address();
	std::printf("HBM buffer address: 0x%016lX\n", dna_addr);

	// Program registers
	ip.write_register(reg::DNA_PTR_LO, static_cast<uint32_t>(dna_addr & 0xFFFFFFFF));
	ip.write_register(reg::DNA_PTR_HI, static_cast<uint32_t>(dna_addr >> 32));
	ip.write_register(reg::NUM_ENTRIES, static_cast<uint32_t>(packed));

	// Start!
	uint64_t cyc_before = read_cycles();
	ip.write_register(reg::COMMAND, reg::CMD_START);

	if (!wait_for_done(ip)) return EXIT_FAILURE;
	uint64_t cyc_after = read_cycles();

	status = ip.read_register(reg::STATUS);
	uint32_t total = ip.read_register(reg::TOTAL_BASES);
	uint64_t total_cycles = cyc_after - cyc_before;

	std::printf("After completion: status=%u, total_bases=%u\n", status, total);
	std::printf("\nPerformance (FPGA @ 256MHz):\n");
	std::printf("  Total:  %lu cycles (%.3f ms)\n", total_cycles, total_cycles / 256000.0);
	std::printf("  Per base: %.1f cycles\n", static_cast<double>(total_cycles) / packed);

	// --- Compare with golden model ---
	MarkovGolden golden;
	golden.train(test_seqs);

	std::printf("\nBase probabilities (Q16.16 -> double):\n");
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
	// Test 2: A-biased sequences
	// ============================================================
	std::printf("\n=== Test 2: A-biased sequences (HBM DMA) ===\n");

	ip.write_register(reg::COMMAND, reg::CMD_RESET);

	std::vector<std::string> biased_seqs;
	for (int i = 0; i < 50; i++) {
		std::string seq;
		for (int j = 0; j < 200; j++) {
			if (j % 10 < 7) seq += 'A';
			else if (j % 10 == 7) seq += 'C';
			else if (j % 10 == 8) seq += 'G';
			else seq += 'T';
		}
		biased_seqs.push_back(seq);
	}

	size_t biased_entries = 0;
	for (const auto& s : biased_seqs) biased_entries += s.size();

	size_t biased_buf_size = ((biased_entries + 4095) / 4096) * 4096;
	auto bo2 = xrt::bo(device, biased_buf_size, xrt::bo::flags::normal, 0);
	auto bo2_map = bo2.map<uint8_t*>();
	std::memset(bo2_map, 0, biased_buf_size);
	size_t biased_packed = pack_sequences(biased_seqs, bo2_map);
	bo2.sync(XCL_BO_SYNC_BO_TO_DEVICE);

	uint64_t dna_addr2 = bo2.address();
	ip.write_register(reg::DNA_PTR_LO, static_cast<uint32_t>(dna_addr2 & 0xFFFFFFFF));
	ip.write_register(reg::DNA_PTR_HI, static_cast<uint32_t>(dna_addr2 >> 32));
	ip.write_register(reg::NUM_ENTRIES, static_cast<uint32_t>(biased_packed));

	ip.write_register(reg::COMMAND, reg::CMD_START);
	if (!wait_for_done(ip)) return EXIT_FAILURE;

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

	bool overall = (base_pass == 4) && (full_pass >= 250);
	std::printf("Overall: %s\n", overall ? "PASS" : "FAIL");

	return overall ? EXIT_SUCCESS : EXIT_FAILURE;
}
