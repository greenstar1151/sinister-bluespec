#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include <experimental/xrt_ip.h>
#include <xrt/xrt_device.h>

namespace {

constexpr unsigned int kDeviceIndex = 0;
constexpr uint32_t kEchoInOffset = 0x00;
constexpr uint32_t kEchoOutOffset = 0x04;
constexpr uint32_t kCounterOffset = 0x08;
constexpr uint32_t kMagicOffset = 0x0c;
constexpr uint32_t kStatusOffset = 0x10;

}  // namespace

int main(int argc, char** argv)
{
	if (argc < 2) {
		std::fprintf(stderr, "Usage: %s <path-to-kernel.xclbin>\n", argv[0]);
		return EXIT_FAILURE;
	}
	const std::string xclbin_path = argv[1];

	xrt::device device{kDeviceIndex};
	auto uuid = device.load_xclbin(xclbin_path);
	auto ip = xrt::ip(device, uuid, "kernel:{kernel_1}");

	const std::vector<uint32_t> test_values = {
		0x12345678u,
		0xCAFEBABEu,
		0x00000000u,
		0xFFFFFFFFu,
		0xA5A5A5A5u,
	};

	std::printf("[U50 Echo] xclbin: %s\n", xclbin_path.c_str());

	int passed = 0;
	for (uint32_t value : test_values) {
		ip.write_register(kEchoInOffset, value);
		uint32_t echo = ip.read_register(kEchoOutOffset);
		if (echo == value) {
			std::printf("  [PASS] echo 0x%08X -> 0x%08X\n", value, echo);
			passed++;
		} else {
			std::printf("  [FAIL] echo 0x%08X -> 0x%08X\n", value, echo);
		}
	}

	uint32_t status = ip.read_register(kStatusOffset);
	uint32_t counter0 = ip.read_register(kCounterOffset);
	uint32_t counter1 = ip.read_register(kCounterOffset);
	uint32_t counter2 = ip.read_register(kCounterOffset);
	uint32_t magic = ip.read_register(kMagicOffset);

	std::printf("Echo: %d/%zu passed\n", passed, test_values.size());
	std::printf("status = %u\n", status);
	std::printf("counter reads: %u, %u, %u\n", counter0, counter1, counter2);
	std::printf("magic = 0x%08X\n", magic);

	if (magic != 0xDEADBEEFu) {
		std::fprintf(stderr, "Unexpected magic value\n");
		return EXIT_FAILURE;
	}

	return passed == static_cast<int>(test_values.size()) ? EXIT_SUCCESS : EXIT_FAILURE;
}