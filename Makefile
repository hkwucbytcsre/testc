ifneq ($(KERNELRELEASE),)
obj-m := scx_leak_hotfix.o
else

# Path to a kernel tree already taken through `modules_prepare` with the
# target .config and Module.symvers in place. See tools/extract_target.sh.
KDIR ?= /root/android_kernel_oneplus_mt6989
ARCH ?= arm64
LLVM ?= 1

# LOCALVERSION must be empty on the command line: scripts/setlocalversion
# otherwise appends a git suffix and the resulting vermagic will not match
# the target kernel.
KBUILD_ARGS := -C "$(KDIR)" M="$(CURDIR)" ARCH="$(ARCH)" LLVM="$(LLVM)" LOCALVERSION=

TARGET_RELEASE := 6.1.115-android14-oki-xiaoxiaow
TARGET_VERMAGIC := $(TARGET_RELEASE) SMP preempt mod_unload modversions aarch64

.PHONY: all clean test verify check-layout extract preflight stress stats

all:
	$(MAKE) $(KBUILD_ARGS) modules

clean:
	$(MAKE) $(KBUILD_ARGS) clean

# Static checks only; safe to run anywhere.
test:
	sh tests/source_contract.sh

# Validate the built artifact against the target ABI before loading it.
verify: scx_leak_hotfix.ko
	python3 tools/verify_ko.py scx_leak_hotfix.ko ci/Module.symvers "$(TARGET_VERMAGIC)"

# Independently confirm struct layouts match the target kernel's BTF. This is
# the check that catches a wrong sizeof(struct module), which loads fine and
# then panics the device.
check-layout:
	sh tools/check_struct_layout.sh "$(KDIR)" module
	sh tools/check_struct_layout.sh "$(KDIR)" sched_ext_entity

# Recover target.config and Module.symvers from a kernel image.
extract:
	sh tools/extract_target.sh "$(KDIR)" vmlinux ci

# On-device helpers.
preflight:
	sh scripts/preflight.sh

stress:
	sh scripts/stress_test.sh

stats:
	sh scripts/collect_stats.sh

endif
