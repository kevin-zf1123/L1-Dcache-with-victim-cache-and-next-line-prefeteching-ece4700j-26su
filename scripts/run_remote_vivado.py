#!/usr/bin/env python3
"""Run this project's Vivado flow on the configured remote Windows host.

The remote account name and Vivado path are project infrastructure. The
password is intentionally not stored in this file. Set REMOTE_VIVADO_PASSWORD
for non-interactive use, or run from a TTY and enter it at the prompt.
"""

from __future__ import annotations

import argparse
from collections import Counter
import getpass
import hashlib
import json
import os
import posixpath
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_HOST = "192.168.1.101"
DEFAULT_USER = "王朱峯"
DEFAULT_VIVADO = "/cygdrive/e/software/Xilinx/Vivado/2024.2/bin/vivado.bat"
DEFAULT_REMOTE_ROOT = "C:/Users/kevin/l1d_codex_ascii_20260713_optimized"
DEFAULT_TCL = "scripts/run_vivado.tcl"

DEFAULT_UPLOADS = [
    "src/l1d_sram.sv",
    "src/l1d_next_line_prefetch.sv",
    "src/l1d_stream_prefetch.sv",
    "src/l1d_prefetch_controller.sv",
    "src/l1d_shadow_cache.sv",
    "src/l1d_cache_legacy.sv",
    "src/l1d_cache_optimized.sv",
    "src/l1d_cache.sv",
    "src/l1d_cache_deploy.sv",
    "src/l1d_fpga_harness.sv",
    "src/tb_l1d_cache.sv",
    "src/tb_l1d_cache_oop.sv",
    "src/tb_l1d_prefetch_units.sv",
    "src/tb_l1d_cache_p3.sv",
    "src/tb_l1d_cache_optimized_p3.sv",
    "src/tb_l1d_fpga_harness.sv",
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

SIMULATION_CONFIGURATIONS = {
    "dm_s8_vc4_pf0": {
        "sets": 8, "ways": 1, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 0, "mem_latency": 2, "mem_bp": 1, "cpu_bp": 0,
    },
    "2w_s4_vc4_pf0": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 0, "mem_latency": 2, "mem_bp": 1, "cpu_bp": 0,
    },
    "2w_s4_vc8_pf0": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 8,
        "prefetch": 0, "mem_latency": 2, "mem_bp": 1, "cpu_bp": 0,
    },
    "2w_s4_vc4_pf1": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 1, "mem_latency": 2, "mem_bp": 1, "cpu_bp": 0,
    },
    "trace_replay_smoke_2w_s4_vc4_pf0": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 0, "mem_latency": 2, "mem_bp": 1, "cpu_bp": 0,
    },
    "trace_replay_generated_pointer_2w_s4_vc4_pf1": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 1, "mem_latency": 2, "mem_bp": 1, "cpu_bp": 0,
    },
    "2w_s4_vc4_pf1_low_latency": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 1, "mem_latency": 0, "mem_bp": 0, "cpu_bp": 0,
    },
    "2w_s4_vc4_pf1_high_latency_random_bp": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 1, "mem_latency": 8, "mem_bp": 2, "cpu_bp": 0,
    },
}
for _geometry in SIMULATION_CONFIGURATIONS.values():
    _geometry["prefetch_policy"] = 1
    _geometry["pf_opt_level"] = 3

SYNTHESIS_CONFIGURATIONS = {
    "optimized_pf0_deploy": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 0, "prefetch_policy": 1, "pf_opt_level": 1,
        "pf_use_stream": 0, "pf_use_adaptive": 0,
        "pf_use_shadow": 0, "pf_use_mshr": 0,
        "top": "l1d_cache_deploy", "profile": "deploy",
    },
    "optimized_pf0_deploy_vc_lookup": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 0, "prefetch_policy": 1, "pf_opt_level": 1,
        "pf_use_stream": 0, "pf_use_adaptive": 0,
        "pf_use_shadow": 0, "pf_use_mshr": 0,
        "vc_format_in_swap": 0,
        "top": "l1d_cache_deploy", "profile": "deploy-vc-lookup-ab",
    },
    "p3_research": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 1, "prefetch_policy": 1, "pf_opt_level": 3,
        "pf_use_stream": 1, "pf_use_adaptive": 1,
        "pf_use_shadow": 1, "pf_use_mshr": 1,
        "top": "l1d_cache", "profile": "research",
    },
    "p3_deploy": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 1, "prefetch_policy": 1, "pf_opt_level": 3,
        "pf_use_stream": 1, "pf_use_adaptive": 1,
        "pf_use_shadow": 1, "pf_use_mshr": 1,
        "top": "l1d_cache_deploy", "profile": "deploy",
    },
    "p3_no_shadow_proxy": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 1, "prefetch_policy": 1, "pf_opt_level": 3,
        "pf_use_stream": 1, "pf_use_adaptive": 1,
        "pf_use_shadow": 0, "pf_use_mshr": 1,
        "top": "l1d_cache_deploy", "profile": "deploy-raw-proxy",
    },
    "p3_lite_mshr_fixed": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 1, "prefetch_policy": 1, "pf_opt_level": 3,
        "pf_use_stream": 1, "pf_use_adaptive": 0,
        "pf_use_shadow": 0, "pf_use_mshr": 1,
        "top": "l1d_cache_deploy", "profile": "deploy-fixed",
    },
    "stream_detector_only": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 1, "prefetch_policy": 1, "pf_opt_level": 3,
        "pf_use_stream": 1, "pf_use_adaptive": 0,
        "pf_use_shadow": 0, "pf_use_mshr": 0,
        "top": "l1d_cache_deploy", "profile": "deploy-stream-only",
    },
    "legacy_matched": {
        "sets": 4, "ways": 2, "line_bytes": 16, "victim_entries": 4,
        "prefetch": 1, "prefetch_policy": 0, "pf_opt_level": 0,
        "pf_use_stream": 0, "pf_use_adaptive": 0,
        "pf_use_shadow": 0, "pf_use_mshr": 0,
        "top": "l1d_cache_deploy", "profile": "legacy",
    },
}
for _geometry in SYNTHESIS_CONFIGURATIONS.values():
    _geometry.setdefault("vc_format_in_swap", 1)
    _geometry.setdefault("pf_idle_guard", 2)
    _geometry.setdefault("pf_epoch_demands", 256)
    _geometry.setdefault("pf_off_demands", 512)
    _geometry.setdefault("pf_probe_budget", 8)
    _geometry.setdefault("pf_probe_refill", 16)
    _geometry.setdefault("pf_on_refill", 8)

