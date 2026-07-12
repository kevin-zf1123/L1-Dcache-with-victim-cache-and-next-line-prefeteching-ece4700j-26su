#!/usr/bin/env python3
"""Capture attributable per-command SPEC memory windows under QEMU system mode.

Each timed command is run twice from a fresh ``-snapshot`` VM: a count-only
pass determines the complete ROI event count, then a capture pass selects five
10k-event windows (5k warmup + 5k measure) at q=10/30/50/70/90.  ROIs shorter
than 50k events are captured whole.  Every licensed artifact is forced beneath
the ignored ``build/`` tree.

The helper fails closed.  It never publishes traces and never accepts a QEMU
plugin summary that is incomplete, unattributed, or internally inconsistent.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import posixpath
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    from .split_qemu_memtrace_windows import (
        TraceFormatError,
        parse_key_values,
        sha256,
        split_v2_trace,
        write_markdown_manifest,
    )
except ImportError:  # Direct execution puts scripts/ itself on sys.path.
    from split_qemu_memtrace_windows import (
        TraceFormatError,
        parse_key_values,
        sha256,
        split_v2_trace,
        write_markdown_manifest,
    )


QEMU_VERSION_PREFIX = "QEMU emulator version 11.0.1"
GUEST_TOOLS = "/tmp/l1d-trace-tools"
SPEC_COMMAND_OPTIONS_WITH_VALUE = {"-i", "-o", "-e"}
SPEC_DIRECTIVE_ARITY = {"-E": 2, "-r": 0, "-N": 1, "-C": 1}
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
HOST_INPUT_PATHS = (
    "scripts/capture_spec_qemu_windows.py",
    "scripts/split_qemu_memtrace_windows.py",
    "scripts/qemu_memtrace.c",
    "scripts/qemu_memtrace_policy.h",
    "scripts/qemu_memtrace_canonical.h",
    "scripts/build_qemu_memtrace_plugin.sh",
    "scripts/start_qemu_trace_vm.sh",
    "scripts/trace_roi/roi_abi.h",
    "scripts/trace_roi/libl1d_roi.c",
    "scripts/trace_roi/trace_exec.c",
    "scripts/trace_roi/build_guest_tools.sh",
)
DETERMINISTIC_SUMMARY_FIELDS = (
    "total_events",
    "misaligned_events",
    "cross_line_events",
    "expanded_replay_accesses",
    "canonical_replay_accesses",
)


class CaptureError(RuntimeError):
    """A pass cannot be trusted and must not be replayed."""


@dataclass(frozen=True)
class SpecCommand:
    index: int
    raw: str
    tokens: tuple[str, ...]
    executable_index: int
    working_directory: str | None
    directives: tuple[str, ...]

    @property
    def executable(self) -> str:
        return self.tokens[self.executable_index]


@dataclass(frozen=True)
class WindowSpec:
    index: int
    start: int
    count: int
    warmup: int
    measure: int
    label: str
    quantile: float | None

    def plugin_text(self) -> str:
        return f"{self.start}:{self.count}:{self.warmup}:{self.measure}:{self.label}"


@dataclass(frozen=True)
class CompareCommand:
    index: int
    raw: str
    actual_output: str

    @property
    def sha256(self) -> str:
        return hashlib.sha256((self.raw + "\n").encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class ComparePlan:
    source_text: str
    directives: tuple[str, ...]
    working_directory: str
    commands: tuple[CompareCommand, ...]

    def selected_commands(self, actual_outputs: set[str]) -> tuple[CompareCommand, ...]:
        selected = tuple(
            command for command in self.commands if command.actual_output in actual_outputs
        )
        if not selected:
            raise CaptureError("timed command produced no output named by compare.cmd")
        return selected

    def select(self, actual_outputs: set[str]) -> str:
        selected = self.selected_commands(actual_outputs)
        if len(selected) == len(self.commands):
            return self.source_text
        return "\n".join((*self.directives, *(command.raw for command in selected))) + "\n"

    @staticmethod
    def command_record(command: CompareCommand) -> dict[str, Any]:
        return {
            "index": command.index,
            "sha256": command.sha256,
            "actual_output": command.actual_output,
        }

    def evidence(self, actual_outputs: set[str]) -> dict[str, Any]:
        selected = self.selected_commands(actual_outputs)
        text = self.select(actual_outputs)
        return {
            "text": text,
            "sha256": compare_cmd_sha(text),
            "full_plan": {
                "text": self.source_text,
                "sha256": compare_cmd_sha(self.source_text),
                "working_directory": self.working_directory,
                "commands": [self.command_record(command) for command in self.commands],
            },
            "selected_commands": [self.command_record(command) for command in selected],
        }


def run(
    command: list[str],
    *,
    cwd: Path,
    check: bool = True,
    timeout_s: int | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        check=check,
        timeout=timeout_s,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def ssh_options(repo: Path, port: int) -> list[str]:
    return [
        "-p",
        str(port),
        "-o",
        f"UserKnownHostsFile={repo / 'debian-rv64' / 'ssh_known_hosts'}",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=5",
        "-o",
        "ConnectionAttempts=1",
    ]


def ssh(
    repo: Path,
    command: str,
    *,
    port: int,
    check: bool = True,
    timeout_s: int | None = None,
) -> subprocess.CompletedProcess[str]:
    return run(
        ["ssh", *ssh_options(repo, port), "debian@127.0.0.1", command],
        cwd=repo,
        check=check,
        timeout_s=timeout_s,
    )


def scp_to_guest(repo: Path, source: Path, destination: str, *, port: int) -> None:
    options = ssh_options(repo, port)
    # scp spells the port option with uppercase P.
    options[0] = "-P"
    run(
        ["scp", *options, str(source), f"debian@127.0.0.1:{destination}"],
        cwd=repo,
        timeout_s=120,
    )


def scp_from_guest(repo: Path, source: str, destination: Path, *, port: int) -> None:
    options = ssh_options(repo, port)
    options[0] = "-P"
    run(
        ["scp", *options, f"debian@127.0.0.1:{source}", str(destination)],
        cwd=repo,
        timeout_s=120,
    )


def wait_for_ssh(repo: Path, qemu: subprocess.Popen[bytes], timeout_s: int, *, port: int) -> None:
    deadline = time.monotonic() + timeout_s
    last_output = ""
    while time.monotonic() < deadline:
        if qemu.poll() is not None:
            raise CaptureError(f"QEMU exited before SSH became ready (rc={qemu.returncode})")
        try:
            result = ssh(repo, "true", port=port, check=False, timeout_s=10)
        except subprocess.TimeoutExpired:
            last_output = "SSH probe timed out"
            time.sleep(3)
            continue
        if result.returncode == 0:
            return
        last_output = result.stdout.strip()
        time.sleep(3)
    raise CaptureError(f"timed out waiting for VM SSH; last output: {last_output}")


def validate_private_output(repo: Path, out_dir: Path) -> None:
    build_dir = (repo / "build").resolve()
    resolved = out_dir.resolve()
    if not resolved.is_relative_to(build_dir):
        raise CaptureError(
            f"licensed capture output must stay below ignored {build_dir}; got {resolved}"
        )


def parse_speccmds(text: str) -> list[SpecCommand]:
    commands: list[SpecCommand] = []
    directives: list[str] = []
    working_directory: str | None = None
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        try:
            tokens = shlex.split(raw_line, posix=True)
        except ValueError as error:
            raise CaptureError(f"speccmds line {line_number}: {error}") from error
        if not tokens:
            continue

        directive_arity = SPEC_DIRECTIVE_ARITY.get(tokens[0])
        if directive_arity is not None:
            if len(tokens) != directive_arity + 1:
                raise CaptureError(
                    f"speccmds line {line_number}: directive {tokens[0]!r} expects "
                    f"{directive_arity} value(s)"
                )
            directives.append(raw_line)
            if tokens[0] == "-C":
                working_directory = tokens[1]
            continue

        position = 0
        while position < len(tokens) and tokens[position].startswith("-"):
            option = tokens[position]
            if option == "--":
                position += 1
                break
            if option not in SPEC_COMMAND_OPTIONS_WITH_VALUE:
                raise CaptureError(
                    f"speccmds line {line_number}: unsupported specinvoke option {option!r}"
                )
            if position + 1 >= len(tokens):
                raise CaptureError(
                    f"speccmds line {line_number}: option {option!r} lacks a value"
                )
            position += 2

        if position >= len(tokens):
            raise CaptureError(f"speccmds line {line_number}: missing executable")
        commands.append(
            SpecCommand(
                index=len(commands),
                raw=raw_line,
                tokens=tuple(tokens),
                executable_index=position,
                working_directory=working_directory,
                directives=tuple(directives),
            )
        )
    if not commands:
        raise CaptureError("speccmds.cmd contains no timed commands")
    return commands


def parse_compare_cmd(text: str, *, run_dir: str) -> ComparePlan:
    """Parse SPEC's compare plan and identify each actual output fail-closed."""

    directives: list[str] = []
    commands: list[CompareCommand] = []
    working_directory: str | None = None
    seen_outputs: set[str] = set()
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        try:
            tokens = shlex.split(raw_line, posix=True)
        except ValueError as error:
            raise CaptureError(f"compare.cmd line {line_number}: {error}") from error
        if not tokens:
            continue

        directive_arity = SPEC_DIRECTIVE_ARITY.get(tokens[0])
        if directive_arity is not None:
            if len(tokens) != directive_arity + 1:
                raise CaptureError(
                    f"compare.cmd line {line_number}: directive {tokens[0]!r} expects "
                    f"{directive_arity} value(s)"
                )
            directives.append(raw_line)
            if tokens[0] == "-C":
                if working_directory is not None:
                    raise CaptureError("compare.cmd contains more than one -C directive")
                working_directory = tokens[1]
            continue

        redirects = [
            index
            for index, token in enumerate(tokens)
            if token in {">", ">>", "1>", "1>>"}
        ]
        if len(redirects) != 1 or redirects[0] < 1:
            raise CaptureError(
                f"compare.cmd line {line_number}: cannot identify actual output before redirect"
            )
        actual_token = tokens[redirects[0] - 1]
        if not actual_token or actual_token.startswith("-"):
            raise CaptureError(
                f"compare.cmd line {line_number}: malformed actual output {actual_token!r}"
            )
        commands.append(
            CompareCommand(
                index=len(commands), raw=raw_line, actual_output=actual_token
            )
        )

    if not commands:
        raise CaptureError("compare.cmd contains no comparison commands")
    if working_directory is None:
        raise CaptureError("compare.cmd lacks a -C working-directory directive")
    normalized_run_dir = posixpath.normpath(run_dir)
    normalized_working_directory = posixpath.normpath(working_directory)
    if normalized_working_directory != normalized_run_dir:
        raise CaptureError(
            "compare.cmd working directory does not match the discovered run directory"
        )
    normalized_commands: list[CompareCommand] = []
    for command in commands:
        actual = command.actual_output
        absolute = posixpath.normpath(
            actual if posixpath.isabs(actual) else posixpath.join(normalized_run_dir, actual)
        )
        if absolute == normalized_run_dir or not absolute.startswith(normalized_run_dir + "/"):
            raise CaptureError(f"compare output escapes run directory: {actual!r}")
        if absolute in seen_outputs:
            raise CaptureError(f"compare output is referenced more than once: {actual!r}")
        seen_outputs.add(absolute)
        normalized_commands.append(
            CompareCommand(
                index=command.index, raw=command.raw, actual_output=absolute
            )
        )
    return ComparePlan(
        source_text=text,
        directives=tuple(directives),
        working_directory=normalized_working_directory,
        commands=tuple(normalized_commands),
    )


