#!/usr/bin/env python3
"""Capture SPEC benchmark memory-access windows with the QEMU trace plugin.

This helper assumes the SPEC benchmarks were already built and runsetup was
already performed inside the Debian RV64 VM. For each benchmark it boots a
fresh QEMU instance with the memory-trace plugin enabled, runs the benchmark's
latest test-size run directory under trace start/stop markers, then shuts the
VM down.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path


DEFAULT_WINDOWS = "10000:10000;50000:5000;100000:5000;200000:5000;400000:5000"


def run(
    cmd: list[str],
    *,
    cwd: Path,
    check: bool = True,
    timeout_s: int | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd,
        check=check,
        timeout=timeout_s,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def ssh(
    repo: Path,
    command: str,
    *,
    check: bool = True,
    timeout_s: int | None = None,
) -> subprocess.CompletedProcess[str]:
    return run(
        [
            "ssh",
            "-p",
            "2222",
            "-o",
            f"UserKnownHostsFile={repo / 'debian-rv64' / 'ssh_known_hosts'}",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "ConnectTimeout=5",
            "-o",
            "ConnectionAttempts=1",
            "debian@127.0.0.1",
            command,
        ],
        cwd=repo,
        check=check,
        timeout_s=timeout_s,
    )


def wait_for_ssh(repo: Path, timeout_s: int) -> None:
    deadline = time.monotonic() + timeout_s
    last_output = ""
    while time.monotonic() < deadline:
        try:
            result = ssh(repo, "true", check=False, timeout_s=10)
        except subprocess.TimeoutExpired:
            last_output = "ssh probe timed out"
            time.sleep(5)
            continue
        if result.returncode == 0:
            return
        last_output = result.stdout.strip()
        time.sleep(5)
    raise RuntimeError(f"timed out waiting for VM SSH; last output: {last_output}")


def find_run_dir(repo: Path, bench: str, size: str, label: str) -> str:
    command = (
        "cd /home/debian/spec2026 && "
        f"find benchspec/CPU/{bench}/run -maxdepth 1 -type d "
        f"-name 'run_base_{size}_{label}*' | sort | tail -1"
    )
    result = ssh(repo, command)
    run_dir = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    if not run_dir:
        raise RuntimeError(f"no run directory found for {bench}; run runcpu --action=runsetup first")
    return f"/home/debian/spec2026/{run_dir}"


def capture_one(
    repo: Path,
    bench: str,
    out_dir: Path,
    windows: str,
    size: str,
    label: str,
    boot_timeout_s: int,
) -> None:
    raw_dir = out_dir / "raw"
    log_dir = out_dir / "logs"
    raw_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    trace_path = raw_dir / f"spec2026_{bench.replace('.', '_')}_{size}_windows.trace"
    boot_log = log_dir / f"spec2026_{bench.replace('.', '_')}_{size}_qemu.log"

    env = os.environ.copy()
    env["L1D_QEMU_PLUGIN_ARGS"] = (
        f"out={trace_path},start=off,aligned=on,noio=on,windows={windows}"
    )

    with boot_log.open("wb") as log:
        qemu = subprocess.Popen(
            [str(repo / "scripts" / "start_qemu_trace_vm.sh")],
            cwd=repo,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
        )

    try:
        wait_for_ssh(repo, boot_timeout_s)
        run_dir = find_run_dir(repo, bench, size, label)
        command = (
            "set -e; cd /home/debian/spec2026 && . ./shrc; "
            f"cd {run_dir}; "
            "/home/debian/trace_mark start; "
            "status=0; specinvoke -f speccmds.cmd || status=$?; "
            "/home/debian/trace_mark stop || true; "
            "if [ -f compare.cmd ]; then specinvoke -f compare.cmd || status=$?; fi; "
            "exit $status"
        )
        result = ssh(repo, command, check=False)
        (log_dir / f"spec2026_{bench.replace('.', '_')}_{size}_specinvoke.log").write_text(
            result.stdout, encoding="utf-8"
        )
        if result.returncode != 0:
            raise RuntimeError(f"{bench} specinvoke failed with {result.returncode}")
    finally:
        try:
            ssh(repo, "sudo poweroff", check=False, timeout_s=15)
        except subprocess.TimeoutExpired:
            pass
        try:
            qemu.wait(timeout=90)
        except subprocess.TimeoutExpired:
            qemu.terminate()
            try:
                qemu.wait(timeout=15)
            except subprocess.TimeoutExpired:
                qemu.kill()
                qemu.wait()

    if not trace_path.exists():
        raise RuntimeError(f"trace was not written: {trace_path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--out-dir", type=Path, default=Path("build/spec2026/qemu"))
    parser.add_argument("--windows", default=DEFAULT_WINDOWS)
    parser.add_argument("--size", default="test")
    parser.add_argument("--label", default="codexrv64")
    parser.add_argument("--boot-timeout-s", type=int, default=600)
    parser.add_argument("benchmarks", nargs="+")
    args = parser.parse_args()

    repo = args.repo.resolve()
    out_dir = args.out_dir if args.out_dir.is_absolute() else repo / args.out_dir

    for bench in args.benchmarks:
        print(f"capturing {bench}", flush=True)
        capture_one(repo, bench, out_dir, args.windows, args.size, args.label, args.boot_timeout_s)

    return 0


if __name__ == "__main__":
    sys.exit(main())
