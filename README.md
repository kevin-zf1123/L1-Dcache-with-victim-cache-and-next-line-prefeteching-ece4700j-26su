# L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su
Design and Evaluation of a High-Performance L1 Data Cache with Victim Cache and Next-Line Prefetching

## RV64 QEMU VM

Set the local Debian RV64 QEMU VM directory outside the repository:

```bash
export RV64_VM_DIR=/path/to/debian-rv64
```

Start the VM:

```bash
cd "$RV64_VM_DIR"
./start.sh
```

SSH into the running VM:

```bash
cd "$RV64_VM_DIR"
./ssh.sh
```

For SPEC CPU 2026 memory-trace capture, build the host QEMU plugin from this
repository:

```bash
scripts/build_qemu_memtrace_plugin.sh
```

Then start `qemu-system-riscv64` with the generated plugin
`build/qemu-memtrace/qemu_memtrace.dylib`. The detailed `782.lbm_r` build,
trace-capture, and validation procedure is recorded in
`docs/l1d_baseline.md`.