def reset_compare_outputs(repo: Path, plan: ComparePlan, *, port: int) -> None:
    outputs = " ".join(shlex.quote(command.actual_output) for command in plan.commands)
    result = ssh(repo, f"rm -f -- {outputs}", port=port, check=False, timeout_s=60)
    if result.returncode != 0:
        raise CaptureError(f"cannot clear declared compare outputs: {result.stdout.strip()}")


def produced_compare_outputs(repo: Path, plan: ComparePlan, *, port: int) -> set[str]:
    probes = "; ".join(
        f"if [ -f {shlex.quote(command.actual_output)} ]; then printf '%s\\n' {index}; fi"
        for index, command in enumerate(plan.commands)
    )
    result = ssh(repo, probes, port=port, check=False, timeout_s=60)
    if result.returncode != 0:
        raise CaptureError(f"cannot inventory produced compare outputs: {result.stdout.strip()}")
    produced: set[str] = set()
    for line in result.stdout.splitlines():
        try:
            index = int(line, 10)
        except ValueError as error:
            raise CaptureError(f"malformed compare-output inventory: {line!r}") from error
        if index < 0 or index >= len(plan.commands):
            raise CaptureError(f"compare-output inventory index is out of range: {index}")
        produced.add(plan.commands[index].actual_output)
    return produced


def wrap_speccmd(command: SpecCommand, *, nonce: int, shim: str, trace_exec: str) -> str:
    wrapper = [
        trace_exec,
        "--shim",
        shim,
        "--nonce",
        f"0x{nonce:016x}",
        "--command-index",
        str(command.index),
        "--",
    ]
    executable_pattern = re.compile(
        rf"(?<!\S){re.escape(command.executable)}(?=\s|$)"
    )
    matches = list(executable_pattern.finditer(command.raw))
    if len(matches) != 1:
        raise CaptureError(
            f"cannot locate one unquoted executable token in command {command.index}"
        )
    offset = matches[0].start()
    wrapped_command = command.raw[:offset] + shlex.join(wrapper) + " " + command.raw[offset:]
    return "\n".join((*command.directives, wrapped_command)) + "\n"


def compute_windows(total_events: int) -> list[WindowSpec]:
    if total_events <= 0:
        raise CaptureError("ROI contains no supported memory events")
    if total_events < 50_000:
        return [WindowSpec(0, 0, total_events, 0, total_events, "whole", None)]

    windows: list[WindowSpec] = []
    for index, percentile in enumerate((10, 30, 50, 70, 90)):
        center = (total_events * percentile) // 100
        start = center - 5_000
        windows.append(
            WindowSpec(index, start, 10_000, 5_000, 5_000, f"q{percentile}", percentile / 100)
        )
    for previous, current in zip(windows, windows[1:]):
        if previous.start + previous.count > current.start:
            raise CaptureError("computed quantile windows overlap")
    if windows[0].start < 0 or windows[-1].start + windows[-1].count > total_events:
        raise CaptureError("computed quantile window exceeds the ROI")
    return windows


def parse_trace_metadata(path: Path, *, expected_mode: str) -> dict[str, Any]:
    named: dict[str, list[dict[str, str]]] = {
        "context": [],
        "registers": [],
        "roi_start": [],
        "roi_stop": [],
        "summary": [],
        "violation": [],
    }
    payload_count = 0
    schema_seen = False
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped == "# L1D_QEMU_MEMTRACE schema=3":
                schema_seen = True
            if stripped and not stripped.startswith("#"):
                payload_count += 1
                continue
            for key in named:
                prefix = f"# {key} "
                if line.startswith(prefix):
                    named[key].append(parse_key_values(line[len(prefix) :]))
                    break
    if not schema_seen:
        raise CaptureError(f"{path}: missing schema-v3 header")
    for key in ("context", "registers", "roi_start", "roi_stop", "summary"):
        if len(named[key]) != 1:
            raise CaptureError(f"{path}: expected exactly one {key}, got {len(named[key])}")
    summary = named["summary"][0]
    context = named["context"][0]
    registers = named["registers"][0]
    roi_start = named["roi_start"][0]
    roi_stop = named["roi_stop"][0]
    if summary.get("status") != "PASS" or summary.get("mode") != expected_mode:
        raise CaptureError(
            f"{path}: plugin summary is {summary.get('status')}/{summary.get('mode')}, "
            f"first violation={summary.get('first_violation')}"
        )
    if summary.get("start_seen") != "1" or summary.get("stop_seen") != "1":
        raise CaptureError(f"{path}: ROI marker pair is incomplete")
    if context.get("mode") != expected_mode or registers.get("status") != "PASS":
        raise CaptureError(f"{path}: context/register audit is not PASS/{expected_mode}")
    try:
        if int(context["expected_nonce"], 0) != int(roi_start["nonce"], 0):
            raise CaptureError(f"{path}: context/start nonce mismatch")
        if int(context["command"], 0) != int(roi_start["command"], 0):
            raise CaptureError(f"{path}: context/start command mismatch")
        for field in ("nonce", "command", "vcpu", "priv", "satp", "pid", "tid"):
            expected = int(roi_start[field], 0)
            if int(roi_stop[field], 0) != expected or int(summary[field], 0) != expected:
                raise CaptureError(f"{path}: ROI identity field {field} is inconsistent")
        if int(roi_stop["total_events"], 0) != int(summary["total_events"], 0):
            raise CaptureError(f"{path}: stop/summary total_events mismatch")
    except (KeyError, ValueError) as error:
        raise CaptureError(f"{path}: malformed ROI identity chain: {error}") from error
    if int(summary.get("violations", "-1"), 0) != 0 or named["violation"]:
        raise CaptureError(f"{path}: plugin reported a violation")
    if expected_mode == "count" and payload_count != 0:
        raise CaptureError(f"{path}: count pass unexpectedly contains payload")
    if expected_mode == "capture" and int(summary["captured_rows"], 0) != payload_count:
        raise CaptureError(f"{path}: captured_rows does not match payload")
    total_events = int(summary["total_events"], 0)
    misaligned_events = int(summary["misaligned_events"], 0)
    cross_line_events = int(summary["cross_line_events"], 0)
    expanded_accesses = int(summary["expanded_replay_accesses"], 0)
    canonical_accesses = int(summary["canonical_replay_accesses"], 0)
    if (
        cross_line_events > misaligned_events
        or expanded_accesses != cross_line_events
        or canonical_accesses != total_events + expanded_accesses
    ):
        raise CaptureError(f"{path}: canonicalization counters do not conserve")
    return {
        "schema": "l1d-qemu-memtrace-metadata-v3",
        "context": named["context"][0],
        "registers": named["registers"][0],
        "roi_start": named["roi_start"][0],
        "roi_stop": named["roi_stop"][0],
        "summary": summary,
        "payload_lines": payload_count,
    }


def find_run_dir(repo: Path, bench: str, size: str, label: str, *, port: int) -> str:
    for value, name in ((bench, "benchmark"), (size, "size"), (label, "label")):
        if not SAFE_NAME_RE.fullmatch(value):
            raise CaptureError(f"unsafe {name}: {value!r}")
    command = (
        "set -eu; cd /home/debian/spec2026; "
        f"find benchspec/CPU/{shlex.quote(bench)}/run -maxdepth 1 -type d "
        f"-name {shlex.quote(f'run_base_{size}_{label}*')} | sort | tail -1"
    )
    result = ssh(repo, command, port=port)
    relative = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    if not relative:
        raise CaptureError(
            f"no run directory for {bench}; run runcpu --action=runsetup first"
        )
    return f"/home/debian/spec2026/{relative}"


def read_guest_file(repo: Path, path: str, *, port: int, required: bool = True) -> str | None:
    probe = ssh(
        repo,
        f"if [ -f {shlex.quote(path)} ]; then base64 -w 0 {shlex.quote(path)}; "
        "else exit 44; fi",
        port=port,
        check=False,
        timeout_s=60,
    )
    if probe.returncode == 44 and not required:
        return None
    if probe.returncode != 0:
        raise CaptureError(f"cannot read guest file {path}: {probe.stdout.strip()}")
    import base64

    return base64.b64decode(probe.stdout).decode("utf-8")


