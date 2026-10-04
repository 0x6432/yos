ZIG    ?= zig
QEMU   ?= qemu-system-x86_64
OPT    ?= ReleaseSafe
LIMINE := deps/limine
ISO    := build/yos.iso
SMP    ?= 4
QEMUFLAGS ?= -M q35 -m 512M -smp $(SMP) -cdrom $(ISO) -serial stdio -display none -no-reboot -no-shutdown

.PHONY: all kernel initrd iso run test clean deps

all: iso

deps:
	./scripts/fetch-deps.sh

kernel:
	$(ZIG) build -Doptimize=$(OPT)

initrd:
	./scripts/mkinitrd.sh

iso: kernel initrd
	@test -d $(LIMINE) || ./scripts/fetch-deps.sh
	rm -rf build/iso_root
	mkdir -p build/iso_root/boot/limine build/iso_root/EFI/BOOT
	cp zig-out/bin/kernel build/iso_root/boot/kernel
	cp build/initrd.tar build/iso_root/boot/initrd.tar
	cp limine.conf build/iso_root/boot/limine/
	cp $(LIMINE)/limine-bios.sys $(LIMINE)/limine-bios-cd.bin $(LIMINE)/limine-uefi-cd.bin build/iso_root/boot/limine/
	cp $(LIMINE)/BOOTX64.EFI build/iso_root/EFI/BOOT/
	xorriso -as mkisofs -R -r -J -b boot/limine/limine-bios-cd.bin \
		-no-emul-boot -boot-load-size 4 -boot-info-table -hfsplus \
		-apm-block-size 2048 --efi-boot boot/limine/limine-uefi-cd.bin \
		-efi-boot-part --efi-boot-image --protective-msdos-label \
		build/iso_root -o $(ISO) 2>/dev/null
	$(LIMINE)/limine bios-install $(ISO) 2>/dev/null

run: iso
	$(QEMU) $(QEMUFLAGS)

test: iso
	python3 scripts/test.py

clean:
	rm -rf build zig-out .zig-cache
