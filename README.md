# yos

A 64-bit hobby operating system written in Zig, booted by Limine, using uACPI,
and implementing the Linux x86_64 syscall ABI. Goal: run GNU bash.

See [PLAN.md](PLAN.md) for the design and milestones.

## Requirements
- Zig 0.14.1
- xorriso, make, a C compiler (for the Limine host tool)
- qemu-system-x86_64

## Build & run
```sh
./scripts/fetch-deps.sh   # Limine binaries
make run                  # build ISO and boot in QEMU (serial on stdio)
make test                 # automated boot test
```
