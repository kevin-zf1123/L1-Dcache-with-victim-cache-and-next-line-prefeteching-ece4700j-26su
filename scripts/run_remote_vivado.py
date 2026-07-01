#!/usr/bin/env python3
"""Run this project's Vivado flow on the configured remote Windows host.

The remote account name and Vivado path are project infrastructure. The
password is intentionally not stored in this file. Set REMOTE_VIVADO_PASSWORD
for non-interactive use, or run from a TTY and enter it at the prompt.
"""

from __future__ import annotations

import argparse
import getpass
import os
import posixpath
import re
import socket
import stat
import sys
from pathlib import Path

DEFAULT_HOST = "192.168.1.101"
DEFAULT_USER = "王朱峯"
DEFAULT_VIVADO = "/cygdrive/e/software/Xilinx/Vivado/2024.2/bin/vivado.bat"
DEFAULT_REMOTE_ROOT = "C:/Users/kevin/l1d_codex_ascii_20260701"
DEFAULT_TCL = "scripts/run_vivado.tcl"

DEFAULT_UPLOADS = [
    "src/l1d_sram.sv",
    "src/l1d_next_line_prefetch.sv",
    "src/l1d_cache.sv",
    "src/tb_l1d_cache.sv",
    "src/tb_l1d_cache_oop.sv",
    "scripts/run_vivado.tcl",
    "constraints/l1d_baseline.xdc",
    "traces/smoke.trace",
    "traces/generated/phase3_matrix_row_major.trace",
    "traces/generated/phase3_matrix_column_major.trace",
    "traces/generated/phase3_pointer_permutation.trace",
    "traces/generated/phase3_pointer_mixed_update.trace",
    "traces/generated/MANIFEST.md",
]

DEFAULT_DOWNLOADS = [
    "build/vivado/reports",
    "vivado.log",
    "vivado.jou",
]

FAIL_PATTERNS = [
    re.compile(r"^\s*ERROR:", re.IGNORECASE),
    re.compile(r"^\s*CRITICAL WARNING:", re.IGNORECASE),
    re.compile(r"^\s*FATAL:", re.IGNORECASE),
    re.compile(r"couldn'?t read file", re.IGNORECASE),
    re.compile(r"\bFAIL\b", re.IGNORECASE),
    re.compile(r"source.*failed", re.IGNORECASE),
]

try:
    import paramiko
except ImportError as exc:
    raise SystemExit(
        "paramiko is required. Use the project-local .venv-remote-vivado "
        "environment or install paramiko in a temporary environment."
    ) from exc


def cygwin_path(path: str) -> str:
    normalized = path.replace("\\", "/")
    if len(normalized) >= 3 and normalized[1] == ":" and normalized[2] == "/":
        return f"/cygdrive/{normalized[0].lower()}{normalized[2:]}"
    return normalized


def windows_path(path: str) -> str:
    normalized = path.replace("\\", "/")
    if normalized.startswith("/cygdrive/") and len(normalized) >= 12:
        drive = normalized[10]
        return f"{drive.upper()}:{normalized[11:]}"
    return normalized


def ensure_remote_dir(sftp: paramiko.SFTPClient, remote_dir: str) -> None:
    parts = [part for part in remote_dir.split("/") if part]
    current = "/" if remote_dir.startswith("/") else ""
    for part in parts:
        current = posixpath.join(current, part)
        try:
            sftp.stat(current)
        except FileNotFoundError:
            sftp.mkdir(current)


def upload_file(
    sftp: paramiko.SFTPClient,
    local_root: Path,
    remote_root: str,
    rel_path: str,
) -> None:
    local_path = local_root / rel_path
    if not local_path.exists():
        raise FileNotFoundError(f"upload source does not exist: {rel_path}")
    remote_path = posixpath.join(remote_root, rel_path.replace("\\", "/"))
    ensure_remote_dir(sftp, posixpath.dirname(remote_path))
    sftp.put(str(local_path), remote_path)
    print(f"uploaded {rel_path}", flush=True)


def write_remote_text(
    sftp: paramiko.SFTPClient,
    remote_root: str,
    rel_path: str,
    text: str,
) -> None:
    remote_path = posixpath.join(remote_root, rel_path)
    ensure_remote_dir(sftp, posixpath.dirname(remote_path))
    with sftp.open(remote_path, "w") as remote_file:
        remote_file.write(text)
    print(f"wrote remote {rel_path}", flush=True)


def download_path(
    sftp: paramiko.SFTPClient,
    remote_path: str,
    local_path: Path,
) -> None:
    attrs = sftp.stat(remote_path)
    if stat.S_ISDIR(attrs.st_mode):
        local_path.mkdir(parents=True, exist_ok=True)
        for entry in sftp.listdir_attr(remote_path):
            download_path(
                sftp,
                posixpath.join(remote_path, entry.filename),
                local_path / entry.filename,
            )
    else:
        local_path.parent.mkdir(parents=True, exist_ok=True)
        sftp.get(remote_path, str(local_path))
        print(f"downloaded {remote_path}", flush=True)


