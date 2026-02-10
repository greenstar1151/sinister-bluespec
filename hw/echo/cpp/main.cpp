/*
 * Echo Test — Host-side PCIe Communication Test
 *
 * Tests:
 *   1. Write a value to FPGA, read it back (echo)
 *   2. Check hardware counter increments on each read
 *   3. Verify unknown-offset returns magic number (0xDEADBEEF)
 *
 * Usage:
 *   make bsim   (build for bluesim)
 *   make        (build for real PCIe)
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>

#include "bdbmpcie.h"


int main(int argc, char** argv)
{
	BdbmPcie* pcie = BdbmPcie::getInstance();

	// Check magic word — confirms PCIe link is up
	unsigned int d = pcie->readWord(0);
	printf("[Echo Test] Magic: 0x%x\n", d);
	fflush(stdout);

	//-------------------------------------------------------------------
	// Test 1: Echo — write a value, read it back
	//-------------------------------------------------------------------
	uint32_t testValues[] = { 0x12345678, 0xCAFEBABE, 0x00000000, 0xFFFFFFFF, 0xA5A5A5A5 };
	int numTests = sizeof(testValues) / sizeof(testValues[0]);
	int passed = 0;

	printf("\n--- Echo Test ---\n");
	for (int i = 0; i < numTests; i++) {
		// Write to offset 0
		pcie->userWriteWord(0, testValues[i]);
		usleep(1000);  // small delay for HW to process

		// Read back from offset 0
		uint32_t readback = pcie->userReadWord(0);

		if (readback == testValues[i]) {
			printf("  [PASS] echo 0x%08X -> 0x%08X\n", testValues[i], readback);
			passed++;
		} else {
			printf("  [FAIL] echo 0x%08X -> 0x%08X (mismatch)\n", testValues[i], readback);
		}
	}
	printf("Echo: %d/%d passed\n", passed, numTests);

	//-------------------------------------------------------------------
	// Test 2: Status register — should be 1 after we wrote data
	//-------------------------------------------------------------------
	printf("\n--- Status Register ---\n");
	uint32_t status = pcie->userReadWord(4);  // offset 1 (addr = 4)
	printf("  echoValid = %u (expected: 1)\n", status);

	//-------------------------------------------------------------------
	// Test 3: Hardware counter — should increment on each read
	//-------------------------------------------------------------------
	printf("\n--- HW Counter ---\n");
	uint32_t c0 = pcie->userReadWord(8);  // offset 2 (addr = 8)
	uint32_t c1 = pcie->userReadWord(8);
	uint32_t c2 = pcie->userReadWord(8);
	printf("  counter reads: %u, %u, %u\n", c0, c1, c2);
	if (c1 == c0 + 1 && c2 == c1 + 1) {
		printf("  [PASS] counter increments correctly\n");
	} else {
		printf("  [FAIL] counter did not increment as expected\n");
	}

	//-------------------------------------------------------------------
	// Test 4: Unknown offset — should return 0xDEADBEEF
	//-------------------------------------------------------------------
	printf("\n--- Unknown Offset ---\n");
	uint32_t magic = pcie->userReadWord(12);  // offset 3 (addr = 12)
	printf("  offset 3 = 0x%08X (expected: 0xDEADBEEF)\n", magic);
	if (magic == 0xDEADBEEF) {
		printf("  [PASS]\n");
	} else {
		printf("  [FAIL]\n");
	}

	printf("\n[Echo Test] Done.\n");

	return 0;
}
