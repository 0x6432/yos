# yos — plan

A 64-bit hobby OS written in Zig. Boots with **Limine**, uses **uACPI** for ACPI,
speaks the **Linux x86_64 syscall ABI** so unmodified static Linux binaries run.
North-star goal: boot to an interactive **GNU bash** prompt.

## Design decisions

| Area | Choice |
| --- | --- |
| Arch | x86_64 only, single CPU for now (SMP later) |
| Boot | Limine protocol (base revision 3), BIOS + UEFI ISO |
| Console | COM1 serial (16550), IRQ-driven input |
| Physical memory | Buddy allocator (orders 0..10, 4 KiB..4 MiB), per-page `struct Page` array |
| Kernel heap | Slab allocator (16..2048 B size classes, 1 page slabs); large allocs go straight to buddy; exposed as `std.mem.Allocator` |
| Virtual memory | 4-level paging, kernel half shared by all address spaces, per-process VMAs, demand-zero pages, copy-on-write fork |
| ACPI | uACPI (full mode): MADT for LAPIC/IOAPIC, HPET/PM timer via namespace, S5 poweroff |
| Interrupts | IDT + LAPIC + IOAPIC, LAPIC timer @ 100 Hz |
| Scheduler | Preemptive round robin, kernel threads + user threads, FPU state saved with fxsave |
| Syscalls | `syscall` instruction, Linux numbers & struct layouts, return through `iretq` |
| Userspace | static ELF loader (ET_EXEC / static-PIE), SysV auxv stack |
| Files | VFS over a ramfs populated from a USTAR initrd (Limine module), devfs nodes, pipes, tty with termios |

## Milestones

Each milestone is a git tag `mN` pushed to GitHub plus a tarball backup in `backups/`.

- **M0 – skeleton**: zig build, linker script, Limine ISO, serial logging, panic handler, `make run`/`make test`.
- **M1 – CPU + PMM**: GDT/TSS, IDT + exception handlers, buddy physical allocator.
- **M2 – VMM + heap**: page-table management, MMIO mapping, slab kernel heap.
- **M3 – ACPI + interrupts**: uACPI integration, MADT parsing, LAPIC/IOAPIC, timer.
- **M4 – scheduler**: kernel threads, context switch, round-robin preemption, sleep/wait queues.
- **M5 – userspace**: syscall entry, ELF loader, first Linux static binary (`write`/`exit`).
- **M6 – VFS + processes**: initrd/ramfs, fd table, fork/execve/wait4, pipes, tty/termios, mmap/brk.
- **M7 – bash**: remaining syscalls + signals needed by bash, interactive prompt over serial. ✅ done

## Phase 2

- **M8 – COW fork**: shared frames with refcounts, write faults copy on demand. ✅
- **M9 – full signals**: stop/continue job control, siginfo, sigaltstack, RT signal queueing, alarm/itimer, sigtimedwait, waitid, SA_RESTART/ERESTARTSYS, SIGTTIN, SIGCHLD auto-reap. ✅
- **M10 – Zig 0.16.0**: port build system (root_module), kernel (Io.Writer logging, unmanaged ArrayList, asm clobber structs, own frame-pointer unwinder), userland rewritten on a tiny raw-syscall runtime (`userland/lib/sys.zig`). ✅
- **M11 – SMP**: Limine MP boot, per-CPU data/GDT/TSS/LAPIC timer (GS-based `current`), shared run queue with wake-up IPIs, big kernel lock taken on user→kernel entry and dropped on return / idle halt; sched_getaffinity + `nproc`. Tested with -smp 1/2/4. ✅
- **M12 – VFS + ext2**: inode-ops VFS with mounts, ramfs/devfs/ext2 drivers, virtio-blk, block cache, ext2 root.

## Later
SMP, COW fork, real block devices + ext2, framebuffer console, keyboard, networking.