def run_remote(ssh: paramiko.SSHClient, command: str) -> int:
    transport = ssh.get_transport()
    if transport is None:
        raise RuntimeError("SSH transport is not available")
    channel = transport.open_session()
    channel.get_pty()
    channel.exec_command(command)
    while True:
        while channel.recv_ready():
            sys.stdout.write(channel.recv(65536).decode("utf-8", "replace"))
            sys.stdout.flush()
        while channel.recv_stderr_ready():
            sys.stderr.write(channel.recv_stderr(65536).decode("utf-8", "replace"))
            sys.stderr.flush()
        if channel.exit_status_ready():
            break
    return channel.recv_exit_status()


def check_tcp(host: str, port: int, timeout: float = 5.0) -> None:
    with socket.create_connection((host, port), timeout=timeout):
        return


def scan_logs(local_root: Path, rel_paths: list[str]) -> int:
    checked = 0
    findings: list[str] = []
    candidate_files: list[Path] = []
    for rel in rel_paths:
        path = local_root / rel
        if path.is_dir():
            candidate_files.extend(path.rglob("*.log"))
            candidate_files.extend(path.rglob("*.jou"))
            candidate_files.extend(path.rglob("*.rpt"))
        elif path.exists() and path.suffix.lower() in {".log", ".jou", ".rpt"}:
            candidate_files.append(path)

    for path in sorted(set(candidate_files)):
        checked += 1
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            findings.append(f"{path}: cannot read log: {exc}")
            continue
        for line_no, line in enumerate(text.splitlines(), start=1):
            matched = None
            for pattern in FAIL_PATTERNS:
                if pattern.search(line):
                    matched = pattern
                    break
            if matched:
                findings.append(
                    f"{path}:{line_no}: matched {matched.pattern!r}: "
                    f"{line[:160]}"
                )
                break
        if path.name.endswith("_simulation.log") and "ALL OOP TESTS PASSED" not in text:
            findings.append(f"{path}: missing ALL OOP TESTS PASSED")

    print(f"scanned {checked} downloaded log/report files", flush=True)
    for finding in findings:
        print(f"LOG_SCAN_FAILURE {finding}", flush=True)
    return 1 if findings else 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-root", default=".")
    parser.add_argument(
        "--remote-root",
        default=os.environ.get("REMOTE_VIVADO_WORKDIR", DEFAULT_REMOTE_ROOT),
    )
    parser.add_argument(
        "--vivado",
        default=os.environ.get("REMOTE_VIVADO_LAUNCHER", DEFAULT_VIVADO),
    )
    parser.add_argument("--tcl", default=os.environ.get("REMOTE_VIVADO_TCL", DEFAULT_TCL))
    parser.add_argument("--upload", action="append", default=[])
    parser.add_argument("--download", action="append", default=[])
    parser.add_argument("--no-default-uploads", action="store_true")
    parser.add_argument("--no-default-downloads", action="store_true")
    parser.add_argument("--probe-only", action="store_true")
    parser.add_argument("--skip-log-scan", action="store_true")
    parser.add_argument("--part-env", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    host = os.environ.get("REMOTE_VIVADO_HOST", DEFAULT_HOST)
    user = os.environ.get("REMOTE_VIVADO_USER", DEFAULT_USER)
    password = os.environ.get("REMOTE_VIVADO_PASSWORD")
    if not password and sys.stdin.isatty():
        password = getpass.getpass(f"Password for {user}@{host}: ")
    if not password:
        raise SystemExit(
            "REMOTE_VIVADO_PASSWORD is required. Pass it only through the "
            "current process environment or the interactive password prompt."
        )

    check_tcp(host, 22)

    local_root = Path(args.local_root).resolve()
    remote_root = cygwin_path(args.remote_root)
    vivado = cygwin_path(args.vivado)
    uploads = [] if args.no_default_uploads else list(DEFAULT_UPLOADS)
    uploads.extend(args.upload)
    downloads = [] if args.no_default_downloads else list(DEFAULT_DOWNLOADS)
    downloads.extend(args.download)
    tcl_rel = args.tcl.replace("\\", "/")

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(
        hostname=host,
        username=user,
        password=password,
        look_for_keys=False,
        allow_agent=False,
    )
    sftp = ssh.open_sftp()
    try:
        ensure_remote_dir(sftp, remote_root)
        if args.probe_only:
            tcl_rel = "scripts/noop_probe.tcl"
            write_remote_text(
                sftp,
                remote_root,
                tcl_rel,
                "puts \"NOOP_PROBE Vivado [version -short]\"\nexit\n",
            )
            downloads = ["vivado.log", "vivado.jou"]
        else:
            for rel_path in uploads:
                upload_file(sftp, local_root, remote_root, rel_path)

        tcl_source = windows_path(posixpath.join(remote_root, tcl_rel))
        env_prefix = f"export L1D_PART='{args.part_env}'; " if args.part_env else ""
        command = (
            f"cd '{remote_root}' && {env_prefix}'{vivado}' "
            f"-mode batch -source '{tcl_source}'"
        )
        print(f"starting remote Vivado batch flow with source {tcl_source}", flush=True)
        status = run_remote(ssh, command)
        print(f"remote Vivado exit status: {status}", flush=True)

        for rel_path in downloads:
            remote_path = posixpath.join(remote_root, rel_path.replace("\\", "/"))
            try:
                download_path(sftp, remote_path, local_root / rel_path)
            except FileNotFoundError:
                print(f"missing remote download path: {rel_path}", flush=True)
                status = status or 1
    finally:
        sftp.close()
        ssh.close()

    if not args.skip_log_scan:
        status = status or scan_logs(local_root, downloads)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