IMPLEMENTATION_CONFIGURATIONS = {
    name: SYNTHESIS_CONFIGURATIONS[name]
    for name in (
        "optimized_pf0_deploy",
        "p3_deploy",
        "p3_lite_mshr_fixed",
        "legacy_matched",
    )
}

ACTIVITY_SIMULATIONS = {
    f"harness_{name}": "PASS: deploy harness"
    for name in IMPLEMENTATION_CONFIGURATIONS
}

AUXILIARY_SIMULATIONS = {
    "prefetch_units": "directed prefetch-unit checks",
    "p3_prefetch_mshr": "directed P3 PF-MSHR checks",
    "p3_prefetch_edges": "PASS P3 accounting",
}

BASE_WORKLOADS = (
    "directed_rv64",
    "victim_dirty_regression",
    "cpu_response_backpressure",
    "matrix_row_major",
    "matrix_column_major",
    "matrix_blocked_tiled",
    "matrix_same_set_exceeds_l1",
    "matrix_same_set_exceeds_l1_plus_victim",
    "matrix_store_heavy_dirty",
    "pointer_random_permutation",
    "pointer_conflict_chain",
    "pointer_irregular_defeats_next_line",
    "pointer_mixed_load_store_update",
)

SIMULATION_WORKLOADS = {
    name: BASE_WORKLOADS
    for name in (
        "dm_s8_vc4_pf0",
        "2w_s4_vc4_pf0",
        "2w_s4_vc8_pf0",
    )
}
SIMULATION_WORKLOADS.update(
    {
        name: BASE_WORKLOADS + ("external_prefetch_matrix_candidates",)
        for name in (
            "2w_s4_vc4_pf1",
            "2w_s4_vc4_pf1_low_latency",
            "2w_s4_vc4_pf1_high_latency_random_bp",
        )
    }
)
SIMULATION_WORKLOADS.update(
    {
        "trace_replay_smoke_2w_s4_vc4_pf0": ("trace_replay",),
        "trace_replay_generated_pointer_2w_s4_vc4_pf1": ("trace_replay",),
    }
)

SYNTHESIS_PARAMETER_FIELDS = {
    "LINE_BYTES": "line_bytes",
    "NUM_SETS": "sets",
    "NUM_WAYS": "ways",
    "VICTIM_ENTRIES": "victim_entries",
    "ENABLE_PREFETCH": "prefetch",
    "PREFETCH_POLICY": "prefetch_policy",
    "PF_OPT_LEVEL": "pf_opt_level",
    "PF_USE_STREAM": "pf_use_stream",
    "PF_USE_ADAPTIVE": "pf_use_adaptive",
    "PF_USE_SHADOW": "pf_use_shadow",
    "PF_USE_MSHR": "pf_use_mshr",
    "PF_IDLE_GUARD": "pf_idle_guard",
    "PF_EPOCH_DEMANDS": "pf_epoch_demands",
    "PF_OFF_DEMANDS": "pf_off_demands",
    "PF_PROBE_BUDGET": "pf_probe_budget",
    "PF_PROBE_REFILL": "pf_probe_refill",
    "PF_ON_REFILL": "pf_on_refill",
    "VC_FORMAT_IN_SWAP": "vc_format_in_swap",
}

OOC_REPORTS = (
    "utilization.rpt",
    "hierarchical_utilization.rpt",
    "timing_summary.rpt",
    "timing_top20.rpt",
    "high_fanout.rpt",
    "control_sets.rpt",
    "unconstrained_paths.rpt",
    "power_vectorless.rpt",
    "synth.dcp",
)

