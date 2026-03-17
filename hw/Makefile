# ============================================================
# Top-level dispatcher — delegates to per-kernel Makefiles
# ============================================================
# Usage:
#   make PROJECT=echo          (default: build echo kernel)
#   make PROJECT=motif xclbin  (build motif xclbin only)
#   make PROJECT=motif package (full build + package)
#   make clean-all             (clean all projects)
# ============================================================

PROJECT ?= echo
KERNEL_DIR := ./$(PROJECT)_kernel

# Forward all targets to the kernel's own Makefile
%:
	$(MAKE) -C $(KERNEL_DIR) $@

all:
	$(MAKE) -C $(KERNEL_DIR) all

clean:
	$(MAKE) -C $(KERNEL_DIR) clean

clean-all:
	@for d in *_kernel; do \
		echo "=== Cleaning $$d ==="; \
		$(MAKE) -C $$d clean; \
	done

distclean-all:
	@for d in *_kernel; do \
		echo "=== Distcleaning $$d ==="; \
		$(MAKE) -C $$d distclean; \
	done
	rm -rf build

.PHONY: all clean clean-all distclean-all