# yos

A 64-bit hobby operating system written in **Zig**, booted by **Limine**, using
**uACPI**, and implementing the **Linux x86_64 syscall ABI** — unmodified static
Linux binaries (including GNU bash) run on it.

```
[yos] starting init: /bin/bash
root@yos:~# echo hello from bash $BASH_VERSION, 6*7=$((6*7))
hello from bash 5.2.37(1)-release, 6*7=42
root@yos:~# uname -a; ls /bin | head -3; cat /etc/motd | wc -l
yos yos 0.1.0 #1 yos hobby kernel (zig) x86_64
bash
cat
free
6
root@yos:~# sleep 30
^C
root@yos:~# sleep 0.2 & wait; echo bg-done
[1] 36
[1]+  Done                    sleep 0.2
bg-done
```

## Features
- Limine boot (BIOS + UEFI ISO), serial console
- GDT/TSS/IDT, exceptions, LAPIC + IOAPIC, LAPIC timer (100 Hz)
- **Buddy** physical allocator, **slab** kernel heap (also a `std.mem.Allocator`)
- 4-level paging, per-process address spaces, demand-zero paging, fork copy
- **uACPI**: tables, MADT, full AML namespace init, SCI, S5 poweroff / reboot
- Preemptive **round-robin** scheduler, kernel + user threads, FPU state
- `syscall` entry, ~120 Linux syscalls: files, dirs, pipes, fork/execve/wait4,
  signals (handlers, sigreturn, SA_RESTART), mmap/brk, poll/select, termios tty,
  process groups / job control, clocks, `#!` scripts
- ramfs populated from a USTAR initrd; /dev/{console,tty,null,zero,urandom}
- Userland: static GNU bash 5.2 (musl, built with `zig cc`) + small Zig tools
  (`ls cat head wc mkdir rm uname sleep free poweroff ktest`)

See [PLAN.md](PLAN.md) for the design and milestones (`m0`..`m7` git tags).

## Requirements
- Zig 0.16.0, make, xorriso, gcc (Limine host tool + bash build helpers), curl
- qemu-system-x86_64

## Build & run
```sh
./scripts/fetch-deps.sh   # Limine binaries -> deps/limine
./scripts/build-bash.sh   # static bash -> prebuilt/bin/bash (optional, ~5 min)
make run                  # build ISO and boot in QEMU (serial on stdio)
make test                 # automated boot + scripted bash session
```
Without `prebuilt/bin/bash`, init falls back to `/bin/ktest` (the kernel self-test suite).

## Layout
```
kernel/src/main.zig        boot sequence
kernel/src/arch/           cpu helpers, GDT/TSS, IDT, entry.S (ISRs, syscall, context switch)
kernel/src/mm/             pmm.zig (buddy), vmm.zig (paging), heap.zig (slab)
kernel/src/acpi.zig        uACPI kernel API + MADT
kernel/src/dev/            apic.zig, tty.zig
kernel/src/sched.zig       round-robin scheduler (SMP), wait queues
kernel/src/smp.zig         AP bring-up (Limine MP), percpu.zig per-CPU data, sync.zig BKL
kernel/src/proc.zig        processes, VMAs, exec, exit
kernel/src/syscall.zig     Linux syscall table
kernel/src/vfs.zig         ramfs, files, pipes, devices
kernel/src/signal.zig      signal delivery
userland/                  Zig userland programs
third_party/uacpi/         vendored uACPI (MIT)
```

## Next steps
SMP, copy-on-write fork, block devices + ext2, framebuffer console + PS/2 keyboard, /proc, networking.
