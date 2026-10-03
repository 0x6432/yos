#!/usr/bin/env python3
"""Boot yos in QEMU (headless, serial on stdio) and drive it with expect/send steps."""
import os, select, subprocess, sys, time

QEMU = os.environ.get("QEMU", "qemu-system-x86_64")
ISO = os.environ.get("ISO", "build/yos.iso")

# (expect, send) steps. `send` may be None.
STEPS = [
    ("starting init: /bin/bash", None),
    ("# ", "echo hello from bash $BASH_VERSION, 6*7=$((6*7))\n"),
    ("6*7=42", None),
    ("# ", "uname -a; ls /bin | head -3; cat /etc/motd | wc -l\n"),
    ("yos yos", None),
    ("# ", "for i in 1 2 3; do echo -n \"n$i \"; done; echo; cat /etc/hostname | cat\n"),
    ("n1 n2 n3", None),
    ("# ", "cd /tmp && echo data > f.txt && cat f.txt && pwd\n"),
    ("/tmp", None),
    ("# ", "ktest\n"),
    ("TESTS PASSED", None),
    ("# ", "x=$(echo sub); echo \"[$x]\"; type cd; false || echo or-ok\n"),
    ("or-ok", None),
    ("# ", "sleep 30\n"),
    ("sleep 30", "\x03"),
    ("# ", "echo interrupted-ok; sleep 0.2 & wait; echo bg-done\n"),
    ("bg-done", None),
    ("# ", "exit\n"),
    ("init exited", None),
]

def main():
    timeout = float(os.environ.get("TEST_TIMEOUT", "60"))
    p = subprocess.Popen([QEMU, "-M", "q35", "-m", "512M", "-cdrom", ISO, "-serial", "stdio",
                          "-display", "none", "-no-reboot"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    buf = b""
    ok = True
    try:
        for expect, send in STEPS:
            deadline = time.time() + timeout
            start = len(buf)
            while expect.encode() not in buf[start:] and b"KERNEL PANIC" not in buf:
                r, _, _ = select.select([p.stdout], [], [], 0.2)
                if r:
                    chunk = os.read(p.stdout.fileno(), 4096)
                    if not chunk:
                        break
                    buf += chunk
                    sys.stdout.write(chunk.decode(errors="replace")); sys.stdout.flush()
                if time.time() > deadline:
                    break
            if expect.encode() not in buf[start:]:
                print(f"\n[test] FAILED waiting for {expect!r}")
                ok = False
                break
            if send is not None:
                time.sleep(0.3)
                for ch in send.encode():
                    p.stdin.write(bytes([ch])); p.stdin.flush(); time.sleep(0.01)
        # drain a little
        end = time.time() + 1
        while time.time() < end:
            r, _, _ = select.select([p.stdout], [], [], 0.2)
            if r:
                chunk = os.read(p.stdout.fileno(), 4096)
                if not chunk: break
                sys.stdout.write(chunk.decode(errors="replace"))
    finally:
        p.kill()
    print("\n[test] PASSED" if ok else "\n[test] FAILED")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