def guest_tools_source_hash(repo: Path) -> str:
    digest = hashlib.sha256()
    source_dir = repo / "scripts" / "trace_roi"
    for name in ("roi_abi.h", "libl1d_roi.c", "trace_exec.c", "build_guest_tools.sh"):
        digest.update(name.encode("utf-8") + b"\0")
        digest.update((source_dir / name).read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def _valid_guest_tool_cache(cache_dir: Path, source_hash: str) -> bool:
    manifest_path = cache_dir / "cache_manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    if manifest.get("source_sha256") != source_hash:
        return False
    if manifest.get("execution_policy") != {
        "address_space_randomization": "disabled-fail-closed"
    }:
        return False
    for name in ("libl1d_roi.so", "trace_exec"):
        path = cache_dir / name
        if not path.is_file() or manifest.get("binaries", {}).get(name) != sha256(path):
            return False
    return True


def guest_tool_context(cache_dir: Path) -> dict[str, Any]:
    manifest = json.loads((cache_dir / "cache_manifest.json").read_text(encoding="utf-8"))
    if not _valid_guest_tool_cache(cache_dir, manifest["source_sha256"]):
        raise CaptureError("guest ROI tool cache failed its hash audit")
    return manifest


def prepare_guest_tools(repo: Path, cache_dir: Path, *, port: int) -> dict[str, Any]:
    cache_dir.mkdir(parents=True, exist_ok=True)
    cached_shim = cache_dir / "libl1d_roi.so"
    cached_exec = cache_dir / "trace_exec"
    source_hash = guest_tools_source_hash(repo)
    ssh(repo, f"rm -rf {GUEST_TOOLS}; mkdir -p {GUEST_TOOLS}", port=port)

    if not _valid_guest_tool_cache(cache_dir, source_hash):
        for stale in (cached_shim, cached_exec, cache_dir / "cache_manifest.json"):
            stale.unlink(missing_ok=True)
        source_dir = repo / "scripts" / "trace_roi"
        remote_source = "/tmp/l1d-trace-source"
        ssh(repo, f"rm -rf {remote_source}; mkdir -p {remote_source}", port=port)
        for name in ("roi_abi.h", "libl1d_roi.c", "trace_exec.c", "build_guest_tools.sh"):
            scp_to_guest(repo, source_dir / name, f"{remote_source}/{name}", port=port)
        result = ssh(
            repo,
            f"chmod +x {remote_source}/build_guest_tools.sh; "
            f"{remote_source}/build_guest_tools.sh {GUEST_TOOLS}",
            port=port,
            check=False,
            timeout_s=180,
        )
        if result.returncode != 0:
            raise CaptureError(f"guest ROI tool build failed:\n{result.stdout}")
        scp_from_guest(repo, f"{GUEST_TOOLS}/libl1d_roi.so", cached_shim, port=port)
        scp_from_guest(repo, f"{GUEST_TOOLS}/trace_exec", cached_exec, port=port)
        cache_manifest = {
            "schema": "l1d-trace-roi-guest-tools-v1",
            "source_sha256": source_hash,
            "execution_policy": {
                "address_space_randomization": "disabled-fail-closed"
            },
            "binaries": {
                "libl1d_roi.so": sha256(cached_shim),
                "trace_exec": sha256(cached_exec),
            },
        }
        (cache_dir / "cache_manifest.json").write_text(
            json.dumps(cache_manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    else:
        scp_to_guest(repo, cached_shim, f"{GUEST_TOOLS}/libl1d_roi.so", port=port)
        scp_to_guest(repo, cached_exec, f"{GUEST_TOOLS}/trace_exec", port=port)

    validation = ssh(
        repo,
        f"chmod 755 {GUEST_TOOLS}/trace_exec; chmod 644 {GUEST_TOOLS}/libl1d_roi.so; "
        f"file {GUEST_TOOLS}/trace_exec {GUEST_TOOLS}/libl1d_roi.so",
        port=port,
    )
    if "RISC-V" not in validation.stdout or "shared object" not in validation.stdout:
        raise CaptureError(f"guest ROI tools have the wrong format:\n{validation.stdout}")
    return guest_tool_context(cache_dir)


def inspect_guest_executable(
    repo: Path, run_dir: str, command: SpecCommand, *, port: int
) -> dict[str, str]:
    pieces = [f"cd {shlex.quote(run_dir)}"]
    if command.working_directory is not None:
        pieces.append(f"cd {shlex.quote(command.working_directory)}")
    executable = shlex.quote(command.executable)
    pieces.extend(
        [
            f"target=$(readlink -f -- {executable})",
            'test -f "$target" && test -x "$target"',
            'readelf -l "$target" | grep -q "Requesting program interpreter"',
            'printf "path=%s\\n" "$target"',
            'printf "sha256=%s\\n" "$(sha256sum "$target" | awk \'{print $1}\')"',
            'printf "file=%s\\n" "$(file -b "$target" | tr \' \' \'_\')"',
            'printf "kernel=%s\\n" "$(uname -srvm | tr \' \' \'_\')"',
        ]
    )
    result = ssh(repo, "set -eu; " + "; ".join(pieces), port=port, check=False)
    if result.returncode != 0:
        raise CaptureError(
            f"command {command.index} target is missing, non-executable, or static: "
            f"{command.executable}\n{result.stdout}"
        )
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    if not {"path", "sha256", "file", "kernel"}.issubset(values):
        raise CaptureError(f"incomplete executable inspection: {result.stdout}")
    return values


def stop_vm(repo: Path, qemu: subprocess.Popen[bytes], *, port: int) -> None:
    try:
        ssh(repo, "sudo poweroff", port=port, check=False, timeout_s=20)
    except (subprocess.TimeoutExpired, OSError):
        pass
    try:
        qemu.wait(timeout=120)
    except subprocess.TimeoutExpired:
        qemu.terminate()
        try:
            qemu.wait(timeout=15)
        except subprocess.TimeoutExpired:
            qemu.kill()
            qemu.wait(timeout=15)


def launch_pass(
    *,
    repo: Path,
    unit_dir: Path,
    bench: str,
    size: str,
    label: str,
    command: SpecCommand | None,
    command_index: int,
    nonce: int,
    pass_name: str,
    total_events: int | None,
    windows: list[WindowSpec],
    boot_timeout_s: int,
    run_timeout_s: int,
    port: int,
    guest_cache: Path,
) -> tuple[dict[str, Any], list[SpecCommand] | None, str, dict[str, str], dict[str, Any]]:
    raw_path = unit_dir / f"{pass_name}.raw.tsv"
    log_path = unit_dir / f"{pass_name}.qemu.log"
    spec_log_path = unit_dir / f"{pass_name}.specinvoke.log"
    compare_cmd_path = unit_dir / f"{pass_name}.compare.cmd"
    full_compare_cmd_path = unit_dir / f"{pass_name}.compare.full.cmd"
    compare_log_path = unit_dir / f"{pass_name}.compare.log"
    plugin_parts = [
        f"out={raw_path}",
        f"mode={pass_name}",
        f"nonce=0x{nonce:016x}",
        f"command={command_index}",
    ]
    if pass_name == "capture":
        if total_events is None or not windows:
            raise CaptureError("capture pass needs total_events and windows")
        plugin_parts.extend(
            [
                f"expected_total={total_events}",
                "windows=" + ";".join(window.plugin_text() for window in windows),
            ]
        )

    environment = os.environ.copy()
    environment["L1D_QEMU_PLUGIN_ARGS"] = ",".join(plugin_parts)
    environment["L1D_QEMU_SSH_PORT"] = str(port)
    with log_path.open("wb") as log:
        qemu = subprocess.Popen(
            [str(repo / "scripts" / "start_qemu_trace_vm.sh")],
            cwd=repo,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
        )

    discovered: list[SpecCommand] | None = None
    run_dir = ""
    executable_context: dict[str, str] = {}
    spec_result: subprocess.CompletedProcess[str] | None = None
    compare_result: subprocess.CompletedProcess[str] | None = None
    compare_evidence: dict[str, Any] | None = None
    compare_plan: ComparePlan | None = None
    try:
        wait_for_ssh(repo, qemu, boot_timeout_s, port=port)
        prepare_guest_tools(repo, guest_cache, port=port)
        run_dir = find_run_dir(repo, bench, size, label, port=port)
        if command is None:
            speccmd_text = read_guest_file(repo, f"{run_dir}/speccmds.cmd", port=port)
            assert speccmd_text is not None
            (unit_dir.parent / "speccmds.original.cmd").write_text(
                speccmd_text, encoding="utf-8"
            )
            discovered = parse_speccmds(speccmd_text)
            if command_index >= len(discovered):
                raise CaptureError(f"command index {command_index} does not exist")
            command = discovered[command_index]

        if command.index != command_index:
            raise CaptureError("command index mismatch")
        executable_context = inspect_guest_executable(repo, run_dir, command, port=port)
        source_compare_text = read_guest_file(repo, f"{run_dir}/compare.cmd", port=port)
        assert source_compare_text is not None
        compare_plan = parse_compare_cmd(source_compare_text, run_dir=run_dir)
        full_compare_cmd_path.write_text(source_compare_text, encoding="utf-8")
        # Every command unit starts from a fresh snapshot.  Clearing all outputs
        # declared by compare.cmd prevents runsetup leftovers from making an
        # unexecuted command appear correct, and lets us attribute side outputs
        # (not just stdout/stderr) to this one timed command.
        reset_compare_outputs(repo, compare_plan, port=port)
        wrapped = wrap_speccmd(
            command,
            nonce=nonce,
            shim=f"{GUEST_TOOLS}/libl1d_roi.so",
            trace_exec=f"{GUEST_TOOLS}/trace_exec",
        )
        local_cmd = unit_dir / f"{pass_name}.speccmds.cmd"
        remote_cmd = f"/tmp/l1d-{bench.replace('.', '_')}-c{command_index}-{pass_name}.cmd"
        local_cmd.write_text(wrapped, encoding="utf-8")
        scp_to_guest(repo, local_cmd, remote_cmd, port=port)
        guest_command = (
            "set -o pipefail; cd /home/debian/spec2026; . ./shrc; "
            f"cd {shlex.quote(run_dir)}; specinvoke -f {shlex.quote(remote_cmd)}"
        )
        spec_result = ssh(
            repo,
            guest_command,
            port=port,
            check=False,
            timeout_s=run_timeout_s,
        )
        spec_log_path.write_text(spec_result.stdout, encoding="utf-8")
        if spec_result.returncode == 0:
            # The wrapped target has returned, so the shim has emitted ROI STOP.
            # Check SPEC's own reference-output oracle before destroying this
            # snapshot.  Count and capture passes must each be correct on their
            # independently booted, read-only VM state.
            assert compare_plan is not None
            produced = produced_compare_outputs(repo, compare_plan, port=port)
            compare_evidence = compare_plan.evidence(produced)
            compare_text = str(compare_evidence["text"])
            compare_cmd_path.write_text(compare_text, encoding="utf-8")
            remote_compare_cmd = (
                f"/tmp/l1d-{bench.replace('.', '_')}-c{command_index}-{pass_name}-compare.cmd"
            )
            scp_to_guest(repo, compare_cmd_path, remote_compare_cmd, port=port)
            compare_result = ssh(
                repo,
                "set -o pipefail; cd /home/debian/spec2026; . ./shrc; "
                f"cd {shlex.quote(run_dir)}; "
                f"specinvoke -f {shlex.quote(remote_compare_cmd)}",
                port=port,
                check=False,
                timeout_s=run_timeout_s,
            )
            compare_log_path.write_text(compare_result.stdout, encoding="utf-8")
    finally:
        stop_vm(repo, qemu, port=port)

    if spec_result is None or spec_result.returncode != 0:
        rc = "not-run" if spec_result is None else str(spec_result.returncode)
        raise CaptureError(f"{bench} command {command_index} {pass_name} pass failed (rc={rc})")
    if compare_result is None or compare_result.returncode != 0:
        rc = "not-run" if compare_result is None else str(compare_result.returncode)
        raise CaptureError(
            f"{bench} command {command_index} {pass_name} compare failed (rc={rc})"
        )
    if compare_evidence is None:
        raise CaptureError(
            f"{bench} command {command_index} {pass_name} compare.cmd was not captured"
        )
    if not raw_path.is_file():
        raise CaptureError(f"QEMU plugin did not write {raw_path}")
    metadata = parse_trace_metadata(raw_path, expected_mode=pass_name)
    return metadata, discovered, run_dir, executable_context, compare_evidence


def write_metadata_files(unit_dir: Path, pass_name: str, metadata: dict[str, Any]) -> tuple[Path, Path]:
    context_path = unit_dir / f"{pass_name}.context.json"
    summary_path = unit_dir / f"{pass_name}.summary.json"
    context = {
        "schema": metadata["schema"],
        "context": metadata["context"],
        "registers": metadata["registers"],
        "roi_start": metadata["roi_start"],
        "roi_stop": metadata["roi_stop"],
    }
    context_path.write_text(json.dumps(context, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    summary_path.write_text(
        json.dumps(metadata["summary"], indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return context_path, summary_path


def artifact(path: Path, base: Path) -> dict[str, Any]:
    resolved = path.resolve()
    return {
        "path": str(resolved.relative_to(base.resolve())),
        "sha256": sha256(resolved),
    }


def command_sha(command: SpecCommand) -> str:
    serialized = "\n".join((*command.directives, command.raw)) + "\n"
    return hashlib.sha256(serialized.encode()).hexdigest()


def compare_cmd_sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def validate_comparison_evidence(
    comparison: Any, artifacts: dict[str, Any] | None = None
) -> None:
    """Validate the additive SPEC reference-output correctness evidence."""

    if not isinstance(comparison, dict):
        raise CaptureError("comparison evidence is malformed")
    text = comparison.get("text")
    digest = comparison.get("sha256")
    if not isinstance(text, str) or not text:
        raise CaptureError("comparison compare.cmd content is missing")
    if digest != compare_cmd_sha(text):
        raise CaptureError("comparison compare.cmd content hash mismatch")
    full_plan = comparison.get("full_plan")
    if not isinstance(full_plan, dict):
        raise CaptureError("comparison full compare plan is missing")
    full_text = full_plan.get("text")
    full_digest = full_plan.get("sha256")
    working_directory = full_plan.get("working_directory")
    commands = full_plan.get("commands")
    selected = comparison.get("selected_commands")
    if (
        not isinstance(full_text, str)
        or not full_text
        or full_digest != compare_cmd_sha(full_text)
        or not isinstance(working_directory, str)
        or not working_directory
        or not isinstance(commands, list)
        or not commands
        or not isinstance(selected, list)
        or not selected
    ):
        raise CaptureError("comparison full/selected plan metadata is malformed")
    expected_indices = list(range(len(commands)))
    if [item.get("index") for item in commands if isinstance(item, dict)] != expected_indices:
        raise CaptureError("comparison full-plan command indices are not dense")
    full_by_index: dict[int, dict[str, Any]] = {}
    for item in commands:
        if (
            not isinstance(item, dict)
            or not isinstance(item.get("index"), int)
            or not isinstance(item.get("sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"])
            or not isinstance(item.get("actual_output"), str)
            or not item["actual_output"]
        ):
            raise CaptureError("comparison full-plan command record is malformed")
        full_by_index[item["index"]] = item
    parsed_full = parse_compare_cmd(full_text, run_dir=working_directory)
    parsed_full_records = [
        parsed_full.command_record(command) for command in parsed_full.commands
    ]
    if parsed_full_records != commands:
        raise CaptureError("declared compare commands do not match full compare text")
    selected_indices: list[int] = []
    for item in selected:
        if not isinstance(item, dict) or item.get("index") not in full_by_index:
            raise CaptureError("selected comparison command is absent from full plan")
        index = item["index"]
        if item != full_by_index[index] or index in selected_indices:
            raise CaptureError("selected comparison command identity mismatch/duplicate")
        selected_indices.append(index)
    parsed_selected = parse_compare_cmd(text, run_dir=working_directory)
    parsed_selected_identities = [
        (command.sha256, command.actual_output) for command in parsed_selected.commands
    ]
    declared_selected_identities = [
        (item["sha256"], item["actual_output"]) for item in selected
    ]
    if parsed_selected_identities != declared_selected_identities:
        raise CaptureError("selected compare text does not match selected command identities")
    if (
        comparison.get("count_pass_status") != "PASS"
        or comparison.get("capture_pass_status") != "PASS"
    ):
        raise CaptureError("count and capture SPEC comparisons must both PASS")

    if artifacts is None:
        return
    required = (
        "count_compare_cmd",
        "count_compare_full_cmd",
        "count_compare_log",
        "capture_compare_cmd",
        "capture_compare_full_cmd",
        "capture_compare_log",
    )
    if any(name not in artifacts for name in required):
        raise CaptureError("comparison artifacts are incomplete")
    for name in ("count_compare_cmd", "capture_compare_cmd"):
        metadata = artifacts[name]
        if not isinstance(metadata, dict) or metadata.get("sha256") != digest:
            raise CaptureError(f"artifact {name} does not match compare.cmd content")
    for name in ("count_compare_full_cmd", "capture_compare_full_cmd"):
        metadata = artifacts[name]
        if not isinstance(metadata, dict) or metadata.get("sha256") != full_digest:
            raise CaptureError(f"artifact {name} does not match full compare plan")


def git_context(repo: Path) -> dict[str, Any]:
    commit = run(["git", "rev-parse", "HEAD"], cwd=repo).stdout.strip()
    dirty = bool(run(["git", "status", "--porcelain"], cwd=repo).stdout.strip())
    return {"commit": commit, "dirty": dirty}


def file_identity(path: Path) -> dict[str, Any]:
    resolved = path.resolve()
    if not resolved.is_file():
        raise CaptureError(f"provenance input not found: {resolved}")
    return {
        "path": str(resolved),
        "bytes": resolved.stat().st_size,
        "sha256": sha256(resolved),
    }


def host_input_context(repo: Path) -> dict[str, Any]:
    inputs: dict[str, Any] = {}
    aggregate = hashlib.sha256()
    for relative in HOST_INPUT_PATHS:
        path = repo / relative
        identity = file_identity(path)
        inputs[relative] = identity
        aggregate.update(relative.encode("utf-8") + b"\0")
        aggregate.update(identity["sha256"].encode("ascii") + b"\0")
    return {"sha256": aggregate.hexdigest(), "files": inputs}


def qemu_context(repo: Path) -> dict[str, Any]:
    binary = os.environ.get("L1D_QEMU_BIN") or shutil.which("qemu-system-riscv64")
    if not binary:
        raise CaptureError("qemu-system-riscv64 not found")
    binary_path = Path(binary).resolve()
    version = run([str(binary_path), "--version"], cwd=repo).stdout.splitlines()[0]
    if not version.startswith(QEMU_VERSION_PREFIX):
        raise CaptureError(f"QEMU 11.0.1 required; got {version}")
    plugin_extension = "dylib" if sys.platform == "darwin" else "so"
    plugin = Path(
        os.environ.get(
            "L1D_QEMU_PLUGIN",
            str(repo / "build" / "qemu-memtrace" / f"qemu_memtrace.{plugin_extension}"),
        )
    ).resolve()
    if not plugin.is_file():
        raise CaptureError(f"plugin not found: {plugin}; run build_qemu_memtrace_plugin.sh")
    vm_dir = Path(os.environ.get("L1D_QEMU_VM_DIR", str(repo / "debian-rv64"))).resolve()
    code_pflash = Path(
        os.environ.get(
            "L1D_QEMU_CODE_PFLASH",
            "/opt/homebrew/share/qemu/edk2-riscv-code.fd",
        )
    ).resolve()
    immutable_vm_inputs = {
        "uefi_code_pflash": file_identity(code_pflash),
        "uefi_vars": file_identity(vm_dir / "edk2-riscv-vars.fd"),
        "base_qcow2": file_identity(vm_dir / "debian-rv64.qcow2"),
        "seed_iso": file_identity(vm_dir / "seed.iso"),
    }
    return {
        "qemu_version": version,
        "plugin_api": 6,
        "target": "riscv64",
        "system_emulation": True,
        "smp_vcpus": 1,
        "qemu_executable": file_identity(binary_path),
        "plugin_sha256": sha256(plugin),
        "plugin_path": str(plugin),
        "immutable_vm_inputs": immutable_vm_inputs,
        "host_inputs": host_input_context(repo),
        "repository": git_context(repo),
    }


def build_unit_manifest(
    *,
    repo: Path,
    unit_dir: Path,
    bench: str,
    command: SpecCommand,
    size: str,
    label: str,
    nonce: int,
    toolchain: dict[str, Any],
    guest_tools: dict[str, Any],
    executable_context: dict[str, str],
    count_metadata: dict[str, Any],
    capture_metadata: dict[str, Any],
    count_compare_evidence: dict[str, Any],
    capture_compare_evidence: dict[str, Any],
    replay_windows: list[dict[str, Any]],
    count_context_path: Path,
    count_summary_path: Path,
    capture_context_path: Path,
    capture_summary_path: Path,
) -> dict[str, Any]:
    count_total = int(count_metadata["summary"]["total_events"], 0)
    capture_total = int(capture_metadata["summary"]["total_events"], 0)
    count_matches = count_total == capture_total and capture_metadata["summary"].get(
        "count_matches_capture"
    ) == "1"
    if not count_matches:
        raise CaptureError(f"count total {count_total} != capture total {capture_total}")
    deterministic_counts: dict[str, int] = {}
    for field in DETERMINISTIC_SUMMARY_FIELDS:
        count_value = int(count_metadata["summary"][field], 0)
        capture_value = int(capture_metadata["summary"][field], 0)
        if count_value != capture_value:
            raise CaptureError(
                f"count/capture deterministic field {field} differs: "
                f"{count_value} != {capture_value}"
            )
        deterministic_counts[field] = count_value
    if count_compare_evidence != capture_compare_evidence:
        raise CaptureError("full/selected compare plans changed between count and capture passes")
    comparison = dict(count_compare_evidence)
    comparison.update(
        {"count_pass_status": "PASS", "capture_pass_status": "PASS"}
    )

    manifest: dict[str, Any] = {
        "schema": "l1d-qemu-capture-manifest-v2",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "status": "PASS",
        "valid": True,
        "capture_id": f"spec2026-{bench}-cmd{command.index:03d}-{nonce:016x}",
        "benchmark": bench,
        "command_index": command.index,
        "size": size,
        "label": label,
        "command": {
            "text": command.raw,
            "sha256": command_sha(command),
            "directives": list(command.directives),
            "executable": command.executable,
            "path": executable_context["path"],
            "elf_sha256": executable_context["sha256"],
            "file": executable_context["file"],
        },
        "comparison": comparison,
        "toolchain": toolchain,
        "guest_tools": guest_tools,
        "roi": {
            "nonce": f"0x{nonce:016x}",
            "marker_magic": "0x4c3144524f490002",
            "marker_version": 2,
            "start_seen": True,
            "stop_seen": True,
            "vcpu": 0,
            "priv": 0,
            "satp": capture_metadata["summary"]["satp"],
            "pid": int(capture_metadata["summary"]["pid"], 0),
            "tid": int(capture_metadata["summary"]["tid"], 0),
            "total_events": count_total,
            "count_pass_events": count_total,
            "capture_pass_events": capture_total,
            "count_matches_capture": count_matches,
            "deterministic_counts": deterministic_counts,
            "filtered_foreign_satp_count_pass": int(
                count_metadata["summary"]["filtered_foreign_satp"], 0
            ),
            "filtered_foreign_satp_capture_pass": int(
                capture_metadata["summary"]["filtered_foreign_satp"], 0
            ),
            "misaligned_source_events_count_pass": int(
                count_metadata["summary"]["misaligned_events"], 0
            ),
            "misaligned_source_events_capture_pass": int(
                capture_metadata["summary"]["misaligned_events"], 0
            ),
            "cross_line_source_events_count_pass": int(
                count_metadata["summary"]["cross_line_events"], 0
            ),
            "cross_line_source_events_capture_pass": int(
                capture_metadata["summary"]["cross_line_events"], 0
            ),
            "expanded_replay_accesses_count_pass": int(
                count_metadata["summary"]["expanded_replay_accesses"], 0
            ),
            "expanded_replay_accesses_capture_pass": int(
                capture_metadata["summary"]["expanded_replay_accesses"], 0
            ),
            "canonical_replay_accesses_count_pass": int(
                count_metadata["summary"]["canonical_replay_accesses"], 0
            ),
            "canonical_replay_accesses_capture_pass": int(
                capture_metadata["summary"]["canonical_replay_accesses"], 0
            ),
            "violations": [],
        },
        "guest": {"kernel": executable_context["kernel"]},
        "artifacts": {
            "count_raw": artifact(unit_dir / "count.raw.tsv", unit_dir),
            "count_context": artifact(count_context_path, unit_dir),
            "count_summary": artifact(count_summary_path, unit_dir),
            "count_qemu_log": artifact(unit_dir / "count.qemu.log", unit_dir),
            "count_specinvoke_log": artifact(unit_dir / "count.specinvoke.log", unit_dir),
            "count_compare_cmd": artifact(unit_dir / "count.compare.cmd", unit_dir),
            "count_compare_full_cmd": artifact(
                unit_dir / "count.compare.full.cmd", unit_dir
            ),
            "count_compare_log": artifact(unit_dir / "count.compare.log", unit_dir),
            "raw": artifact(unit_dir / "capture.raw.tsv", unit_dir),
            "context": artifact(capture_context_path, unit_dir),
            "summary": artifact(capture_summary_path, unit_dir),
            "capture_qemu_log": artifact(unit_dir / "capture.qemu.log", unit_dir),
            "capture_specinvoke_log": artifact(
                unit_dir / "capture.specinvoke.log", unit_dir
            ),
            "capture_compare_cmd": artifact(unit_dir / "capture.compare.cmd", unit_dir),
            "capture_compare_full_cmd": artifact(
                unit_dir / "capture.compare.full.cmd", unit_dir
            ),
            "capture_compare_log": artifact(unit_dir / "capture.compare.log", unit_dir),
        },
        "windows": replay_windows,
    }
    for window in manifest["windows"]:
        replay_path = Path(window["replay"]["path"]).resolve()
        window["replay"]["path"] = str(replay_path.relative_to(unit_dir.resolve()))
    validate_comparison_evidence(manifest["comparison"], manifest["artifacts"])
    return manifest


def write_invalid_manifest(path: Path, *, bench: str, command_index: int | None, error: Exception) -> None:
    failure_artifacts: list[dict[str, Any]] = []
    if path.parent.is_dir():
        for candidate in sorted(path.parent.rglob("*")):
            if not candidate.is_file() or candidate == path or candidate.name.endswith(".tmp"):
                continue
            failure_artifacts.append(
                {
                    "path": str(candidate.relative_to(path.parent)),
                    "sha256": sha256(candidate),
                    "bytes": candidate.stat().st_size,
                }
            )
    manifest = {
        "schema": "l1d-qemu-capture-manifest-v2",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "status": "INVALID",
        "valid": False,
        "benchmark": bench,
        "command_index": command_index,
        "roi": {"count_matches_capture": False, "violations": [str(error)]},
        "failure_artifacts": failure_artifacts,
        "windows": [],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def retain_failed_unit(unit_dir: Path, final_unit_dir: Path) -> None:
    """Publish diagnostic evidence without ever retaining replayable traces."""

    if final_unit_dir.exists():
        shutil.rmtree(final_unit_dir)
    if not unit_dir.exists():
        final_unit_dir.mkdir(parents=True, exist_ok=True)
        return
    replay_dir = unit_dir / "replay"
    if replay_dir.exists():
        shutil.rmtree(replay_dir)
    for stale_manifest in (unit_dir / "manifest.json", unit_dir / "manifest.md"):
        stale_manifest.unlink(missing_ok=True)
    os.replace(unit_dir, final_unit_dir)


def invalidate_published_units(manifests: list[Path], error: Exception) -> None:
    for manifest_path in manifests:
        unit_dir = manifest_path.parent
        unit = json.loads(manifest_path.read_text(encoding="utf-8"))
        replay_dir = unit_dir / "replay"
        if replay_dir.exists():
            shutil.rmtree(replay_dir)
        manifest_path.unlink(missing_ok=True)
        (unit_dir / "manifest.md").unlink(missing_ok=True)
        write_invalid_manifest(
            manifest_path,
            bench=str(unit.get("benchmark", "unknown")),
            command_index=unit.get("command_index"),
            error=error,
        )


def write_benchmark_plan(
    bench_dir: Path,
    bench: str,
    commands: list[SpecCommand],
    manifests: list[Path],
) -> Path:
    if len(commands) != len(manifests):
        raise CaptureError(f"{bench}: captured unit count does not match speccmds")
    units: list[dict[str, Any]] = []
    common_compare_plan: dict[str, Any] | None = None
    for manifest_path in manifests:
        unit = json.loads(manifest_path.read_text(encoding="utf-8"))
        comparison = unit.get("comparison", {})
        full_plan = comparison.get("full_plan")
        if not isinstance(full_plan, dict):
            raise CaptureError(f"{bench}: unit lacks full compare plan")
        normalized_compare_plan = {
            "sha256": full_plan.get("sha256"),
            "working_directory": full_plan.get("working_directory"),
            "commands": full_plan.get("commands"),
        }
        if common_compare_plan is None:
            common_compare_plan = normalized_compare_plan
        elif normalized_compare_plan != common_compare_plan:
            raise CaptureError(f"{bench}: full compare plan differs across command units")
        units.append(
            {
                "command_index": unit["command_index"],
                "manifest": str(manifest_path.resolve().relative_to(bench_dir.resolve())),
                "sha256": sha256(manifest_path),
                "selected_compare_commands": comparison.get("selected_commands"),
            }
        )
    if common_compare_plan is None:
        raise CaptureError(f"{bench}: no compare plan was captured")

    speccmds_path = bench_dir / "speccmds.original.cmd"
    plan = {
        "schema": "l1d-qemu-benchmark-plan-v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "status": "PASS",
        "valid": True,
        "benchmark": bench,
        "command_count": len(commands),
        "speccmds": artifact(speccmds_path, bench_dir),
        "commands": [
            {"index": command.index, "sha256": command_sha(command)}
            for command in commands
        ],
        "compare_plan": common_compare_plan,
        "units": units,
    }
    final_path = bench_dir / "benchmark_plan.json"
    temporary = bench_dir / "benchmark_plan.json.tmp"
    temporary.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    try:
        validate_benchmark_plan(temporary)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    os.replace(temporary, final_path)
    return final_path


def capture_benchmark(
    *,
    repo: Path,
    out_dir: Path,
    bench: str,
    size: str,
    label: str,
    toolchain: dict[str, Any],
    boot_timeout_s: int,
    run_timeout_s: int,
    port: int,
) -> tuple[list[Path], Path]:
    bench_dir = out_dir / bench.replace(".", "_")
    if bench_dir.exists():
        shutil.rmtree(bench_dir)
    bench_dir.mkdir(parents=True, exist_ok=True)
    source_hash = guest_tools_source_hash(repo)
    guest_cache = out_dir / "guest-tools" / source_hash[:16]
    commands: list[SpecCommand] | None = None
    manifests: list[Path] = []

    command_index = 0
    while commands is None or command_index < len(commands):
        nonce = secrets.randbits(64) or 1
        final_unit_dir = bench_dir / f"cmd{command_index:03d}"
        unit_dir = bench_dir / f".cmd{command_index:03d}.{nonce:016x}.tmp"
        if final_unit_dir.exists():
            shutil.rmtree(final_unit_dir)
        for stale_temp in bench_dir.glob(f".cmd{command_index:03d}.*.tmp"):
            shutil.rmtree(stale_temp)
        unit_dir.mkdir(parents=True)
        manifest_path = unit_dir / "manifest.json"
        try:
            known_command = None if commands is None else commands[command_index]
            (
                count_metadata,
                discovered,
                _run_dir,
                executable_context,
                count_compare_evidence,
            ) = launch_pass(
                repo=repo,
                unit_dir=unit_dir,
                bench=bench,
                size=size,
                label=label,
                command=known_command,
                command_index=command_index,
                nonce=nonce,
                pass_name="count",
                total_events=None,
                windows=[],
                boot_timeout_s=boot_timeout_s,
                run_timeout_s=run_timeout_s,
                port=port,
                guest_cache=guest_cache,
            )
            if commands is None:
                assert discovered is not None
                commands = discovered
            command = commands[command_index]
            total_events = int(count_metadata["summary"]["total_events"], 0)
            windows = compute_windows(total_events)
            (
                capture_metadata,
                _unused,
                _run_dir,
                capture_executable,
                capture_compare_evidence,
            ) = launch_pass(
                repo=repo,
                unit_dir=unit_dir,
                bench=bench,
                size=size,
                label=label,
                command=command,
                command_index=command_index,
                nonce=nonce,
                pass_name="capture",
                total_events=total_events,
                windows=windows,
                boot_timeout_s=boot_timeout_s,
                run_timeout_s=run_timeout_s,
                port=port,
                guest_cache=guest_cache,
            )
            if capture_executable["sha256"] != executable_context["sha256"]:
                raise CaptureError("target ELF changed between count and capture passes")

            count_context, count_summary = write_metadata_files(unit_dir, "count", count_metadata)
            capture_context, capture_summary = write_metadata_files(
                unit_dir, "capture", capture_metadata
            )
            replay_windows = split_v2_trace(
                unit_dir / "capture.raw.tsv",
                unit_dir / "replay",
                f"spec2026_{bench.replace('.', '_')}_cmd{command_index:03d}",
            )
            manifest = build_unit_manifest(
                repo=repo,
                unit_dir=unit_dir,
                bench=bench,
                command=command,
                size=size,
                label=label,
                nonce=nonce,
                toolchain=toolchain,
                guest_tools=guest_tool_context(guest_cache),
                executable_context=executable_context,
                count_metadata=count_metadata,
                capture_metadata=capture_metadata,
                count_compare_evidence=count_compare_evidence,
                capture_compare_evidence=capture_compare_evidence,
                replay_windows=replay_windows,
                count_context_path=count_context,
                count_summary_path=count_summary,
                capture_context_path=capture_context,
                capture_summary_path=capture_summary,
            )
            manifest_path.write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            write_markdown_manifest(manifest, unit_dir / "manifest.md")
            os.replace(unit_dir, final_unit_dir)
            manifests.append(final_unit_dir / "manifest.json")
        except Exception as error:
            retain_failed_unit(unit_dir, final_unit_dir)
            invalid_path = final_unit_dir / "manifest.json"
            write_invalid_manifest(
                invalid_path,
                bench=bench,
                command_index=command_index,
                error=error,
            )
            raise
        command_index += 1
    assert commands is not None
    try:
        benchmark_plan = write_benchmark_plan(bench_dir, bench, commands, manifests)
    except Exception as error:
        invalidate_published_units(manifests, error)
        raise
    return manifests, benchmark_plan


def _resolve_below(base: Path, relative: str, *, description: str) -> Path:
    candidate = (base / relative).resolve()
    if not candidate.is_relative_to(base.resolve()):
        raise CaptureError(f"{description} escapes campaign root: {relative}")
    return candidate


def validate_benchmark_plan(path: Path) -> dict[str, Any]:
    path = path.resolve()
    root = path.parent
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CaptureError(f"cannot read benchmark plan {path}: {error}") from error
    if (
        plan.get("schema") != "l1d-qemu-benchmark-plan-v1"
        or plan.get("status") != "PASS"
        or plan.get("valid") is not True
        or not isinstance(plan.get("benchmark"), str)
    ):
        raise CaptureError(f"benchmark plan is not valid PASS evidence: {path}")
    benchmark = plan["benchmark"]
    command_count = plan.get("command_count")
    commands = plan.get("commands")
    units = plan.get("units")
    if (
        not isinstance(command_count, int)
        or command_count <= 0
        or not isinstance(commands, list)
        or len(commands) != command_count
        or not isinstance(units, list)
        or len(units) != command_count
    ):
        raise CaptureError(f"benchmark command/unit count is malformed: {path}")
    expected_indices = list(range(command_count))
    if [entry.get("index") for entry in commands if isinstance(entry, dict)] != expected_indices:
        raise CaptureError(f"benchmark command indices are not dense: {path}")

    speccmds = plan.get("speccmds")
    if not isinstance(speccmds, dict):
        raise CaptureError(f"benchmark plan lacks speccmds provenance: {path}")
    speccmds_path = _resolve_below(
        root, str(speccmds.get("path", "")), description="speccmds"
    )
    if not speccmds_path.is_file() or sha256(speccmds_path) != speccmds.get("sha256"):
        raise CaptureError(f"speccmds hash mismatch: {speccmds_path}")
    parsed_commands = parse_speccmds(speccmds_path.read_text(encoding="utf-8"))
    expected_command_records = [
        {"index": command.index, "sha256": command_sha(command)}
        for command in parsed_commands
    ]
    if expected_command_records != commands:
        raise CaptureError(f"benchmark command plan does not match speccmds: {path}")

    compare_plan = plan.get("compare_plan")
    if (
        not isinstance(compare_plan, dict)
        or not isinstance(compare_plan.get("sha256"), str)
        or not isinstance(compare_plan.get("working_directory"), str)
        or not isinstance(compare_plan.get("commands"), list)
        or not compare_plan["commands"]
    ):
        raise CaptureError(f"benchmark compare plan is malformed: {path}")
    full_compare_records = compare_plan["commands"]
    full_indices = {entry.get("index") for entry in full_compare_records if isinstance(entry, dict)}
    if full_indices != set(range(len(full_compare_records))):
        raise CaptureError(f"benchmark compare command indices are not dense: {path}")

    seen_command_indices: set[int] = set()
    selected_compare_indices: set[int] = set()
    unit_paths: list[Path] = []
    for entry in units:
        if not isinstance(entry, dict) or not isinstance(entry.get("command_index"), int):
            raise CaptureError(f"benchmark unit entry is malformed: {path}")
        command_index = entry["command_index"]
        if command_index < 0 or command_index >= command_count:
            raise CaptureError(f"benchmark command index is out of range: {command_index}")
        if command_index in seen_command_indices:
            raise CaptureError(f"duplicate benchmark command unit {command_index}: {path}")
        seen_command_indices.add(command_index)
        unit_path = _resolve_below(
            root, str(entry.get("manifest", "")), description="benchmark unit manifest"
        )
        if not unit_path.is_file() or sha256(unit_path) != entry.get("sha256"):
            raise CaptureError(f"benchmark unit manifest hash mismatch: {unit_path}")
        unit = json.loads(unit_path.read_text(encoding="utf-8"))
        if (
            unit.get("status") != "PASS"
            or unit.get("valid") is not True
            or unit.get("benchmark") != benchmark
            or unit.get("command_index") != command_index
            or unit.get("command", {}).get("sha256") != commands[command_index]["sha256"]
        ):
            raise CaptureError(f"benchmark/unit command identity mismatch: {unit_path}")
        comparison = unit.get("comparison")
        validate_comparison_evidence(comparison, unit.get("artifacts"))
        unit_compare_plan = {
            "sha256": comparison["full_plan"]["sha256"],
            "working_directory": comparison["full_plan"]["working_directory"],
            "commands": comparison["full_plan"]["commands"],
        }
        if unit_compare_plan != compare_plan:
            raise CaptureError(f"benchmark/unit full compare plan mismatch: {unit_path}")
        selected = comparison["selected_commands"]
        if entry.get("selected_compare_commands") != selected:
            raise CaptureError(f"benchmark/unit selected compare plan mismatch: {unit_path}")
        for selected_entry in selected:
            index = selected_entry["index"]
            if index in selected_compare_indices:
                raise CaptureError(
                    f"compare command {index} is assigned to more than one timed command"
                )
            selected_compare_indices.add(index)
        unit_paths.append(unit_path)

    if seen_command_indices != set(expected_indices):
        raise CaptureError(f"benchmark command-unit set is not dense: {path}")
    if selected_compare_indices != full_indices:
        raise CaptureError(
            f"benchmark selected compare subsets do not exactly cover full plan: {path}"
        )
    return {
        "benchmark": benchmark,
        "command_count": command_count,
        "unit_paths": unit_paths,
        "compare_command_count": len(full_compare_records),
    }


def validate_file_identity_metadata(value: Any, *, description: str) -> None:
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("path"), str)
        or not value["path"]
        or not isinstance(value.get("bytes"), int)
        or value["bytes"] <= 0
        or not isinstance(value.get("sha256"), str)
        or re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) is None
    ):
        raise CaptureError(f"{description} provenance is malformed")


def validate_toolchain_provenance(toolchain: Any) -> None:
    if not isinstance(toolchain, dict):
        raise CaptureError("toolchain provenance is missing")
    validate_file_identity_metadata(
        toolchain.get("qemu_executable"), description="QEMU executable"
    )
    immutable = toolchain.get("immutable_vm_inputs")
    expected_vm_inputs = {"uefi_code_pflash", "uefi_vars", "base_qcow2", "seed_iso"}
    if not isinstance(immutable, dict) or set(immutable) != expected_vm_inputs:
        raise CaptureError("immutable VM input provenance is incomplete")
    for name, metadata in immutable.items():
        validate_file_identity_metadata(metadata, description=f"VM input {name}")

    host_inputs = toolchain.get("host_inputs")
    if not isinstance(host_inputs, dict) or set(host_inputs) != {"sha256", "files"}:
        raise CaptureError("host input provenance is malformed")
    files = host_inputs.get("files")
    if not isinstance(files, dict) or set(files) != set(HOST_INPUT_PATHS):
        raise CaptureError("host input SHA map is incomplete")
    aggregate = hashlib.sha256()
    for relative in HOST_INPUT_PATHS:
        metadata = files[relative]
        validate_file_identity_metadata(metadata, description=f"host input {relative}")
        aggregate.update(relative.encode("utf-8") + b"\0")
        aggregate.update(metadata["sha256"].encode("ascii") + b"\0")
    if host_inputs.get("sha256") != aggregate.hexdigest():
        raise CaptureError("host input aggregate hash mismatch")


def validate_campaign_manifest(path: Path) -> dict[str, Any]:
    path = path.resolve()
    root = path.parent
    try:
        campaign = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CaptureError(f"cannot read campaign manifest {path}: {error}") from error
    if (
        campaign.get("schema") != "l1d-qemu-capture-campaign-v2"
        or campaign.get("status") != "PASS"
        or campaign.get("valid") is not True
    ):
        raise CaptureError("campaign is not a valid PASS v2 manifest")
    captures = campaign.get("captures")
    if not isinstance(captures, list) or not captures:
        raise CaptureError("campaign has no captures")
    requested_benchmarks = campaign.get("requested_benchmarks")
    expected_capture_units = campaign.get("expected_capture_units")
    benchmark_plan_entries = campaign.get("benchmark_plans")
    if (
        not isinstance(requested_benchmarks, list)
        or not requested_benchmarks
        or any(not isinstance(item, str) for item in requested_benchmarks)
        or len(set(requested_benchmarks)) != len(requested_benchmarks)
    ):
        raise CaptureError("campaign requested_benchmarks is malformed")
    if not isinstance(expected_capture_units, int) or expected_capture_units != len(captures):
        raise CaptureError("campaign expected_capture_units does not match captures")
    if (
        not isinstance(benchmark_plan_entries, list)
        or len(benchmark_plan_entries) != len(requested_benchmarks)
    ):
        raise CaptureError("campaign benchmark plan set is incomplete")
    campaign_toolchain = campaign.get("toolchain")
    validate_toolchain_provenance(campaign_toolchain)

    benchmark_plans: dict[str, dict[str, Any]] = {}
    planned_unit_paths: set[Path] = set()
    planned_capture_units = 0
    for entry in benchmark_plan_entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("benchmark"), str):
            raise CaptureError("campaign benchmark plan entry is malformed")
        benchmark = entry["benchmark"]
        if benchmark in benchmark_plans:
            raise CaptureError(f"duplicate benchmark plan: {benchmark}")
        plan_path = _resolve_below(
            root, str(entry.get("path", "")), description="benchmark plan"
        )
        if not plan_path.is_file() or sha256(plan_path) != entry.get("sha256"):
            raise CaptureError(f"benchmark plan hash mismatch: {plan_path}")
        validated_plan = validate_benchmark_plan(plan_path)
        if (
            validated_plan["benchmark"] != benchmark
            or entry.get("command_count") != validated_plan["command_count"]
        ):
            raise CaptureError(f"campaign/benchmark plan identity mismatch: {plan_path}")
        benchmark_plans[benchmark] = validated_plan
        planned_unit_paths.update(path.resolve() for path in validated_plan["unit_paths"])
        planned_capture_units += validated_plan["command_count"]
    if set(benchmark_plans) != set(requested_benchmarks):
        raise CaptureError("benchmark plan set does not match requested_benchmarks")
    if planned_capture_units != expected_capture_units:
        raise CaptureError("benchmark command counts do not match expected_capture_units")

    seen_units: set[tuple[str, int]] = set()
    expected_replays: set[Path] = set()
    replay_list: list[dict[str, Any]] = []
    for capture in captures:
        if not isinstance(capture, dict):
            raise CaptureError("campaign capture entry is not an object")
        unit_path = _resolve_below(root, str(capture.get("manifest", "")), description="unit manifest")
        if not unit_path.is_file() or sha256(unit_path) != capture.get("sha256"):
            raise CaptureError(f"unit manifest hash mismatch: {unit_path}")
        unit = json.loads(unit_path.read_text(encoding="utf-8"))
        if (
            unit.get("schema") != "l1d-qemu-capture-manifest-v2"
            or unit.get("status") != "PASS"
            or unit.get("valid") is not True
            or unit.get("roi", {}).get("count_matches_capture") is not True
            or unit.get("roi", {}).get("violations") != []
        ):
            raise CaptureError(f"unit manifest is not replayable: {unit_path}")
        if unit.get("toolchain") != campaign_toolchain:
            raise CaptureError(f"unit/campaign toolchain provenance mismatch: {unit_path}")
        roi = unit["roi"]
        deterministic = roi.get("deterministic_counts")
        if not isinstance(deterministic, dict) or set(deterministic) != set(
            DETERMINISTIC_SUMMARY_FIELDS
        ):
            raise CaptureError(f"unit deterministic count gate is missing: {unit_path}")
        count_field_pairs = {
            "misaligned_events": (
                "misaligned_source_events_count_pass",
                "misaligned_source_events_capture_pass",
            ),
            "cross_line_events": (
                "cross_line_source_events_count_pass",
                "cross_line_source_events_capture_pass",
            ),
            "expanded_replay_accesses": (
                "expanded_replay_accesses_count_pass",
                "expanded_replay_accesses_capture_pass",
            ),
            "canonical_replay_accesses": (
                "canonical_replay_accesses_count_pass",
                "canonical_replay_accesses_capture_pass",
            ),
        }
        for field, value in deterministic.items():
            if not isinstance(value, int) or value < 0:
                raise CaptureError(f"unit deterministic field {field} is malformed")
            if field == "total_events":
                compared = (
                    roi.get("total_events"),
                    roi.get("count_pass_events"),
                    roi.get("capture_pass_events"),
                )
            else:
                compared = tuple(roi.get(name) for name in count_field_pairs[field])
            if any(item != value for item in compared):
                raise CaptureError(f"unit deterministic field {field} is inconsistent")
        if (
            deterministic["expanded_replay_accesses"]
            != deterministic["cross_line_events"]
            or deterministic["canonical_replay_accesses"]
            != deterministic["total_events"]
            + deterministic["expanded_replay_accesses"]
        ):
            raise CaptureError(f"unit deterministic count conservation failed: {unit_path}")
        if unit.get("guest_tools", {}).get("execution_policy") != {
            "address_space_randomization": "disabled-fail-closed"
        }:
            raise CaptureError(f"unit ASLR execution policy is not bound: {unit_path}")
        for field in (
            "filtered_foreign_satp_count_pass",
            "filtered_foreign_satp_capture_pass",
        ):
            # Older local v2 fixtures predate this additive audit counter.
            value = unit["roi"].get(field, 0)
            if not isinstance(value, int) or value < 0:
                raise CaptureError(f"unit {field} is malformed: {unit_path}")
        artifacts = unit.get("artifacts")
        if not isinstance(artifacts, dict) or "raw" not in artifacts:
            raise CaptureError(f"unit has no authoritative raw artifact: {unit_path}")
        # A PASS capture is replayable only when SPEC's reference-output oracle
        # passed independently in both snapshot runs.  This intentionally makes
        # pre-gate manifests invalid under the authoritative validator.
        validate_comparison_evidence(unit.get("comparison"), artifacts)
        for name, metadata in artifacts.items():
            if not isinstance(metadata, dict):
                raise CaptureError(f"artifact {name} metadata is malformed: {unit_path}")
            artifact_path = _resolve_below(
                unit_path.parent,
                str(metadata.get("path", "")),
                description=f"artifact {name}",
            )
            if not artifact_path.is_file() or sha256(artifact_path) != metadata.get("sha256"):
                raise CaptureError(f"artifact {name} hash mismatch: {artifact_path}")
        benchmark = unit.get("benchmark")
        command_index = unit.get("command_index")
        if not isinstance(benchmark, str) or not isinstance(command_index, int):
            raise CaptureError(f"unit identity is malformed: {unit_path}")
        identity = (benchmark, command_index)
        if identity in seen_units:
            raise CaptureError(f"duplicate capture unit {identity}")
        seen_units.add(identity)
        if (
            capture.get("benchmark") != benchmark
            or capture.get("command_index") != command_index
            or capture.get("status") != "PASS"
        ):
            raise CaptureError(f"campaign/unit identity mismatch: {unit_path}")

        windows = unit.get("windows")
        if not isinstance(windows, list) or not windows:
            raise CaptureError(f"unit has no replay windows: {unit_path}")
        seen_window_indices: set[int] = set()
        for window in windows:
            if not isinstance(window, dict) or not isinstance(window.get("index"), int):
                raise CaptureError(f"malformed window in {unit_path}")
            window_index = window["index"]
            if window_index in seen_window_indices:
                raise CaptureError(f"duplicate window {window_index} in {unit_path}")
            seen_window_indices.add(window_index)
            replay = window.get("replay")
            if not isinstance(replay, dict):
                raise CaptureError(f"window {window_index} lacks replay metadata")
            kind = window.get("kind")
            warmup_events = window.get("warmup_events")
            measure_events = window.get("measure_events")
            total_events = window.get("total_events")
            # Additive canonicalization metadata defaults preserve old local
            # schema-v2 fixtures whose replay had a 1:1 source mapping.
            source_warmup_events = window.get("source_warmup_events", warmup_events)
            source_measure_events = window.get("source_measure_events", measure_events)
            source_total_events = window.get("source_total_events", total_events)
            misaligned_source_events = window.get("misaligned_source_events", 0)
            cross_line_source_events = window.get("cross_line_source_events", 0)
            expanded_replay_accesses = window.get("expanded_replay_accesses", 0)
            if (
                kind not in {"whole", "sampled"}
                or not isinstance(warmup_events, int)
                or not isinstance(measure_events, int)
                or not isinstance(total_events, int)
                or min(warmup_events, measure_events) < 0
                or total_events <= 0
                or warmup_events + measure_events != total_events
                or (kind == "whole" and warmup_events != 0)
                or not isinstance(source_warmup_events, int)
                or not isinstance(source_measure_events, int)
                or not isinstance(source_total_events, int)
                or not isinstance(misaligned_source_events, int)
                or not isinstance(cross_line_source_events, int)
                or not isinstance(expanded_replay_accesses, int)
                or min(
                    source_warmup_events,
                    source_measure_events,
                    misaligned_source_events,
                    cross_line_source_events,
                    expanded_replay_accesses,
                ) < 0
                or source_total_events <= 0
                or source_warmup_events + source_measure_events != source_total_events
                or cross_line_source_events > misaligned_source_events
                or expanded_replay_accesses != cross_line_source_events
                or total_events != source_total_events + expanded_replay_accesses
                or (kind == "whole" and source_warmup_events != 0)
            ):
                raise CaptureError(f"window {window_index} phase metadata is malformed")
            replay_path = _resolve_below(
                unit_path.parent, str(replay.get("path", "")), description="replay"
            )
            if not replay_path.is_relative_to(root):
                raise CaptureError(f"replay escapes campaign root: {replay_path}")
            if replay_path in expected_replays:
                raise CaptureError(f"replay is referenced more than once: {replay_path}")
            if not replay_path.is_file() or sha256(replay_path) != replay.get("sha256"):
                raise CaptureError(f"replay hash mismatch: {replay_path}")
            phase: str | None = None
            phase_counts = {"warmup": 0, "measure": 0}
            seen_phases: list[str] = []
            for line in replay_path.read_text(encoding="utf-8").splitlines():
                if line == "# PHASE warmup":
                    phase = "warmup"
                    seen_phases.append(phase)
                elif line == "# PHASE measure":
                    phase = "measure"
                    seen_phases.append(phase)
                elif line.strip() and not line.lstrip().startswith("#"):
                    if phase is None:
                        raise CaptureError(f"replay payload precedes phase marker: {replay_path}")
                    phase_counts[phase] += 1
            if seen_phases != ["warmup", "measure"]:
                raise CaptureError(f"replay phase markers are malformed: {replay_path}")
            actual_payload = phase_counts["warmup"] + phase_counts["measure"]
            if actual_payload != replay.get("payload_lines"):
                raise CaptureError(f"replay payload count mismatch: {replay_path}")
            if actual_payload != total_events:
                raise CaptureError(f"replay payload/phase total mismatch: {replay_path}")
            if (
                phase_counts["warmup"] != warmup_events
                or phase_counts["measure"] != measure_events
            ):
                raise CaptureError(f"replay phase counts mismatch: {replay_path}")
            expected_replays.add(replay_path)
            replay_list.append(
                {
                    "capture_manifest": str(unit_path.relative_to(root)),
                    "benchmark": benchmark,
                    "command_index": command_index,
                    "window_index": window_index,
                    "kind": kind,
                    "warmup_events": warmup_events,
                    "measure_events": measure_events,
                    "total_events": total_events,
                    "source_warmup_events": source_warmup_events,
                    "source_measure_events": source_measure_events,
                    "source_total_events": source_total_events,
                    "misaligned_source_events": misaligned_source_events,
                    "cross_line_source_events": cross_line_source_events,
                    "expanded_replay_accesses": expanded_replay_accesses,
                    "path": str(replay_path.relative_to(root)),
                    "sha256": replay["sha256"],
                    "payload_lines": replay["payload_lines"],
                }
            )

    if {identity[0] for identity in seen_units} != set(requested_benchmarks):
        raise CaptureError("captured benchmark set does not match requested_benchmarks")
    captured_unit_paths = {
        _resolve_below(root, str(capture["manifest"]), description="unit manifest")
        for capture in captures
    }
    if captured_unit_paths != planned_unit_paths:
        raise CaptureError("campaign capture units do not match benchmark command plans")

    actual_replays = {candidate.resolve() for candidate in root.rglob("*.trace")}
    extra = actual_replays - expected_replays
    missing = expected_replays - actual_replays
    if extra or missing:
        raise CaptureError(
            "campaign replay set mismatch; "
            f"extra={[str(item.relative_to(root)) for item in sorted(extra)]}, "
            f"missing={[str(item.relative_to(root)) for item in sorted(missing)]}"
        )
    replay_list.sort(key=lambda item: (item["benchmark"], item["command_index"], item["window_index"]))
    return {
        "schema": "l1d-qemu-replay-list-v2",
        "status": "PASS",
        "campaign_manifest": str(path),
        "campaign_sha256": sha256(path),
        "capture_units": len(seen_units),
        "replay_count": len(replay_list),
        "replays": replay_list,
    }


def write_campaign_manifest(
    out_dir: Path,
    unit_manifests: list[Path],
    benchmark_plan_paths: list[Path],
    requested_benchmarks: list[str],
    toolchain: dict[str, Any],
) -> Path:
    captures: list[dict[str, Any]] = []
    for path in unit_manifests:
        unit = json.loads(path.read_text(encoding="utf-8"))
        captures.append(
            {
                "benchmark": unit["benchmark"],
                "command_index": unit["command_index"],
                "manifest": str(path.resolve().relative_to(out_dir.resolve())),
                "sha256": sha256(path),
                "status": unit["status"],
            }
        )
    benchmark_plans: list[dict[str, Any]] = []
    for plan_path in benchmark_plan_paths:
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
        benchmark_plans.append(
            {
                "benchmark": plan["benchmark"],
                "command_count": plan["command_count"],
                "path": str(plan_path.resolve().relative_to(out_dir.resolve())),
                "sha256": sha256(plan_path),
            }
        )
    campaign = {
        "schema": "l1d-qemu-capture-campaign-v2",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "status": "PASS" if captures and all(item["status"] == "PASS" for item in captures) else "INVALID",
        "valid": bool(captures) and all(item["status"] == "PASS" for item in captures),
        "requested_benchmarks": requested_benchmarks,
        "expected_capture_units": len(captures),
        "toolchain": toolchain,
        "benchmark_plans": benchmark_plans,
        "captures": captures,
    }
    path = out_dir / "campaign_manifest.json"
    markdown_path = out_dir / "campaign_manifest.md"
    path.unlink(missing_ok=True)
    markdown_path.unlink(missing_ok=True)
    temporary_path = path.with_suffix(".json.tmp")
    temporary_path.write_text(
        json.dumps(campaign, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    try:
        # Validate the complete temporary evidence graph before a formal PASS
        # path is visible to any consumer.
        validate_campaign_manifest(temporary_path)
    except Exception as error:
        temporary_path.unlink(missing_ok=True)
        # No unit trace remains replayable when the top-level evidence graph
        # fails acceptance.  Raw/log diagnostics are retained and hashed.
        invalidate_published_units(unit_manifests, error)
        invalid = {
            "schema": "l1d-qemu-capture-campaign-v2",
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "status": "INVALID",
            "valid": False,
            "requested_benchmarks": requested_benchmarks,
            "expected_capture_units": len(captures),
            "violations": [str(error)],
            "captures": [],
        }
        invalid_tmp = path.with_suffix(".invalid.tmp")
        invalid_tmp.write_text(
            json.dumps(invalid, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(invalid_tmp, path)
        raise
    markdown = [
        "# Private QEMU Capture Campaign",
        "",
        f"Status: **{campaign['status']}**",
        "",
        "| benchmark | command | unit manifest | sha256 |",
        "| --- | ---: | --- | --- |",
    ]
    for capture in captures:
        markdown.append(
            f"| {capture['benchmark']} | {capture['command_index']} | "
            f"`{capture['manifest']}` | `{capture['sha256']}` |"
        )
    markdown.append("")
    temporary_markdown = markdown_path.with_suffix(".md.tmp")
    temporary_markdown.write_text("\n".join(markdown), encoding="utf-8")
    os.replace(temporary_markdown, markdown_path)
    # Publish JSON last: its presence is the authoritative acceptance point.
    os.replace(temporary_path, path)
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--out-dir", type=Path, default=Path("build/spec2026/qemu-private"))
    parser.add_argument("--size", default="test")
    parser.add_argument("--label", default="codexrv64")
    parser.add_argument("--boot-timeout-s", type=int, default=900)
    parser.add_argument("--run-timeout-s", type=int, default=21_600)
    parser.add_argument("--ssh-port", type=int, default=2222)
    parser.add_argument(
        "--validate-campaign",
        type=Path,
        help="validate a campaign and emit its authoritative replay-list JSON",
    )
    parser.add_argument(
        "--replay-list",
        type=Path,
        help="write validation output here instead of stdout",
    )
    parser.add_argument("benchmarks", nargs="*")
    args = parser.parse_args()

    repo = args.repo.resolve()
    if args.validate_campaign is not None:
        campaign_path = (
            args.validate_campaign
            if args.validate_campaign.is_absolute()
            else repo / args.validate_campaign
        )
        result = validate_campaign_manifest(campaign_path)
        encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.replay_list is None:
            print(encoded, end="")
        else:
            replay_list_path = (
                args.replay_list if args.replay_list.is_absolute() else repo / args.replay_list
            )
            replay_list_path.parent.mkdir(parents=True, exist_ok=True)
            replay_list_path.write_text(encoded, encoding="utf-8")
        return 0
    if not args.benchmarks:
        parser.error("at least one benchmark is required unless --validate-campaign is used")

    out_dir = args.out_dir if args.out_dir.is_absolute() else repo / args.out_dir
    out_dir = out_dir.resolve()
    validate_private_output(repo, out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    # A campaign is an atomic evidence set.  Preserve only source-keyed guest
    # tool caches; remove every previous unit/replay so stale files can never
    # be consumed after a partial rerun.
    for previous in out_dir.iterdir():
        if previous.name == "guest-tools":
            continue
        if previous.is_dir():
            shutil.rmtree(previous)
        else:
            previous.unlink()

    # Build before collecting toolchain hash so every unit records the exact plugin.
    build = run([str(repo / "scripts" / "build_qemu_memtrace_plugin.sh")], cwd=repo)
    print(build.stdout.strip(), flush=True)
    toolchain = qemu_context(repo)
    unit_manifests: list[Path] = []
    benchmark_plan_paths: list[Path] = []
    for bench in args.benchmarks:
        print(f"capturing {bench} command units", flush=True)
        manifests, benchmark_plan = capture_benchmark(
            repo=repo,
            out_dir=out_dir,
            bench=bench,
            size=args.size,
            label=args.label,
            toolchain=toolchain,
            boot_timeout_s=args.boot_timeout_s,
            run_timeout_s=args.run_timeout_s,
            port=args.ssh_port,
        )
        unit_manifests.extend(manifests)
        benchmark_plan_paths.append(benchmark_plan)
    campaign = write_campaign_manifest(
        out_dir,
        unit_manifests,
        benchmark_plan_paths,
        args.benchmarks,
        toolchain,
    )
    print(f"wrote authoritative private campaign manifest: {campaign}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