IMPLEMENTATION_REPORTS = (
    "post_route_utilization.rpt",
    "post_route_hierarchical_utilization.rpt",
    "post_route_timing_summary.rpt",
    "post_route_timing_top20.rpt",
    "post_route_high_fanout.rpt",
    "post_route_control_sets.rpt",
    "post_route_unconstrained_paths.rpt",
    "post_route_power_vectorless.rpt",
    "post_route_power_activity.rpt",
    "activity_annotation.rpt",
    "post_route.dcp",
)

REQUIRED_EVIDENCE_ARTIFACTS = (
    "build/vivado/reports/2w_s4_vc4_pf1.vcd",
    "build/vivado/reports/activity/optimized_pf0_deploy.saif",
    "build/vivado/reports/activity/p3_deploy.saif",
    "build/vivado/reports/activity/p3_lite_mshr_fixed.saif",
    "build/vivado/reports/activity/legacy_matched.saif",
    "vivado.log",
    "vivado.jou",
)

FAIL_PATTERNS = [
    re.compile(r"^\s*ERROR:", re.IGNORECASE),
    re.compile(r"^\s*CRITICAL WARNING:", re.IGNORECASE),
    re.compile(r"^\s*FATAL:", re.IGNORECASE),
    re.compile(r"couldn'?t read file", re.IGNORECASE),
    re.compile(r"\bFAIL\b", re.IGNORECASE),
    re.compile(r"source.*failed", re.IGNORECASE),
]

# This warning reports a design-gate outcome, not a Vivado execution failure.
# The exact WNS/TNS result is parsed from the dedicated timing report and is
# evaluated by evaluate_prefetch_evidence.py. Keep this allowlist deliberately
# narrow so every other CRITICAL WARNING still fails evidence collection.
EXPECTED_GATE_WARNING_PATTERNS = [
    re.compile(
        r"^\s*CRITICAL WARNING:\s*\[Timing 38-282\]\s+"
        r"The design failed to meet the timing requirements\.\s+"
        r"Please see the timing summary report for details on the timing "
        r"violations\.\s*$",
        re.IGNORECASE,
    ),
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


def scan_logs(local_root: Path, rel_paths: list[str]) -> tuple[int, list[str]]:
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
            if any(
                pattern.search(line)
                for pattern in EXPECTED_GATE_WARNING_PATTERNS
            ):
                continue
            matched = None
            patterns = FAIL_PATTERNS
            if path.suffix.lower() == ".rpt":
                # Timing/check reports legitimately use FAIL as a status word.
                # Numerical timing and unconstrained-path gates are evaluated
                # from their dedicated reports, not as tool-crash signatures.
                patterns = FAIL_PATTERNS[:-2]
            for pattern in patterns:
                if pattern.search(line):
                    matched = pattern
                    break
            if matched:
                findings.append(
                    f"{path}:{line_no}: matched {matched.pattern!r}: "
                    f"{line[:160]}"
                )
                break
        simulation_suffix = "_simulation.log"
        if path.name.endswith(simulation_suffix):
            simulation_name = path.name[: -len(simulation_suffix)]
            expected_pass_marker = AUXILIARY_SIMULATIONS.get(simulation_name)
            if expected_pass_marker is None:
                expected_pass_marker = ACTIVITY_SIMULATIONS.get(
                    simulation_name, "ALL OOP TESTS PASSED"
                )
            if expected_pass_marker not in text:
                findings.append(
                    f"{path}: missing PASS marker {expected_pass_marker!r}"
                )

    print(f"scanned {checked} downloaded log/report files", flush=True)
    for finding in findings:
        print(f"LOG_SCAN_FAILURE {finding}", flush=True)
    return (1 if findings else 0), findings


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def clear_local_download(path: Path) -> None:
    """Remove a prior download so a failed transfer cannot reuse stale evidence."""
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def execution_evidence(
    command: str,
    remote_exit_status: int,
    download_failures: list[str],
    *,
    log_scan_skipped: bool,
) -> tuple[dict[str, object], list[str]]:
    """Build manifest execution metadata and fail-closed findings."""
    findings: list[str] = []
    if remote_exit_status != 0:
        findings.append(f"remote Vivado exited with status {remote_exit_status}")
    for rel_path in download_failures:
        findings.append(f"remote download failed: {rel_path}")
    if log_scan_skipped:
        findings.append("downloaded log scan was skipped")
    return (
        {
            "command": command,
            "remote_exit_status": remote_exit_status,
            "download_failures": list(download_failures),
            "log_scan_skipped": log_scan_skipped,
        },
        findings,
    )


def parse_vivado_parameters(
    path: Path, stage: str
) -> dict[str, dict[str, set[int]]]:
    """Read parameter bindings for one marked Vivado matrix stage."""
    text = path.read_text(encoding="utf-8", errors="replace")
    starts = list(
        re.finditer(
            r"^Running Vivado (synthesis|implementation): (\S+)\s*$",
            text,
            re.MULTILINE,
        )
    )
    result: dict[str, dict[str, set[int]]] = {}
    for index, match in enumerate(starts):
        if match.group(1) != stage:
            continue
        end = starts[index + 1].start() if index + 1 < len(starts) else len(text)
        section = text[match.end() : end]
        parameters: dict[str, set[int]] = {}
        for parameter, value in re.findall(
            r"^\s*Parameter\s+(\S+)\s+bound to:\s+([0-9]+)\b",
            section,
            re.MULTILINE,
        ):
            parameters.setdefault(parameter, set()).add(int(value))
        result[match.group(2)] = parameters
    return result


def parse_synthesis_parameters(path: Path) -> dict[str, dict[str, set[int]]]:
    """Read the parameter bindings Vivado reports for each OOC synthesis point."""
    return parse_vivado_parameters(path, "synthesis")


def parse_implementation_parameters(path: Path) -> dict[str, dict[str, set[int]]]:
    """Read the parameter bindings Vivado reports for each harness build."""
    return parse_vivado_parameters(path, "implementation")


def parse_workload_results(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith("WORKLOAD_RESULT "):
            continue
        row: dict[str, str] = {}
        for token in shlex.split(line[len("WORKLOAD_RESULT ") :]):
            if "=" not in token:
                raise ValueError(f"{path}: malformed WORKLOAD_RESULT token {token!r}")
            key, value = token.split("=", 1)
            if key in row:
                raise ValueError(f"{path}: duplicate WORKLOAD_RESULT field {key!r}")
            row[key] = value
        rows.append(row)
    return rows


class ReportParseError(ValueError):
    """A required numerical Vivado report field is absent or malformed."""


def _read_report(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ReportParseError(f"{path}: cannot read report: {exc}") from exc


def parse_utilization_report(path: Path) -> dict[str, int]:
    """Parse the first summary table from a Vivado utilization report."""
    text = _read_report(path)
    labels = {
        "slice_luts": r"Slice LUTs\*?",
        "lut_as_logic": r"LUT as Logic",
        "lut_as_memory": r"LUT as Memory",
        "slice_registers": r"Slice Registers",
        "f7_muxes": r"F7 Muxes",
        "f8_muxes": r"F8 Muxes",
        "block_ram_tiles": r"Block RAM Tile",
    }
    values: dict[str, int] = {}
    for field, label in labels.items():
        match = re.search(
            rf"^\|\s*{label}\s*\|\s*([0-9]+)\s*\|",
            text,
            re.MULTILINE,
        )
        if match is None:
            raise ReportParseError(f"{path}: missing utilization field {field}")
        values[field] = int(match.group(1), 10)
    control_sets = re.search(
        r"^\|\s*Unique Control Sets\s*\|\s*([0-9]+)\s*\|",
        text,
        re.MULTILINE,
    )
    values["unique_control_sets"] = (
        int(control_sets.group(1), 10) if control_sets else 0
    )
    return values


def parse_timing_summary_report(
    path: Path, *, clock_period_ns: float = 10.0
) -> dict[str, float | int]:
    """Parse setup/hold summary and check_timing counts fail-closed."""
    text = _read_report(path)
    check_start = text.find("check_timing report")
    if check_start < 0:
        raise ReportParseError(f"{path}: missing check_timing report")
    summary_start = text.find("| Design Timing Summary", check_start)
    if summary_start < 0:
        raise ReportParseError(f"{path}: missing Design Timing Summary")
    check_section = text[check_start:summary_start]
    summary = text[summary_start:]
    row = re.search(
        r"^\s*(-?[0-9]+(?:\.[0-9]+)?)\s+"
        r"(-?[0-9]+(?:\.[0-9]+)?)\s+([0-9]+)\s+([0-9]+)\s+"
        r"(-?[0-9]+(?:\.[0-9]+)?)\s+"
        r"(-?[0-9]+(?:\.[0-9]+)?)\s+([0-9]+)\s+([0-9]+)",
        summary,
        re.MULTILINE,
    )
    if row is None:
        raise ReportParseError(f"{path}: missing numerical timing summary row")
    wns = float(row.group(1))
    tns = float(row.group(2))
    setup_failing = int(row.group(3), 10)
    whs = float(row.group(5))
    ths = float(row.group(6))
    hold_failing = int(row.group(7), 10)
    data_path_ns = clock_period_ns - wns
    if data_path_ns <= 0:
        raise ReportParseError(
            f"{path}: impossible slack-derived data path {data_path_ns} ns"
        )
    checks: dict[str, int] = {}
    for name in (
        "no_clock",
        "constant_clock",
        "unconstrained_internal_endpoints",
        "no_input_delay",
        "no_output_delay",
        "multiple_clock",
        "loops",
        "partial_input_delay",
        "partial_output_delay",
        "latch_loops",
    ):
        matches = re.findall(rf"checking {name} \(([0-9]+)\)", check_section)
        if len(matches) != 2 or matches[0] != matches[1]:
            raise ReportParseError(
                f"{path}: inconsistent check_timing count {name}: {matches}"
            )
        checks[name] = int(matches[0], 10)
    return {
        "wns_ns": wns,
        "tns_ns": tns,
        "setup_failing_endpoints": setup_failing,
        "whs_ns": whs,
        "ths_ns": ths,
        "hold_failing_endpoints": hold_failing,
        "clock_period_ns": clock_period_ns,
        "slack_derived_fmax_mhz": 1000.0 / data_path_ns,
        **{f"check_{name}": count for name, count in checks.items()},
    }


def parse_power_report(path: Path) -> dict[str, float | int | str | None]:
    """Parse the Vivado power summary and available activity provenance."""
    text = _read_report(path)

    def table_value(label: str) -> str:
        match = re.search(
            rf"^\|\s*{re.escape(label)}\s*\|\s*([^|]+?)\s*\|",
            text,
            re.MULTILINE,
        )
        if match is None:
            raise ReportParseError(f"{path}: missing power field {label}")
        return match.group(1).strip()

    try:
        total = float(table_value("Total On-Chip Power (W)"))
        dynamic = float(table_value("Dynamic (W)"))
        static = float(table_value("Device Static (W)"))
    except ValueError as exc:
        raise ReportParseError(f"{path}: malformed numerical power field") from exc
    activity_file = table_value("Simulation Activity File")
    matched_text = table_value("Design Nets Matched")
    matched_count = re.fullmatch(r"([0-9]+)\s+of\s+([0-9]+)", matched_text)
    matched_percent = re.fullmatch(
        r"([0-9]+(?:\.[0-9]+)?)%\s*\(([0-9]+)/([0-9]+)\)",
        matched_text,
    )
    if matched_count:
        matched_nets: int | None = int(matched_count.group(1), 10)
        total_nets: int | None = int(matched_count.group(2), 10)
    elif matched_percent:
        reported_percent = float(matched_percent.group(1))
        matched_nets = int(matched_percent.group(2), 10)
        total_nets = int(matched_percent.group(3), 10)
        if not 0.0 <= reported_percent <= 100.0:
            raise ReportParseError(
                f"{path}: out-of-range Design Nets Matched percentage "
                f"{reported_percent}"
            )
        if total_nets <= 0 or matched_nets > total_nets:
            raise ReportParseError(
                f"{path}: invalid Design Nets Matched counts "
                f"{matched_nets}/{total_nets}"
            )
        calculated_percent = 100.0 * matched_nets / total_nets
        if abs(reported_percent - calculated_percent) > 1.0:
            raise ReportParseError(
                f"{path}: inconsistent Design Nets Matched value "
                f"{matched_text!r}"
            )
    elif matched_text == "NA":
        matched_nets = None
        total_nets = None
    else:
        raise ReportParseError(
            f"{path}: malformed Design Nets Matched value {matched_text!r}"
        )
    if total_nets is not None and (
        total_nets <= 0 or matched_nets is None or matched_nets > total_nets
    ):
        raise ReportParseError(
            f"{path}: invalid Design Nets Matched counts "
            f"{matched_nets}/{total_nets}"
        )
    return {
        "total_on_chip_w": total,
        "dynamic_w": dynamic,
        "device_static_w": static,
        "confidence": table_value("Confidence Level"),
        "simulation_activity_file": (
            None if activity_file in {"---", "NA"} else activity_file
        ),
        "matched_design_nets": matched_nets,
        "total_design_nets": total_nets,
    }


def validate_optimized_lifecycle(
    row: dict[str, str], context: str
) -> list[str]:
    """Fail closed on drained schema-3 optimized-prefetch lifecycle state."""
    fields = (
        "pf_admitted",
        "pf_issued",
        "pf_returned",
        "pf_installed",
        "pf_merged",
        "pf_discarded",
        "pf_cancelled",
        "timely_useful",
        "pf_unused_evicted",
        "pf_unused_resident",
        "pf_caused_writebacks",
        "pf_mshr_valid",
    )
    findings: list[str] = []
    values: dict[str, int] = {}
    for field in fields:
        raw = row.get(field)
        if raw is None:
            findings.append(f"{context}: missing optimized lifecycle field {field}")
        elif not re.fullmatch(r"[0-9]+", raw):
            findings.append(
                f"{context}: {field}={raw!r}, expected non-negative decimal integer"
            )
        else:
            values[field] = int(raw, 10)

    if len(values) != len(fields):
        return findings

    if values["pf_admitted"] > values["pf_issued"] + values["pf_cancelled"]:
        findings.append(
            f"{context}: pf_admitted must be <= pf_issued + pf_cancelled "
            "after drain"
        )
    if values["pf_issued"] != values["pf_returned"]:
        findings.append(
            f"{context}: lifecycle conservation failure "
            "pf_issued == pf_returned"
        )
    if values["pf_returned"] != (
        values["pf_installed"] + values["pf_merged"] + values["pf_discarded"]
    ):
        findings.append(
            f"{context}: lifecycle conservation failure pf_returned == "
            "pf_installed + pf_merged + pf_discarded"
        )
    if values["pf_installed"] != (
        values["timely_useful"]
        + values["pf_unused_evicted"]
        + values["pf_unused_resident"]
    ):
        findings.append(
            f"{context}: lifecycle conservation failure pf_installed == "
            "timely_useful + pf_unused_evicted + pf_unused_resident"
        )
    if values["pf_caused_writebacks"] != 0:
        findings.append(
            f"{context}: pf_caused_writebacks="
            f"{values['pf_caused_writebacks']}, expected 0"
        )
    if values["pf_mshr_valid"] != 0:
        findings.append(
            f"{context}: pf_mshr_valid={values['pf_mshr_valid']}, expected 0"
        )
    return findings


def validate_report_matrix(local_root: Path) -> tuple[list[str], dict[str, object]]:
    report_root = local_root / "build" / "vivado" / "reports"
    findings: list[str] = []
    evidence: dict[str, object] = {
        "simulations": [],
        "synthesis": [],
        "implementation": [],
        "artifacts": {},
    }

    expected_logs = {
        f"{name}_simulation.log" for name in SIMULATION_CONFIGURATIONS
    } | {
        f"{name}_simulation.log" for name in AUXILIARY_SIMULATIONS
    } | {
        f"{name}_simulation.log" for name in ACTIVITY_SIMULATIONS
    }
    actual_logs = {path.name for path in report_root.glob("*_simulation.log")}
    if actual_logs != expected_logs:
        findings.append(
            "simulation log set mismatch: "
            f"missing={sorted(expected_logs - actual_logs)} "
            f"extra={sorted(actual_logs - expected_logs)}"
        )

    expected_dirs = {"ooc", "implementation", "activity"}
    actual_dirs = {path.name for path in report_root.iterdir() if path.is_dir()} \
        if report_root.is_dir() else set()
    if actual_dirs != expected_dirs:
        findings.append(
            "synthesis directory set mismatch: "
            f"missing={sorted(expected_dirs - actual_dirs)} "
            f"extra={sorted(actual_dirs - expected_dirs)}"
        )

    for name, geometry in SIMULATION_CONFIGURATIONS.items():
        log = report_root / f"{name}_simulation.log"
        if not log.is_file():
            continue
        try:
            rows = parse_workload_results(log)
        except (OSError, UnicodeError, ValueError) as exc:
            findings.append(str(exc))
            rows = []
        if not rows:
            findings.append(f"{log}: no WORKLOAD_RESULT rows")

        expected_workloads = SIMULATION_WORKLOADS[name]
        actual_workloads = [row.get("name", "<missing>") for row in rows]
        counts = Counter(actual_workloads)
        missing_workloads = sorted(set(expected_workloads) - set(actual_workloads))
        extra_workloads = sorted(set(actual_workloads) - set(expected_workloads))
        duplicate_workloads = sorted(
            workload for workload, count in counts.items() if count != 1
        )
        if (
            len(actual_workloads) != len(expected_workloads)
            or missing_workloads
            or extra_workloads
            or duplicate_workloads
        ):
            findings.append(
                f"{log}: workload matrix mismatch: "
                f"expected_count={len(expected_workloads)} "
                f"actual_count={len(actual_workloads)} "
                f"missing={missing_workloads} extra={extra_workloads} "
                f"duplicates={duplicate_workloads}"
            )

        for index, row in enumerate(rows):
            context = f"{log}:result[{index}]"
            expected_config_id = name
            if name.startswith("trace_replay_smoke_"):
                expected_config_id = "2w_s4_vc4_pf0"
            elif name.startswith("trace_replay_generated_pointer_") or name.startswith(
                "2w_s4_vc4_pf1_"
            ):
                expected_config_id = "2w_s4_vc4_pf1"
            expected_fields = {
                "schema": 3,
                "config_id": expected_config_id,
                "sets": geometry["sets"],
                "ways": geometry["ways"],
                "line_bytes": geometry["line_bytes"],
                "l1_bytes": (
                    geometry["sets"] * geometry["ways"] * geometry["line_bytes"]
                ),
                "victim_entries": geometry["victim_entries"],
                "victim_bytes": geometry["victim_entries"] * geometry["line_bytes"],
                "total_bytes": (
                    geometry["sets"] * geometry["ways"] * geometry["line_bytes"]
                    + geometry["victim_entries"] * geometry["line_bytes"]
                ),
                "mem_latency": geometry["mem_latency"],
                "mem_bp": geometry["mem_bp"],
                "cpu_bp": geometry["cpu_bp"],
                "status": "PASS",
                "watchdogs": 0,
                "protocol": 0,
                "duplicate_lines": 0,
            }
            for field, expected in expected_fields.items():
                if row.get(field) != str(expected):
                    findings.append(
                        f"{context}: {field}={row.get(field)!r}, expected {expected!r}"
                    )
            if row.get("schema") == "3":
                findings.extend(validate_optimized_lifecycle(row, context))
        evidence["simulations"].append(
            {
                "config_id": name,
                "geometry": geometry,
                "log": str(log.relative_to(local_root)),
                "sha256": sha256(log),
                "workload_results": len(rows),
                "workloads": actual_workloads,
            }
        )

    for name, pass_marker in AUXILIARY_SIMULATIONS.items():
        log = report_root / f"{name}_simulation.log"
        if not log.is_file():
            continue
        text = log.read_text(encoding="utf-8", errors="replace")
        if pass_marker not in text:
            findings.append(f"{log}: missing PASS marker {pass_marker!r}")
        evidence["simulations"].append(
            {
                "config_id": name,
                "geometry": None,
                "log": str(log.relative_to(local_root)),
                "sha256": sha256(log),
                "workload_results": 0,
                "workloads": [],
            }
        )

    for name, pass_marker in ACTIVITY_SIMULATIONS.items():
        log = report_root / f"{name}_simulation.log"
        if not log.is_file():
            continue
        text = log.read_text(encoding="utf-8", errors="replace")
        if pass_marker not in text:
            findings.append(f"{log}: missing PASS marker {pass_marker!r}")
        evidence["simulations"].append(
            {
                "config_id": name,
                "geometry": IMPLEMENTATION_CONFIGURATIONS[
                    name.removeprefix("harness_")
                ],
                "log": str(log.relative_to(local_root)),
                "sha256": sha256(log),
                "workload_results": 0,
                "workloads": [],
            }
        )

    vivado_log = local_root / "vivado.log"
    synthesis_parameters: dict[str, dict[str, set[int]]] = {}
    implementation_parameters: dict[str, dict[str, set[int]]] = {}
    if vivado_log.is_file():
        try:
            synthesis_parameters = parse_synthesis_parameters(vivado_log)
            implementation_parameters = parse_implementation_parameters(vivado_log)
        except (OSError, UnicodeError, ValueError) as exc:
            findings.append(f"cannot parse Vivado parameters: {exc}")
    actual_synthesis_sections = set(synthesis_parameters)
    expected_synthesis_sections = set(SYNTHESIS_CONFIGURATIONS)
    if actual_synthesis_sections != expected_synthesis_sections:
        findings.append(
            "Vivado synthesis section mismatch: "
            f"missing={sorted(expected_synthesis_sections - actual_synthesis_sections)} "
            f"extra={sorted(actual_synthesis_sections - expected_synthesis_sections)}"
        )

    for name, geometry in SYNTHESIS_CONFIGURATIONS.items():
        report_dir = report_root / "ooc" / name
        artifacts: dict[str, dict[str, str]] = {}
        for filename in OOC_REPORTS:
            report = report_dir / filename
            if not report.is_file():
                findings.append(f"missing synthesis report: {report}")
                continue
            artifacts[filename] = {
                "path": str(report.relative_to(local_root)),
                "sha256": sha256(report),
            }
        metrics: dict[str, object] = {}
        for metric_name, filename, parser in (
            ("utilization", "utilization.rpt", parse_utilization_report),
            ("timing", "timing_summary.rpt", parse_timing_summary_report),
            ("power_vectorless", "power_vectorless.rpt", parse_power_report),
        ):
            report = report_dir / filename
            if not report.is_file():
                continue
            try:
                metrics[metric_name] = parser(report)
            except ReportParseError as exc:
                findings.append(str(exc))
        bound_parameters = synthesis_parameters.get(name, {})
        normalized_parameters: dict[str, object] = {}
        for parameter, geometry_field in SYNTHESIS_PARAMETER_FIELDS.items():
            values = bound_parameters.get(parameter, set())
            expected_value = geometry[geometry_field]
            if values != {expected_value}:
                findings.append(
                    f"Vivado synthesis {name}: {parameter} bindings="
                    f"{sorted(values)}, expected [{expected_value}]"
                )
            normalized_parameters[parameter] = (
                next(iter(values)) if len(values) == 1 else sorted(values)
            )
        evidence["synthesis"].append(
            {
                "config_id": name,
                "geometry": geometry,
                "bound_parameters": normalized_parameters,
                "reports": artifacts,
                "metrics": metrics,
            }
        )

    actual_implementation_sections = set(implementation_parameters)
    expected_implementation_sections = set(IMPLEMENTATION_CONFIGURATIONS)
    if actual_implementation_sections != expected_implementation_sections:
        findings.append(
            "Vivado implementation section mismatch: "
            f"missing={sorted(expected_implementation_sections - actual_implementation_sections)} "
            f"extra={sorted(actual_implementation_sections - expected_implementation_sections)}"
        )

    for name, geometry in IMPLEMENTATION_CONFIGURATIONS.items():
        report_dir = report_root / "implementation" / name
        artifacts = {}
        for filename in IMPLEMENTATION_REPORTS:
            report = report_dir / filename
            if not report.is_file():
                findings.append(f"missing implementation report: {report}")
                continue
            artifacts[filename] = {
                "path": str(report.relative_to(local_root)),
                "sha256": sha256(report),
            }
        metrics = {}
        for metric_name, filename, parser in (
            (
                "utilization",
                "post_route_utilization.rpt",
                parse_utilization_report,
            ),
            (
                "timing",
                "post_route_timing_summary.rpt",
                parse_timing_summary_report,
            ),
            (
                "power_vectorless",
                "post_route_power_vectorless.rpt",
                parse_power_report,
            ),
            (
                "power_activity",
                "post_route_power_activity.rpt",
                parse_power_report,
            ),
        ):
            report = report_dir / filename
            if not report.is_file():
                continue
            try:
                metrics[metric_name] = parser(report)
            except ReportParseError as exc:
                findings.append(str(exc))
        bound_parameters = implementation_parameters.get(name, {})
        normalized_parameters = {}
        for parameter, geometry_field in SYNTHESIS_PARAMETER_FIELDS.items():
            values = bound_parameters.get(parameter, set())
            expected_value = geometry[geometry_field]
            if values != {expected_value}:
                findings.append(
                    f"Vivado implementation {name}: {parameter} bindings="
                    f"{sorted(values)}, expected [{expected_value}]"
                )
            normalized_parameters[parameter] = (
                next(iter(values)) if len(values) == 1 else sorted(values)
            )
        evidence["implementation"].append(
            {
                "config_id": name,
                "geometry": geometry,
                "bound_parameters": normalized_parameters,
                "reports": artifacts,
                "metrics": metrics,
                "activity_source": (
                    f"build/vivado/reports/activity/{name}.saif"
                ),
            }
        )

    evidence_artifacts = evidence["artifacts"]
    assert isinstance(evidence_artifacts, dict)
    for rel_path in REQUIRED_EVIDENCE_ARTIFACTS:
        artifact = local_root / rel_path
        if not artifact.is_file():
            findings.append(f"missing Vivado evidence artifact: {artifact}")
            continue
        evidence_artifacts[rel_path] = {
            "path": rel_path,
            "sha256": sha256(artifact),
        }
    return findings, evidence


def write_evidence_manifest(
    local_root: Path,
    args: argparse.Namespace,
    evidence: dict[str, object],
    findings: list[str],
    execution: dict[str, object],
) -> Path:
    version_text = (local_root / "vivado.log").read_text(
        encoding="utf-8", errors="replace"
    ) if (local_root / "vivado.log").is_file() else ""
    version_match = re.search(r"Vivado v([^\s]+)", version_text)
    xdc_text = (local_root / "constraints" / "l1d_baseline.xdc").read_text(
        encoding="utf-8", errors="replace"
    )
    period_match = re.search(
        r"create_clock[^\n]*\s-period\s+([0-9.]+)", xdc_text
    )
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=local_root, check=True,
        text=True, stdout=subprocess.PIPE,
    ).stdout.strip()
    dirty = bool(subprocess.run(
        ["git", "status", "--porcelain"], cwd=local_root, check=True,
        text=True, stdout=subprocess.PIPE,
    ).stdout.strip())
    inputs = {}
    for rel_path in DEFAULT_UPLOADS + ["scripts/run_remote_vivado.py"]:
        path = local_root / rel_path
        inputs[rel_path] = sha256(path)
    manifest = {
        "schema": "l1d-vivado-evidence-v3",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "status": "PASS" if not findings else "FAIL",
        "findings": findings,
        "tool": {
            "vivado_version": version_match.group(1) if version_match else None,
            "launcher": args.vivado,
            "part": args.part_env or "xc7a35tcpg236-1",
            "clock_period_ns": float(period_match.group(1)) if period_match else None,
        },
        "repository": {"commit": commit, "dirty": dirty},
        "inputs": inputs,
        "execution": execution,
        **evidence,
    }
    output = local_root / "build" / "vivado" / "evidence_manifest.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(temporary, output)
    print(f"wrote Vivado evidence manifest: {output}", flush=True)
    return output


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
    command = ""
    remote_exit_status = 1
    download_failures: list[str] = []
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
        remote_exit_status = run_remote(ssh, command)
        status = remote_exit_status
        print(f"remote Vivado exit status: {remote_exit_status}", flush=True)

        for rel_path in downloads:
            remote_path = posixpath.join(remote_root, rel_path.replace("\\", "/"))
            local_path = local_root / rel_path
            clear_local_download(local_path)
            try:
                download_path(sftp, remote_path, local_path)
            except OSError as exc:
                failure_kind = (
                    "missing" if isinstance(exc, FileNotFoundError) else "failed"
                )
                print(
                    f"{failure_kind} remote download path: {rel_path} "
                    f"({type(exc).__name__})",
                    flush=True,
                )
                clear_local_download(local_path)
                download_failures.append(rel_path)
                status = status or 1
    finally:
        sftp.close()
        ssh.close()

    execution, findings = execution_evidence(
        command,
        remote_exit_status,
        download_failures,
        log_scan_skipped=args.skip_log_scan and not args.probe_only,
    )
    evidence: dict[str, object] = {
        "simulations": [],
        "synthesis": [],
        "implementation": [],
        "artifacts": {},
    }
    if not args.probe_only:
        matrix_findings, evidence = validate_report_matrix(local_root)
        findings.extend(matrix_findings)
    if not args.skip_log_scan:
        scan_status, scan_findings = scan_logs(local_root, downloads)
        status = status or scan_status
        findings.extend(scan_findings)
    if not args.probe_only:
        write_evidence_manifest(local_root, args, evidence, findings, execution)
        status = status or (1 if findings else 0)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
