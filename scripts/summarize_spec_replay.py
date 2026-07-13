#!/usr/bin/env python3
"""Strict, manifest-driven analysis for paired L1D trace replays.

The analyzer deliberately has no filename inference and no numeric defaults.
Every expected run comes from a machine-readable campaign manifest, and every
log must contain exactly one supported ``WORKLOAD_RESULT`` record.  A campaign
is accepted only when each pair key has exactly one prefetch-off and one
prefetch-on run, all counter conservation rules hold, and the trace artifacts
match their declared SHA-256 digests.

Canonical campaign manifest (paths are relative to the manifest)::

    {
      "schema": "l1d-replay-campaign-v3",
      "runs": [{
        "benchmark": "708.sqlite_r",
        "command": 0,
        "window": 0,
        "config_id": "2w_s4_vc4_pf0",
        "trace_id": "708.sqlite_r-c0-w0",
        "trace": {"path": "windows/c0-w0.trace", "sha256": "..."},
        "log": "logs/c0-w0-pf0.log",
        "sidecar": "sidecars/c0-w0-pf0.tsv",
        "sets": 4,
        "ways": 2,
        "line_bytes": 16,
        "victim_entries": 4,
        "prefetch": 0,
        "prefetch_policy": 1,
        "pf_opt_level": 3,
        "producer_profile": "zero-bubble",
        "producer_gap": 0,
        "timing_profile": "fixed-latency-10",
        "cold_warm_mode": "demand-warm-measure"
      }]
    }

Per-access sidecars are optional as a pair.  When both are present, exact L1
and lower-memory help/pollution are computed and reconciled with counter
deltas.  When neither is present, those fields are explicitly ``N/A``; a
single-sided sidecar is an error.  Campaign/result/sidecar schema 2 remains
read-compatible; schema 3 adds explicit producer/policy identity and lifecycle
conservation for prefetch returns that merge or are discarded instead of
being installed.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import shlex
import statistics
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

if __package__:
    from .render_spec_replay_plots import write_plot_outputs
else:
    from render_spec_replay_plots import write_plot_outputs


RESULT_PREFIX = "WORKLOAD_RESULT "
CAMPAIGN_SCHEMAS = {
    2,
    "2",
    3,
    "3",
    "l1d-replay-campaign-v2",
    "l1d-replay-campaign-v3",
}
RESULT_SCHEMAS = {2, 3}
NA = "N/A"
CANONICAL_PAIRED_CONFIG_IDS = {"2w_s4_vc4_pf0", "2w_s4_vc4_pf1"}
CANONICAL_STANDALONE_CONFIG_IDS = {"dm_s8_vc4_pf0", "2w_s4_vc8_pf0"}
CANONICAL_CONFIG_GEOMETRY = {
    "dm_s8_vc4_pf0": (8, 1, 16, 4, 0),
    "2w_s4_vc4_pf0": (4, 2, 16, 4, 0),
    "2w_s4_vc8_pf0": (4, 2, 16, 8, 0),
    "2w_s4_vc4_pf1": (4, 2, 16, 4, 1),
}

STRING_RESULT_FIELDS = ("config_id", "trace_id", "status")
INT_RESULT_FIELDS = (
    "schema",
    "sets",
    "ways",
    "line_bytes",
    "l1_bytes",
    "victim_entries",
    "victim_bytes",
    "total_bytes",
    "prefetch",
    "accesses",
    "hits",
    "misses",
    "victim_hits",
    "demand_mem_reads",
    "prefetch_mem_reads",
    "mem_reads",
    "mem_writes",
    "read_bytes",
    "write_bytes",
    "writebacks",
    "fills",
    "useful",
    "useless_evicted",
    "unused_resident",
    "pollution_proxy",
    "dropped",
    "timely_useful",
    "late_useful",
    "replay_service_cycles",
    "watchdogs",
    "protocol",
    "duplicate_lines",
)

V3_LIFECYCLE_COUNTER_FIELDS = (
    "pf_candidates",
    "pf_admitted",
    "pf_issued",
    "pf_returned",
    "pf_installed",
    "pf_merged",
    "pf_discarded",
    "pf_cancelled",
    "pf_unused_evicted",
    "pf_unused_resident",
    "pf_vc_bypass",
    "pf_caused_writebacks",
    "pf_demand_block_cycles",
    "pf_true_help",
    "pf_true_pollution",
    "pf_suppressed_quota",
    "pf_suppressed_unsafe",
    "pf_same_line_coalesced",
)

# parse_log normalizes schema-2 rows into the schema-3 lifecycle vocabulary so
# downstream CSV and aggregate code has one stable shape.  The derived schema-2
# values are deliberately conservative: the legacy blocking engine has no
# merge/discard path and every issued request is installed.
ALL_INT_RESULT_FIELDS = INT_RESULT_FIELDS + V3_LIFECYCLE_COUNTER_FIELDS
RAW_COUNTER_FIELDS = tuple(
    field for field in ALL_INT_RESULT_FIELDS if field != "schema"
)
PREFETCH_COUNTER_FIELDS = (
    "prefetch_mem_reads",
    "fills",
    "useful",
    "useless_evicted",
    "unused_resident",
    "pollution_proxy",
    "dropped",
    "timely_useful",
    "late_useful",
) + V3_LIFECYCLE_COUNTER_FIELDS

PAIR_KEY_FIELDS = (
    "benchmark",
    "command",
    "window",
    "sets",
    "ways",
    "line_bytes",
    "victim_entries",
    "timing_profile",
    "prefetch_policy",
    "pf_opt_level",
    "producer_profile",
    "producer_gap",
)
AGGREGATE_KEY_FIELDS = (
    "sets",
    "ways",
    "line_bytes",
    "victim_entries",
    "timing_profile",
    "cold_warm_mode",
    "prefetch_policy",
    "pf_opt_level",
    "producer_profile",
    "producer_gap",
)


class ValidationError(ValueError):
    """Raised when campaign evidence is incomplete or internally inconsistent."""


@dataclass(frozen=True)
class Artifact:
    path: Path
    sha256: str | None = None


@dataclass(frozen=True)
class ExpectedRun:
    benchmark: str
    command: str
    window: str
    config_id: str
    trace_id: str
    trace: Artifact
    log: Artifact
    sidecar: Artifact | None
    simulation_binary: Artifact
    simulator: Artifact
    simulation_command: tuple[str, ...]
    simulation_command_sha256: str
    simulation_cwd: Path
    sets: int
    ways: int
    line_bytes: int
    victim_entries: int
    prefetch: int
    timing_profile: str
    cold_warm_mode: str
    prefetch_policy: int = 0
    pf_opt_level: int = 0
    producer_profile: str = "sequential"
    producer_gap: int = 0
    capture_manifest: Path | None = None
    capture_window_index: int | None = None
    capture_window_kind: str | None = None
    warmup_events: int | None = None
    measure_events: int | None = None
    total_events: int | None = None

    @property
    def pair_key(self) -> tuple[Any, ...]:
        return tuple(getattr(self, field) for field in PAIR_KEY_FIELDS)


@dataclass(frozen=True)
class DemandAccess:
    seq: int
    cycle: int
    addr: int
    op: str
    size: int
    outcome: str

    @property
    def identity(self) -> tuple[int, int, str, int]:
        return (self.seq, self.addr, self.op, self.size)


@dataclass
class RunRecord:
    expected: ExpectedRun
    counters: dict[str, int]
    strings: dict[str, str]
    trace_features: dict[str, Any]
    accesses: list[DemandAccess] | None
    sidecar_event_counts: dict[str, int] | None


def _fail(context: str, message: str) -> None:
    raise ValidationError(f"{context}: {message}")


def _require(mapping: Mapping[str, Any], key: str, context: str) -> Any:
    if key not in mapping:
        _fail(context, f"missing required field {key!r}")
    return mapping[key]


def _string(value: Any, context: str, field: str) -> str:
    if not isinstance(value, (str, int)) or isinstance(value, bool):
        _fail(context, f"field {field!r} must be a non-empty string or integer")
    result = str(value)
    if not result:
        _fail(context, f"field {field!r} must not be empty")
    return result


def _int(value: Any, context: str, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool):
        _fail(context, f"field {field!r} must be an integer, not boolean")
    if isinstance(value, int):
        parsed = value
    elif isinstance(value, str):
        try:
            parsed = int(value, 0)
        except ValueError:
            _fail(context, f"field {field!r} is not an integer: {value!r}")
    else:
        _fail(context, f"field {field!r} must be an integer")
    if parsed < minimum:
        _fail(context, f"field {field!r} must be >= {minimum}, got {parsed}")
    return parsed


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_digest(digest: str, context: str) -> str:
    normalized = digest.lower()
    if not re.fullmatch(r"[0-9a-f]{64}", normalized):
        _fail(context, f"invalid SHA-256 digest {digest!r}")
    return normalized


def _artifact(
    value: Any,
    base_dir: Path,
    context: str,
    *,
    fallback_sha256: Any = None,
) -> Artifact:
    if isinstance(value, str):
        raw_path = value
        raw_digest = fallback_sha256
    elif isinstance(value, Mapping):
        raw_path = _require(value, "path", context)
        raw_digest = value.get("sha256", fallback_sha256)
    else:
        _fail(context, "artifact must be a path string or {path, sha256} object")
    if not isinstance(raw_path, str) or not raw_path:
        _fail(context, "artifact path must be a non-empty string")
    path = Path(raw_path)
    if not path.is_absolute():
        path = base_dir / path
    path = path.resolve()
    if not path.is_file():
        _fail(context, f"artifact does not exist: {path}")
    digest = None
    if raw_digest is not None:
        if not isinstance(raw_digest, str):
            _fail(context, "artifact sha256 must be a string")
        digest = _validate_digest(raw_digest, context)
        actual = _sha256(path)
        if actual != digest:
            _fail(context, f"SHA-256 mismatch for {path}: expected {digest}, got {actual}")
    return Artifact(path=path, sha256=digest)


def _optional_artifact(
    value: Any,
    base_dir: Path,
    context: str,
    *,
    fallback_sha256: Any = None,
) -> Artifact | None:
    if value is None:
        return None
    return _artifact(value, base_dir, context, fallback_sha256=fallback_sha256)


def _simulation_plusargs(command: Sequence[str], context: str) -> dict[str, str]:
    """Return the command's unique ``+NAME=value`` arguments."""

    plusargs: dict[str, str] = {}
    for argument in command[2:]:
        if not argument.startswith("+") or "=" not in argument:
            continue
        key, value = argument[1:].split("=", 1)
        if not key or not value:
            _fail(context, f"malformed simulation plusarg {argument!r}")
        if key in plusargs:
            _fail(context, f"duplicate simulation plusarg +{key}")
        plusargs[key] = value
    return plusargs


def _validate_command_artifact(
    raw_path: str,
    artifact: Artifact,
    simulation_cwd: Path,
    context: str,
    plusarg: str,
) -> None:
    """Resolve one simulation plusarg in its recorded cwd and bind it."""

    command_path = Path(raw_path)
    if not command_path.is_absolute():
        command_path = simulation_cwd / command_path
    if command_path.resolve() != artifact.path:
        _fail(
            context,
            f"+{plusarg} path {command_path.resolve()} does not match declared "
            f"artifact {artifact.path}",
        )


def load_campaign(path: Path) -> tuple[dict[str, Any], list[ExpectedRun]]:
    """Load and validate the expected-run portion of a campaign manifest."""

    manifest_path = path.resolve()
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError(f"manifest {manifest_path}: {exc}") from exc
    if not isinstance(data, dict):
        _fail("manifest", "top level must be an object")
    schema = _require(data, "schema", "manifest")
    if schema not in CAMPAIGN_SCHEMAS:
        _fail("manifest", f"unsupported campaign schema {schema!r}")
    campaign_v3 = schema in {3, "3", "l1d-replay-campaign-v3"}
    if data.get("status") != "PASS" or data.get("artifact_hashes") is not True:
        _fail("manifest", "campaign must declare status=PASS and artifact_hashes=true")
    top_artifacts: dict[str, Artifact] = {}
    for field in ("capture_campaign", "capture_replay_list"):
        top_artifact = _artifact(
            _require(data, field, "manifest"),
            manifest_path.parent,
            f"manifest.{field}",
        )
        if top_artifact.sha256 is None:
            _fail(f"manifest.{field}", "a SHA-256 is required")
        top_artifacts[field] = top_artifact
    try:
        capture_campaign = json.loads(
            top_artifacts["capture_campaign"].path.read_text(encoding="utf-8")
        )
        capture_replay_list = json.loads(
            top_artifacts["capture_replay_list"].path.read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError(f"manifest capture provenance: {exc}") from exc
    if (
        capture_campaign.get("schema") != "l1d-qemu-capture-campaign-v2"
        or capture_campaign.get("status") != "PASS"
        or capture_campaign.get("valid") is not True
    ):
        _fail("manifest.capture_campaign", "capture campaign is not PASS/valid schema-v2")
    requested_benchmarks = capture_campaign.get("requested_benchmarks")
    captures = capture_campaign.get("captures")
    if (
        not isinstance(requested_benchmarks, list)
        or not requested_benchmarks
        or not all(isinstance(item, str) and item for item in requested_benchmarks)
        or not isinstance(captures, list)
        or capture_campaign.get("expected_capture_units") != len(captures)
        or {item.get("benchmark") for item in captures if isinstance(item, dict)}
        != set(requested_benchmarks)
    ):
        _fail("manifest.capture_campaign", "requested benchmark/unit matrix is inconsistent")
    capture_root = top_artifacts["capture_campaign"].path.parent
    for index, capture_entry in enumerate(captures):
        context = f"manifest.capture_campaign.captures[{index}]"
        if not isinstance(capture_entry, dict) or capture_entry.get("status") != "PASS":
            _fail(context, "capture entry is not PASS")
        checked = _artifact(
            {
                "path": _require(capture_entry, "manifest", context),
                "sha256": _require(capture_entry, "sha256", context),
            },
            capture_root,
            context,
        )
        if checked.sha256 is None:
            _fail(context, "unit manifest SHA-256 is required")
    if (
        capture_replay_list.get("schema") != "l1d-qemu-replay-list-v2"
        or capture_replay_list.get("status") != "PASS"
        or capture_replay_list.get("capture_units") != len(captures)
        or capture_replay_list.get("campaign_sha256")
        != top_artifacts["capture_campaign"].sha256
    ):
        _fail("manifest.capture_replay_list", "replay list is not linked to capture campaign")
    authoritative_replays = capture_replay_list.get("replays")
    if (
        not isinstance(authoritative_replays, list)
        or capture_replay_list.get("replay_count") != len(authoritative_replays)
    ):
        _fail("manifest.capture_replay_list", "replay_count does not match replay entries")
    raw_runs = _require(data, "runs", "manifest")
    if not isinstance(raw_runs, list) or not raw_runs:
        _fail("manifest", "runs must be a non-empty array")
    expected_run_count = _int(
        _require(data, "expected_runs", "manifest"),
        "manifest",
        "expected_runs",
        minimum=1,
    )
    _int(
        _require(data, "expected_pairs", "manifest"),
        "manifest",
        "expected_pairs",
    )
    require_sidecars = _require(data, "require_sidecars", "manifest")
    if not isinstance(require_sidecars, bool):
        _fail("manifest", "require_sidecars must be boolean")
    require_capture_manifests = _require(
        data, "require_capture_manifests", "manifest"
    )
    if not isinstance(require_capture_manifests, bool):
        _fail("manifest", "require_capture_manifests must be boolean")
    if len(raw_runs) != expected_run_count:
        _fail(
            "manifest",
            f"expected_runs={expected_run_count}, but runs contains {len(raw_runs)} entries",
        )
    if "actual_runs" in data and _int(data["actual_runs"], "manifest", "actual_runs") != len(raw_runs):
        _fail("manifest", "actual_runs does not match runs length")
    policy_ids: dict[str, set[str]] = {}
    for field in ("paired_config_ids", "standalone_config_ids"):
        raw_ids = _require(data, field, "manifest")
        if (
            not isinstance(raw_ids, list)
            or (field == "paired_config_ids" and not raw_ids)
            or not all(isinstance(item, str) and item for item in raw_ids)
        ):
            _fail(
                "manifest",
                f"{field} must be a string array"
                + (" with at least one ID" if field == "paired_config_ids" else ""),
            )
        if len(set(raw_ids)) != len(raw_ids):
            _fail("manifest", f"{field} contains duplicates")
        policy_ids[field] = set(raw_ids)
    if policy_ids["paired_config_ids"] & policy_ids["standalone_config_ids"]:
        _fail("manifest", "paired and standalone config ID policies overlap")
    if require_capture_manifests and not campaign_v3 and (
        policy_ids["paired_config_ids"] != CANONICAL_PAIRED_CONFIG_IDS
        or policy_ids["standalone_config_ids"]
        != CANONICAL_STANDALONE_CONFIG_IDS
    ):
        _fail(
            "manifest",
            "capture-backed campaign must declare the canonical four-config matrix",
        )

    base_dir = manifest_path.parent
    runs: list[ExpectedRun] = []
    for index, raw in enumerate(raw_runs):
        context = f"manifest.runs[{index}]"
        if not isinstance(raw, dict):
            _fail(context, "run must be an object")

        command_value = raw.get("command", raw.get("command_index"))
        if command_value is None:
            _fail(context, "missing required field 'command' (or 'command_index')")
        if isinstance(command_value, Mapping):
            command_value = raw.get("command_index")
            if command_value is None:
                _fail(context, "object-valued command requires command_index")
        window_value = raw.get("window", raw.get("window_index"))
        if window_value is None:
            _fail(context, "missing required field 'window' (or 'window_index')")

        prefetch = _int(_require(raw, "prefetch", context), context, "prefetch")
        if prefetch not in (0, 1):
            _fail(context, f"prefetch must be 0 or 1, got {prefetch}")
        if campaign_v3:
            prefetch_policy = _int(
                _require(raw, "prefetch_policy", context),
                context,
                "prefetch_policy",
            )
            pf_opt_level = _int(
                _require(raw, "pf_opt_level", context),
                context,
                "pf_opt_level",
            )
            producer_profile = _string(
                _require(raw, "producer_profile", context),
                context,
                "producer_profile",
            )
            producer_gap = _int(
                _require(raw, "producer_gap", context),
                context,
                "producer_gap",
            )
        else:
            # These values describe the historical replay producer and legacy
            # prefetch implementation.  They are explicit in all v3 manifests.
            prefetch_policy = _int(
                raw.get("prefetch_policy", 0), context, "prefetch_policy"
            )
            pf_opt_level = _int(
                raw.get("pf_opt_level", 0), context, "pf_opt_level"
            )
            producer_profile = _string(
                raw.get("producer_profile", "sequential"),
                context,
                "producer_profile",
            )
            producer_gap = _int(
                raw.get("producer_gap", 0), context, "producer_gap"
            )
        if prefetch_policy not in (0, 1):
            _fail(context, f"prefetch_policy must be 0 or 1, got {prefetch_policy}")
        if pf_opt_level not in (0, 1, 2, 3):
            _fail(context, f"pf_opt_level must be in 0..3, got {pf_opt_level}")
        if campaign_v3 and prefetch_policy == 0 and pf_opt_level != 0:
            _fail(context, "legacy prefetch_policy=0 requires pf_opt_level=0")
        if campaign_v3 and prefetch_policy == 1 and pf_opt_level == 0:
            _fail(context, "optimized prefetch_policy=1 requires pf_opt_level in 1..3")
        if producer_profile not in {"sequential", "zero-bubble", "fixed-gap"}:
            _fail(context, f"unsupported producer_profile {producer_profile!r}")
        if producer_profile == "fixed-gap" and producer_gap not in {1, 2, 4, 8}:
            _fail(context, "fixed-gap producer_gap must be one of 1, 2, 4, 8")
        if producer_profile != "fixed-gap" and producer_gap != 0:
            _fail(context, f"{producer_profile} producer_gap must be zero")

        trace_value = _require(raw, "trace", context)
        trace = _artifact(
            trace_value,
            base_dir,
            f"{context}.trace",
            fallback_sha256=raw.get("trace_sha256"),
        )
        if trace.sha256 is None:
            _fail(f"{context}.trace", "a trace SHA-256 is required")

        log = _artifact(
            _require(raw, "log", context),
            base_dir,
            f"{context}.log",
            fallback_sha256=raw.get("log_sha256"),
        )
        if log.sha256 is None:
            _fail(f"{context}.log", "a log SHA-256 is required")
        sidecar = _optional_artifact(
            raw.get("sidecar"),
            base_dir,
            f"{context}.sidecar",
            fallback_sha256=raw.get("sidecar_sha256"),
        )
        if sidecar is not None and sidecar.sha256 is None:
            _fail(f"{context}.sidecar", "a sidecar SHA-256 is required")
        if require_sidecars and sidecar is None:
            _fail(f"{context}.sidecar", "sidecar is required by campaign policy")
        simulation_binary = _artifact(
            _require(raw, "simulation_binary", context),
            base_dir,
            f"{context}.simulation_binary",
        )
        simulator = _artifact(
            _require(raw, "simulator", context),
            base_dir,
            f"{context}.simulator",
        )
        if simulation_binary.sha256 is None or simulator.sha256 is None:
            _fail(context, "simulation binary and simulator SHA-256 values are required")
        raw_simulation_cwd = _require(raw, "simulation_cwd", context)
        if not isinstance(raw_simulation_cwd, str) or not raw_simulation_cwd:
            _fail(context, "simulation_cwd must be a non-empty absolute path")
        simulation_cwd = Path(raw_simulation_cwd)
        if not simulation_cwd.is_absolute():
            _fail(context, "simulation_cwd must be absolute")
        simulation_cwd = simulation_cwd.resolve()
        if not simulation_cwd.is_dir():
            _fail(context, f"simulation_cwd is not an existing directory: {simulation_cwd}")
        raw_command = _require(raw, "simulation_command", context)
        if (
            not isinstance(raw_command, list)
            or len(raw_command) < 2
            or not all(isinstance(item, str) and item for item in raw_command)
        ):
            _fail(
                context,
                "simulation_command must contain simulator, binary, and string arguments",
            )
        command_digest = _validate_digest(
            _string(
                _require(raw, "simulation_command_sha256", context),
                context,
                "simulation_command_sha256",
            ),
            context,
        )
        actual_command_digest = hashlib.sha256(
            json.dumps(
                raw_command, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
        ).hexdigest()
        if command_digest != actual_command_digest:
            _fail(context, "simulation command SHA-256 mismatch")
        command_simulator = Path(raw_command[0])
        command_binary = Path(raw_command[1])
        if not command_simulator.is_absolute():
            command_simulator = simulation_cwd / command_simulator
        if not command_binary.is_absolute():
            command_binary = simulation_cwd / command_binary
        if command_simulator.resolve() != simulator.path or command_binary.resolve() != simulation_binary.path:
            _fail(context, "simulation command does not reference declared simulator/binary")
        plusargs = _simulation_plusargs(raw_command, context)
        for key, expected_value in (
            ("CONFIG_ID", str(raw.get("config_id", ""))),
            ("TRACE_ID", str(raw.get("trace_id", ""))),
        ):
            actual_value = plusargs.get(key)
            if actual_value != expected_value:
                _fail(
                    context,
                    f"simulation command +{key}={actual_value!r} does not match "
                    f"manifest value {expected_value!r}",
                )
        if raw_command.count("+TRACE_SKIP_LOAD_CHECKS") != 1:
            _fail(
                context,
                "simulation command must contain +TRACE_SKIP_LOAD_CHECKS exactly once",
            )
        trace_argument = plusargs.get("TRACE")
        if trace_argument is None:
            _fail(context, "simulation command is missing +TRACE=<path>")
        _validate_command_artifact(
            trace_argument,
            trace,
            simulation_cwd,
            context,
            "TRACE",
        )
        sidecar_argument = plusargs.get("ACCESS_SIDECAR")
        if sidecar is None:
            if sidecar_argument is not None:
                _fail(
                    context,
                    "simulation command declares +ACCESS_SIDECAR without a sidecar artifact",
                )
        else:
            if sidecar_argument is None:
                _fail(context, "simulation command is missing +ACCESS_SIDECAR=<path>")
            _validate_command_artifact(
                sidecar_argument,
                sidecar,
                simulation_cwd,
                context,
                "ACCESS_SIDECAR",
            )
        if campaign_v3:
            profile_code = {
                "sequential": "0",
                "zero-bubble": "1",
                "fixed-gap": "2",
            }[producer_profile]
            expected_plusargs = {
                "PRODUCER_PROFILE": profile_code,
                "PRODUCER_GAP": str(producer_gap),
            }
            for plusarg, wanted in expected_plusargs.items():
                actual = plusargs.get(plusarg)
                if actual != wanted:
                    _fail(
                        context,
                        f"simulation command +{plusarg}={actual!r} does not match "
                        f"manifest value {wanted!r}",
                    )

        capture_path: Path | None = None
        capture_index: int | None = None
        if raw.get("capture_manifest") is not None:
            capture_artifact = _artifact(
                raw["capture_manifest"], base_dir, f"{context}.capture_manifest"
            )
            if capture_artifact.sha256 is None:
                _fail(
                    f"{context}.capture_manifest",
                    "a capture-manifest SHA-256 is required",
                )
            capture_path = capture_artifact.path
            capture_index = _int(
                _require(raw, "capture_window_index", context),
                context,
                "capture_window_index",
            )
            capture_window_kind = _string(
                _require(raw, "capture_window_kind", context),
                context,
                "capture_window_kind",
            )
            warmup_events = _int(
                _require(raw, "warmup_events", context), context, "warmup_events"
            )
            measure_events = _int(
                _require(raw, "measure_events", context),
                context,
                "measure_events",
                minimum=1,
            )
            total_events = _int(
                _require(raw, "total_events", context),
                context,
                "total_events",
                minimum=1,
            )
        else:
            if require_capture_manifests:
                _fail(
                    context,
                    "capture_manifest provenance is required for every run",
                )
            capture_window_kind = None
            warmup_events = None
            measure_events = None
            total_events = None

        run = ExpectedRun(
            benchmark=_string(_require(raw, "benchmark", context), context, "benchmark"),
            command=_string(command_value, context, "command"),
            window=_string(window_value, context, "window"),
            config_id=_string(_require(raw, "config_id", context), context, "config_id"),
            trace_id=_string(_require(raw, "trace_id", context), context, "trace_id"),
            trace=trace,
            log=log,
            sidecar=sidecar,
            simulation_binary=simulation_binary,
            simulator=simulator,
            simulation_command=tuple(raw_command),
            simulation_command_sha256=command_digest,
            simulation_cwd=simulation_cwd,
            sets=_int(_require(raw, "sets", context), context, "sets", minimum=1),
            ways=_int(_require(raw, "ways", context), context, "ways", minimum=1),
            line_bytes=_int(
                _require(raw, "line_bytes", context), context, "line_bytes", minimum=1
            ),
            victim_entries=_int(
                _require(raw, "victim_entries", context),
                context,
                "victim_entries",
                minimum=0,
            ),
            prefetch=prefetch,
            timing_profile=_string(
                _require(raw, "timing_profile", context), context, "timing_profile"
            ),
            cold_warm_mode=_string(
                _require(raw, "cold_warm_mode", context), context, "cold_warm_mode"
            ),
            prefetch_policy=prefetch_policy,
            pf_opt_level=pf_opt_level,
            producer_profile=producer_profile,
            producer_gap=producer_gap,
            capture_manifest=capture_path,
            capture_window_index=capture_index,
            capture_window_kind=capture_window_kind,
            warmup_events=warmup_events,
            measure_events=measure_events,
            total_events=total_events,
        )
        runs.append(run)

    seen: dict[tuple[Any, ...], int] = {}
    for index, run in enumerate(runs):
        unique_key = run.pair_key + (run.prefetch,)
        if unique_key in seen:
            _fail(
                "manifest",
                f"duplicate expected run for pair key {run.pair_key!r}, "
                f"prefetch={run.prefetch} at indices {seen[unique_key]} and {index}",
            )
        seen[unique_key] = index
    actual_config_ids = {run.config_id for run in runs}
    declared_config_ids = (
        policy_ids["paired_config_ids"] | policy_ids["standalone_config_ids"]
    )
    if actual_config_ids != declared_config_ids:
        _fail(
            "manifest",
            "config policy does not match run matrix: "
            f"declared={sorted(declared_config_ids)}, actual={sorted(actual_config_ids)}",
        )
    for run in runs:
        if require_capture_manifests:
            actual_geometry = (
                run.sets,
                run.ways,
                run.line_bytes,
                run.victim_entries,
                run.prefetch,
            )
            if actual_geometry != CANONICAL_CONFIG_GEOMETRY[run.config_id]:
                _fail(
                    "manifest",
                    f"config {run.config_id!r} has non-canonical geometry {actual_geometry}",
                )
        if (
            run.config_id in policy_ids["standalone_config_ids"]
            and run.prefetch != 0
        ):
            _fail("manifest", f"standalone config {run.config_id!r} must be prefetch-off")
    authoritative_keys: set[tuple[Any, ...]] = set()
    for index, replay in enumerate(authoritative_replays):
        context = f"manifest.capture_replay_list.replays[{index}]"
        if not isinstance(replay, dict):
            _fail(context, "replay entry must be an object")
        replay_path = (capture_root / str(_require(replay, "path", context))).resolve()
        capture_path = (
            capture_root / str(_require(replay, "capture_manifest", context))
        ).resolve()
        digest = _validate_digest(
            _string(_require(replay, "sha256", context), context, "sha256"),
            context,
        )
        authoritative_keys.add(
            (
                _string(_require(replay, "benchmark", context), context, "benchmark"),
                str(_int(_require(replay, "command_index", context), context, "command_index")),
                str(_int(_require(replay, "window_index", context), context, "window_index")),
                replay_path,
                digest,
                capture_path,
            )
        )
    run_replay_keys = {
        (
            run.benchmark,
            run.command,
            run.window,
            run.trace.path,
            run.trace.sha256,
            run.capture_manifest,
        )
        for run in runs
    }
    if run_replay_keys != authoritative_keys:
        _fail("manifest", "run replay set differs from authoritative capture replay list")
    configs_by_replay: dict[tuple[Any, ...], set[str]] = defaultdict(set)
    for run in runs:
        replay_key = (
            run.benchmark,
            run.command,
            run.window,
            run.trace.path,
            run.trace.sha256,
            run.capture_manifest,
        )
        if run.config_id in configs_by_replay[replay_key]:
            _fail("manifest", f"duplicate config {run.config_id!r} for replay {replay_key!r}")
        configs_by_replay[replay_key].add(run.config_id)
    for replay_key, config_ids in configs_by_replay.items():
        if config_ids != declared_config_ids:
            _fail(
                "manifest",
                f"replay {replay_key!r} has configs {sorted(config_ids)}, "
                f"expected {sorted(declared_config_ids)}",
            )
    return data, runs


def parse_workload_result(line: str, *, context: str = "WORKLOAD_RESULT") -> dict[str, str]:
    """Parse one result record, rejecting malformed or duplicate fields."""

    if not line.startswith(RESULT_PREFIX):
        _fail(context, f"line does not begin with {RESULT_PREFIX!r}")
    try:
        fields = shlex.split(line[len(RESULT_PREFIX) :].strip())
    except ValueError as exc:
        raise ValidationError(f"{context}: invalid quoting: {exc}") from exc
    row: dict[str, str] = {}
    for field in fields:
        if "=" not in field:
            _fail(context, f"malformed token without '=': {field!r}")
        key, value = field.split("=", 1)
        if not key or not value:
            _fail(context, f"malformed key/value token: {field!r}")
        if key in row:
            _fail(context, f"duplicate field {key!r}")
        row[key] = value
    return row


def parse_log(path: Path) -> tuple[dict[str, int], dict[str, str]]:
    """Read exactly one schema-2/3 result and normalize lifecycle counters."""

    text = path.read_text(encoding="utf-8", errors="strict")
    lines = [line for line in text.splitlines() if line.startswith(RESULT_PREFIX)]
    context = f"log {path}"
    if len(lines) != 1:
        _fail(context, f"expected exactly one WORKLOAD_RESULT line, found {len(lines)}")
    raw = parse_workload_result(lines[0], context=context)
    if "schema" not in raw:
        _fail(context, "missing required field 'schema'")
    schema = _int(raw["schema"], context, "schema")
    if schema not in RESULT_SCHEMAS:
        _fail(context, f"unsupported WORKLOAD_RESULT schema {schema}")
    required = set(STRING_RESULT_FIELDS) | set(INT_RESULT_FIELDS)
    if schema == 3:
        required.update(V3_LIFECYCLE_COUNTER_FIELDS)
    missing = sorted(required - raw.keys())
    if missing:
        _fail(context, f"missing schema={schema} fields: {', '.join(missing)}")

    counters = {field: _int(raw[field], context, field) for field in INT_RESULT_FIELDS}
    if schema == 3:
        counters.update(
            {
                field: _int(raw[field], context, field)
                for field in V3_LIFECYCLE_COUNTER_FIELDS
            }
        )
    else:
        issued = counters["prefetch_mem_reads"]
        installed = counters["fills"]
        counters.update(
            {
                "pf_candidates": issued + counters["dropped"],
                "pf_admitted": issued,
                "pf_issued": issued,
                "pf_returned": issued,
                "pf_installed": installed,
                "pf_merged": 0,
                "pf_discarded": 0,
                "pf_cancelled": 0,
                "pf_unused_evicted": counters["useless_evicted"],
                "pf_unused_resident": counters["unused_resident"],
                "pf_vc_bypass": 0,
                "pf_caused_writebacks": 0,
                "pf_demand_block_cycles": 0,
                "pf_true_help": 0,
                "pf_true_pollution": 0,
                "pf_suppressed_quota": 0,
                "pf_suppressed_unsafe": 0,
                "pf_same_line_coalesced": 0,
            }
        )
    strings = {field: raw[field] for field in STRING_RESULT_FIELDS}
    if counters["prefetch"] not in (0, 1):
        _fail(context, f"prefetch must be 0 or 1, got {counters['prefetch']}")
    return counters, strings


def _check_equal(context: str, expression: str, actual: int, expected: int) -> None:
    if actual != expected:
        _fail(context, f"conservation failure {expression}: got {actual}, expected {expected}")


def validate_counters(
    counters: Mapping[str, int], strings: Mapping[str, str], expected: ExpectedRun
) -> None:
    context = f"run {expected.config_id}/{expected.trace_id}"
    if strings["status"] != "PASS":
        _fail(context, f"status must be PASS, got {strings['status']!r}")
    if strings["config_id"] != expected.config_id:
        _fail(context, f"config_id mismatch: {strings['config_id']!r}")
    if strings["trace_id"] != expected.trace_id:
        _fail(context, f"trace_id mismatch: {strings['trace_id']!r}")
    for field in ("sets", "ways", "line_bytes", "victim_entries", "prefetch"):
        actual = counters[field]
        wanted = getattr(expected, field)
        if actual != wanted:
            _fail(context, f"{field} mismatch: log={actual}, manifest={wanted}")

    l1_bytes = expected.sets * expected.ways * expected.line_bytes
    victim_bytes = expected.victim_entries * expected.line_bytes
    _check_equal(context, "l1_bytes = sets * ways * line_bytes", counters["l1_bytes"], l1_bytes)
    _check_equal(
        context,
        "victim_bytes = victim_entries * line_bytes",
        counters["victim_bytes"],
        victim_bytes,
    )
    _check_equal(
        context,
        "total_bytes = l1_bytes + victim_bytes",
        counters["total_bytes"],
        l1_bytes + victim_bytes,
    )
    _check_equal(
        context,
        "hits + misses = accesses",
        counters["hits"] + counters["misses"],
        counters["accesses"],
    )
    if counters["victim_hits"] > counters["misses"]:
        _fail(context, "victim_hits exceeds misses")
    demand_reads = counters["misses"] - counters["victim_hits"]
    if counters["schema"] == 2:
        _check_equal(
            context,
            "demand_mem_reads = misses - victim_hits",
            counters["demand_mem_reads"],
            demand_reads,
        )
    else:
        _check_equal(
            context,
            "demand_mem_reads + pf_merged = misses - victim_hits",
            counters["demand_mem_reads"] + counters["pf_merged"],
            demand_reads,
        )
    _check_equal(
        context,
        "mem_reads = demand_mem_reads + prefetch_mem_reads",
        counters["mem_reads"],
        counters["demand_mem_reads"] + counters["prefetch_mem_reads"],
    )
    _check_equal(
        context,
        "prefetch_mem_reads = pf_issued",
        counters["prefetch_mem_reads"],
        counters["pf_issued"],
    )
    if counters["schema"] == 2:
        _check_equal(
            context,
            "prefetch_mem_reads = fills",
            counters["prefetch_mem_reads"],
            counters["fills"],
        )
    _check_equal(
        context,
        "pf_issued = pf_returned after drain",
        counters["pf_issued"],
        counters["pf_returned"],
    )
    _check_equal(
        context,
        "pf_returned = pf_installed + pf_merged + pf_discarded",
        counters["pf_returned"],
        counters["pf_installed"]
        + counters["pf_merged"]
        + counters["pf_discarded"],
    )
    _check_equal(
        context,
        "fills = pf_installed",
        counters["fills"],
        counters["pf_installed"],
    )
    _check_equal(
        context,
        "read_bytes = mem_reads * line_bytes",
        counters["read_bytes"],
        counters["mem_reads"] * counters["line_bytes"],
    )
    _check_equal(
        context,
        "write_bytes = mem_writes * line_bytes",
        counters["write_bytes"],
        counters["mem_writes"] * counters["line_bytes"],
    )
    _check_equal(
        context,
        "mem_writes = writebacks",
        counters["mem_writes"],
        counters["writebacks"],
    )
    if counters["schema"] == 2:
        _check_equal(
            context,
            "fills = useful + useless_evicted + unused_resident",
            counters["fills"],
            counters["useful"]
            + counters["useless_evicted"]
            + counters["unused_resident"],
        )
    else:
        _check_equal(
            context,
            "fills = timely_useful + useless_evicted + unused_resident",
            counters["fills"],
            counters["timely_useful"]
            + counters["useless_evicted"]
            + counters["unused_resident"],
        )
        _check_equal(
            context,
            "pf_installed = timely_useful + pf_unused_evicted + pf_unused_resident",
            counters["pf_installed"],
            counters["timely_useful"]
            + counters["pf_unused_evicted"]
            + counters["pf_unused_resident"],
        )
    _check_equal(
        context,
        "pf_unused_evicted = useless_evicted",
        counters["pf_unused_evicted"],
        counters["useless_evicted"],
    )
    _check_equal(
        context,
        "pf_unused_resident = unused_resident",
        counters["pf_unused_resident"],
        counters["unused_resident"],
    )
    if counters["pf_issued"] > counters["pf_admitted"]:
        _fail(context, "pf_issued exceeds pf_admitted")
    if counters["pf_admitted"] > counters["pf_candidates"]:
        _fail(context, "pf_admitted exceeds pf_candidates")
    if counters["pf_admitted"] > (
        counters["pf_issued"] + counters["pf_cancelled"]
    ):
        _fail(
            context,
            "pf_admitted must be <= pf_issued + pf_cancelled after drain",
        )
    _check_equal(
        context,
        "useful = timely_useful + late_useful",
        counters["useful"],
        counters["timely_useful"] + counters["late_useful"],
    )
    if counters["schema"] == 3:
        _check_equal(
            context,
            "late_useful = pf_merged",
            counters["late_useful"],
            counters["pf_merged"],
        )
    if counters["schema"] == 2 and expected.timing_profile.startswith("blocking-") and counters["late_useful"] != 0:
        _fail(
            context,
            "blocking replay cannot observe an independent late prefetch; late_useful must be zero",
        )
    for field in ("watchdogs", "protocol", "duplicate_lines"):
        if counters[field] != 0:
            _fail(context, f"{field} must be zero for a valid run, got {counters[field]}")
    if expected.prefetch == 0:
        nonzero = {field: counters[field] for field in PREFETCH_COUNTER_FIELDS if counters[field]}
        if nonzero:
            _fail(context, f"prefetch-off run has non-zero prefetch counters: {nonzero}")


def _parse_addr(value: Any, context: str) -> int:
    if not isinstance(value, str):
        value = str(value)
    try:
        if value.lower().startswith("0x"):
            return int(value, 16)
        # Traces conventionally print addresses in hexadecimal without 0x.
        return int(value, 16)
    except ValueError:
        _fail(context, f"invalid address {value!r}")


def _normalize_op(value: Any, context: str) -> str:
    op = str(value).lower()
    if op in {"0", "r", "read", "load", "l"}:
        return "load"
    if op in {"1", "w", "write", "store", "s"}:
        return "store"
    _fail(context, f"unsupported operation {value!r}")


def _parse_key_value_line(line: str, context: str) -> dict[str, str]:
    try:
        tokens = shlex.split(line)
    except ValueError as exc:
        raise ValidationError(f"{context}: invalid quoting: {exc}") from exc
    result: dict[str, str] = {}
    for token in tokens:
        if "=" not in token:
            _fail(context, f"expected key=value token, got {token!r}")
        key, value = token.split("=", 1)
        if key in result:
            _fail(context, f"duplicate field {key!r}")
        result[key] = value
    return result


SIDECAR_V2_FIELDS = frozenset(
    {"schema", "event", "seq", "cycle", "addr", "op", "size", "outcome", "details"}
)
SIDECAR_V3_FIELDS = SIDECAR_V2_FIELDS | {"latency"}
SIDECAR_V2_EVENTS = frozenset({"demand", "prefetch_issue", "prefetch_fill"})
SIDECAR_V3_EVENTS = frozenset(
    {
        "demand_present",
        "demand_accept",
        "demand_response",
        "prefetch_candidate",
        "prefetch_admit",
        "prefetch_issue",
        "prefetch_return",
        "prefetch_fill",
        "prefetch_install",
        "prefetch_use",
        "prefetch_evict",
        "prefetch_cancel",
        "prefetch_discard",
        "prefetch_merge",
        "prefetch_suppressed",
        "prefetch_writeback",
        "controller_state",
    }
)


def parse_sidecar(
    path: Path,
    *,
    line_bytes: int,
) -> tuple[list[DemandAccess], dict[str, int]]:
    """Parse schema-2 demand rows or schema-3 lifecycle sidecar events."""

    if line_bytes <= 0 or (line_bytes & (line_bytes - 1)) != 0:
        raise ValueError("line_bytes must be a positive power of two")

    lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
    noncomment = [(n, line) for n, line in enumerate(lines, 1) if line.strip() and not line.lstrip().startswith("#")]
    if not noncomment:
        _fail(f"sidecar {path}", "contains no records")

    header: list[str] | None = None
    first_line = noncomment[0][1]
    if "\t" in first_line and "=" not in first_line:
        header = first_line.split("\t")
        if len(set(header)) != len(header):
            _fail(f"sidecar {path}:{noncomment[0][0]}", "TSV header has duplicate fields")
        noncomment = noncomment[1:]

    accesses: list[DemandAccess] = []
    event_counts: Counter[str] = Counter()
    seen_seq: set[int] = set()
    last_seq: int | None = None
    sidecar_schema: int | None = None
    lifecycle_cycles: dict[int, dict[str, int]] = defaultdict(dict)
    for line_number, line in noncomment:
        context = f"sidecar {path}:{line_number}"
        if header is None:
            row = _parse_key_value_line(line, context)
        else:
            values = line.split("\t")
            if len(values) != len(header):
                _fail(context, f"expected {len(header)} TSV columns, got {len(values)}")
            row = dict(zip(header, values))
        schema = _int(_require(row, "schema", context), context, "schema")
        if schema not in RESULT_SCHEMAS:
            _fail(context, f"unsupported sidecar schema {schema}")
        if sidecar_schema is None:
            sidecar_schema = schema
        elif schema != sidecar_schema:
            _fail(context, f"mixed sidecar schemas {sidecar_schema} and {schema}")
        expected_fields = SIDECAR_V2_FIELDS if schema == 2 else SIDECAR_V3_FIELDS
        if set(row) != expected_fields:
            missing = sorted(expected_fields - set(row))
            extra = sorted(set(row) - expected_fields)
            _fail(
                context,
                f"sidecar fields differ from schema={schema}; missing={missing}, extra={extra}",
            )
        event = _string(_require(row, "event", context), context, "event")
        supported_events = SIDECAR_V2_EVENTS if schema == 2 else SIDECAR_V3_EVENTS
        if event not in supported_events:
            _fail(context, f"unsupported sidecar event {event!r}")
        event_counts[event] += 1

        cycle = _int(row["cycle"], context, "cycle")
        addr = _parse_addr(row["addr"], context)
        details = str(row["details"])
        if schema == 2 and details != "-":
            _fail(context, f"details must be '-', got {details!r}")
        if schema == 3:
            try:
                latency = int(str(row["latency"]), 0)
            except ValueError:
                _fail(context, f"latency is not an integer: {row['latency']!r}")
            if latency < -1:
                _fail(context, f"latency must be >= -1, got {latency}")

        demand_event = event == "demand" or event.startswith("demand_")
        if not demand_event:
            try:
                seq = int(str(row["seq"]), 0)
            except ValueError:
                _fail(context, f"seq is not an integer: {row['seq']!r}")
            if seq != -1:
                _fail(context, f"{event} seq must be -1, got {seq}")
            if event == "controller_state":
                continue
            if str(row["op"]) != "prefetch":
                _fail(context, f"{event} op must be 'prefetch'")
            size = _int(row["size"], context, "size", minimum=1)
            if size != line_bytes:
                _fail(
                    context,
                    f"{event} size must equal line_bytes={line_bytes}, got {size}",
                )
            if addr % line_bytes != 0:
                _fail(context, f"{event} address is not line-aligned: 0x{addr:x}")
            if schema == 2:
                expected_outcome = (
                    "lower_memory" if event == "prefetch_issue" else "l1_hit"
                )
            elif event == "prefetch_issue":
                expected_outcome = "lower_memory"
            else:
                expected_outcome = None
            if expected_outcome is not None and str(row["outcome"]) != expected_outcome:
                _fail(
                    context,
                    f"{event} outcome must be {expected_outcome!r}",
                )
            continue

        seq = _int(row["seq"], context, "seq")
        op = _normalize_op(row["op"], context)
        size = _int(row["size"], context, "size")
        if size > 3:
            _fail(context, f"size must be in 0..3, got {size}")
        outcome = str(row["outcome"])
        if schema == 3 and event in {"demand_present", "demand_accept"}:
            if outcome != "pending":
                _fail(context, f"{event} outcome must be 'pending'")
            expected_latency = -1 if event == "demand_present" else 0
            if latency != expected_latency:
                _fail(
                    context,
                    f"{event} latency must be {expected_latency}",
                )
            if event in lifecycle_cycles[seq]:
                _fail(context, f"duplicate {event} for demand seq {seq}")
            lifecycle_cycles[seq][event] = cycle
            continue
        if outcome not in {"l1_hit", "victim_hit", "lower_memory"}:
            _fail(context, f"unsupported demand outcome {outcome!r}")
        if schema == 3:
            if event != "demand_response":
                _fail(context, f"completed schema-3 demand must use event=demand_response")
            accepted = lifecycle_cycles[seq].get("demand_accept")
            if accepted is None:
                _fail(context, f"demand_response precedes/misses demand_accept for seq {seq}")
            if latency != cycle - accepted:
                _fail(
                    context,
                    f"demand_response latency={latency} does not equal response-accept "
                    f"cycles={cycle - accepted}",
                )
            lifecycle_cycles[seq][event] = cycle
        if seq in seen_seq:
            _fail(context, f"duplicate demand seq {seq}")
        if last_seq is not None and seq <= last_seq:
            _fail(context, f"demand seq is not strictly increasing: {last_seq} then {seq}")
        seen_seq.add(seq)
        last_seq = seq
        accesses.append(DemandAccess(seq, cycle, addr, op, size, outcome))
    if not accesses:
        _fail(f"sidecar {path}", "contains no completed demand records")
    if sidecar_schema == 3:
        for seq in seen_seq:
            events = lifecycle_cycles[seq]
            missing = {
                "demand_present",
                "demand_accept",
                "demand_response",
            } - set(events)
            if missing:
                _fail(
                    f"sidecar {path}",
                    f"demand seq {seq} is missing lifecycle events {sorted(missing)}",
                )
            if not (
                events["demand_present"]
                <= events["demand_accept"]
                <= events["demand_response"]
            ):
                _fail(f"sidecar {path}", f"demand seq {seq} lifecycle cycles regress")
    return accesses, dict(event_counts)


class _Fenwick:
    def __init__(self, size: int) -> None:
        self.tree = [0] * (size + 1)

    def add(self, index: int, delta: int) -> None:
        index += 1
        while index < len(self.tree):
            self.tree[index] += delta
            index += index & -index

    def prefix(self, end: int) -> int:
        total = 0
        while end > 0:
            total += self.tree[end]
            end -= end & -end
        return total

    def range_sum(self, start: int, end: int) -> int:
        return self.prefix(end) - self.prefix(start)


def _percentile(values: Sequence[int], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) - 1) * percentile
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return float(ordered[lower])
    fraction = rank - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def _trace_records(path: Path, phase: str = "measure") -> tuple[list[tuple[str, int, int]], int]:
    """Return (op, size, physical address) records and total payload rows."""

    if phase not in {"measure", "warmup", "all"}:
        raise ValueError(f"unsupported phase {phase!r}")
    lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
    current_phase = "measure"
    header: list[str] | None = None
    records: list[tuple[str, int, int]] = []
    total_payload = 0
    for line_number, original in enumerate(lines, 1):
        line = original.strip()
        if not line:
            continue
        if line.startswith("#"):
            match = re.match(r"#\s*PHASE\s+(warmup|measure)\s*$", line, re.IGNORECASE)
            if match:
                current_phase = match.group(1).lower()
            continue
        context = f"trace {path}:{line_number}"
        if header is None and "\t" in original and "=" not in original:
            candidate = original.rstrip("\r\n").split("\t")
            if "op" in candidate and ("paddr" in candidate or "addr" in candidate):
                header = candidate
                continue

        if header is not None:
            values = original.rstrip("\r\n").split("\t")
            if len(values) != len(header):
                _fail(context, f"expected {len(header)} TSV columns, got {len(values)}")
            row = dict(zip(header, values))
            op = _normalize_op(_require(row, "op", context), context)
            size = _int(_require(row, "size", context), context, "size")
            addr_value = row.get("paddr", row.get("addr"))
            if addr_value is None:
                _fail(context, "TSV row has neither paddr nor addr")
            addr = _parse_addr(addr_value, context)
        elif "=" in line:
            row = _parse_key_value_line(line, context)
            op = _normalize_op(_require(row, "op", context), context)
            size = _int(_require(row, "size", context), context, "size")
            addr_value = row.get("paddr", row.get("addr"))
            if addr_value is None:
                _fail(context, "key/value row has neither paddr nor addr")
            addr = _parse_addr(addr_value, context)
        else:
            fields = line.split()
            if len(fields) not in (4, 5):
                _fail(context, f"expected a 4/5-column replay record, got {len(fields)}")
            op = _normalize_op(fields[0], context)
            size = _int(fields[1], context, "size")
            addr = _parse_addr(fields[3], context)
        if size > 3:
            _fail(context, f"size must be in 0..3, got {size}")
        total_payload += 1
        if phase == "all" or current_phase == phase:
            records.append((op, size, addr))
    if not records:
        _fail(f"trace {path}", f"contains no {phase} memory records")
    return records, total_payload


def analyze_trace(
    path: Path,
    *,
    line_bytes: int,
    sets: int,
    ways: int,
    phase: str = "measure",
) -> dict[str, Any]:
    """Compute locality and set-pressure features for one replay window."""

    if line_bytes <= 0 or sets <= 0 or ways <= 0:
        raise ValueError("line_bytes, sets, and ways must be positive")
    records, total_payload = _trace_records(path, phase)
    lines = [addr // line_bytes for _, _, addr in records]
    loads = sum(op == "load" for op, _, _ in records)
    stores = len(records) - loads
    unique_lines = len(set(lines))

    strides = [right - left for left, right in zip(lines, lines[1:])]
    stride_counts = Counter(strides)
    most_common_stride: int | None = None
    most_common_stride_fraction: float | None = None
    if stride_counts:
        most_common_stride, count = sorted(
            stride_counts.items(), key=lambda item: (-item[1], abs(item[0]), item[0])
        )[0]
        most_common_stride_fraction = count / len(strides)

    fenwick = _Fenwick(len(lines))
    last_position: dict[int, int] = {}
    reuse_distances: list[int] = []
    for position, line in enumerate(lines):
        previous = last_position.get(line)
        if previous is not None:
            reuse_distances.append(fenwick.range_sum(previous + 1, position))
            fenwick.add(previous, -1)
        fenwick.add(position, 1)
        last_position[line] = position

    set_access_counts = [0] * sets
    set_unique: list[set[int]] = [set() for _ in range(sets)]
    for line in lines:
        set_index = line % sets
        set_access_counts[set_index] += 1
        set_unique[set_index].add(line)
    set_unique_counts = [len(items) for items in set_unique]
    mean_accesses = len(lines) / sets
    mean_unique = unique_lines / sets

    return {
        "trace_sha256": _sha256(path),
        "trace_payload_records": total_payload,
        "trace_phase": phase,
        "trace_accesses": len(records),
        "trace_loads": loads,
        "trace_stores": stores,
        "trace_load_store_ratio": None if stores == 0 else loads / stores,
        "trace_load_fraction": loads / len(records),
        "trace_unique_lines": unique_lines,
        "trace_unique_line_bytes": unique_lines * line_bytes,
        "trace_footprint_l1_ratio": unique_lines / (sets * ways),
        "trace_stride_count": len(strides),
        "trace_most_common_line_stride": most_common_stride,
        "trace_most_common_stride_fraction": most_common_stride_fraction,
        "trace_next_line_stride_fraction": (
            None if not strides else sum(stride == 1 for stride in strides) / len(strides)
        ),
        "trace_mean_abs_line_stride": (
            None if not strides else sum(abs(stride) for stride in strides) / len(strides)
        ),
        "trace_cold_line_accesses": unique_lines,
        "trace_reuse_count": len(reuse_distances),
        "trace_reuse_distance_mean": (
            None if not reuse_distances else statistics.fmean(reuse_distances)
        ),
        "trace_reuse_distance_median": (
            None if not reuse_distances else statistics.median(reuse_distances)
        ),
        "trace_reuse_distance_p90": _percentile(reuse_distances, 0.90),
        "trace_reuse_distance_max": max(reuse_distances) if reuse_distances else None,
        "trace_set_access_max": max(set_access_counts),
        "trace_set_access_mean": mean_accesses,
        "trace_set_access_imbalance": max(set_access_counts) / mean_accesses,
        "trace_hottest_set_fraction": max(set_access_counts) / len(lines),
        "trace_set_unique_line_max": max(set_unique_counts),
        "trace_set_unique_line_mean": mean_unique,
        "trace_set_unique_imbalance": (
            0.0 if mean_unique == 0 else max(set_unique_counts) / mean_unique
        ),
        "trace_sets_over_way_capacity": sum(count > ways for count in set_unique_counts),
        "trace_max_unique_lines_over_ways": max(max(set_unique_counts) - ways, 0),
    }


def _validate_capture_manifest(run: ExpectedRun, trace_features: Mapping[str, Any]) -> None:
    if run.capture_manifest is None:
        return
    context = f"capture manifest {run.capture_manifest}"
    try:
        capture = json.loads(run.capture_manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError(f"{context}: {exc}") from exc
    if capture.get("schema") != "l1d-qemu-capture-manifest-v2":
        _fail(context, f"unsupported schema {capture.get('schema')!r}")
    if capture.get("status") != "PASS" or capture.get("valid") is not True:
        _fail(context, "capture must have status=PASS and valid=true")
    toolchain = capture.get("toolchain")
    if not isinstance(toolchain, dict):
        _fail(context, "missing toolchain provenance")
    if not str(toolchain.get("qemu_version", "")).startswith(
        "QEMU emulator version 11.0.1"
    ):
        _fail(context, "capture requires QEMU 11.0.1")
    if (
        toolchain.get("plugin_api") != 6
        or toolchain.get("target") != "riscv64"
        or toolchain.get("system_emulation") is not True
        or toolchain.get("smp_vcpus") != 1
    ):
        _fail(context, "capture requires plugin API 6, system riscv64, and smp=1")
    _validate_digest(str(toolchain.get("plugin_sha256", "")), context)

    command = capture.get("command")
    if not isinstance(command, dict):
        _fail(context, "missing command/ELF provenance")
    _validate_digest(str(command.get("sha256", "")), context)
    _validate_digest(str(command.get("elf_sha256", "")), context)
    if not command.get("path") or not command.get("executable"):
        _fail(context, "command executable identity is incomplete")

    guest_tools = capture.get("guest_tools")
    if (
        not isinstance(guest_tools, dict)
        or guest_tools.get("schema") != "l1d-trace-roi-guest-tools-v1"
    ):
        _fail(context, "missing guest ROI tool provenance")
    _validate_digest(str(guest_tools.get("source_sha256", "")), context)
    binaries = guest_tools.get("binaries")
    if not isinstance(binaries, dict):
        _fail(context, "missing guest ROI binary hashes")
    for binary_name in ("libl1d_roi.so", "trace_exec"):
        _validate_digest(str(binaries.get(binary_name, "")), context)

    roi = capture.get("roi")
    if not isinstance(roi, dict):
        _fail(context, "missing roi object")
    if roi.get("count_matches_capture") is not True:
        _fail(context, "roi.count_matches_capture must be true")
    if roi.get("violations") not in ([], None):
        _fail(context, f"ROI contains violations: {roi.get('violations')!r}")
    if (
        roi.get("start_seen") is not True
        or roi.get("stop_seen") is not True
        or roi.get("vcpu") != 0
        or roi.get("priv") != 0
        or roi.get("marker_version") != 2
    ):
        _fail(context, "ROI must have one U-mode vCPU0 schema-v2 START/STOP pair")
    satp = _int(_require(roi, "satp", context), context, "satp")
    if satp == 0:
        _fail(context, "ROI SATP must be non-Bare")
    event_counts = [
        _int(_require(roi, field, context), context, field, minimum=1)
        for field in ("total_events", "count_pass_events", "capture_pass_events")
    ]
    if len(set(event_counts)) != 1:
        _fail(context, "ROI count/capture event totals differ")

    guest = capture.get("guest")
    if not isinstance(guest, dict) or not guest.get("kernel"):
        _fail(context, "missing guest kernel provenance")
    capture_artifacts = capture.get("artifacts")
    if not isinstance(capture_artifacts, dict) or not capture_artifacts:
        _fail(context, "missing capture evidence artifacts")
    for name, value in capture_artifacts.items():
        checked = _artifact(value, run.capture_manifest.parent, f"{context}.artifacts.{name}")
        if checked.sha256 is None:
            _fail(context, f"capture artifact {name!r} has no SHA-256")
    if str(capture.get("benchmark")) != run.benchmark:
        _fail(context, "benchmark does not match replay campaign")
    if str(capture.get("command_index")) != run.command:
        _fail(context, "command_index does not match replay campaign")
    windows = capture.get("windows")
    if not isinstance(windows, list):
        _fail(context, "windows must be an array")
    matches = [item for item in windows if isinstance(item, dict) and item.get("index") == run.capture_window_index]
    if len(matches) != 1:
        _fail(context, f"expected exactly one window index {run.capture_window_index}, found {len(matches)}")
    window = matches[0]
    for field, expected_value in (
        ("kind", run.capture_window_kind),
        ("warmup_events", run.warmup_events),
        ("measure_events", run.measure_events),
        ("total_events", run.total_events),
    ):
        if window.get(field) != expected_value:
            _fail(context, f"window {field} differs from replay campaign")
    if run.warmup_events + run.measure_events != run.total_events:
        _fail(context, "campaign warmup + measure does not equal total events")
    if run.capture_window_kind == "whole":
        if run.warmup_events != 0 or run.cold_warm_mode != "whole-roi-short":
            _fail(context, "whole short ROI must have zero warmup and whole-roi-short mode")
    elif run.warmup_events <= 0 or run.cold_warm_mode != "demand-warm-measure":
        _fail(context, "sampled ROI must use a nonzero demand warmup")
    if run.measure_events != trace_features["trace_accesses"]:
        _fail(context, "capture measure_events differs from parsed trace")
    if run.total_events != trace_features["trace_payload_records"]:
        _fail(context, "capture total_events differs from parsed trace")
    replay = window.get("replay")
    if not isinstance(replay, dict):
        _fail(context, "selected window has no replay artifact")
    replay_artifact = _artifact(replay, run.capture_manifest.parent, f"{context}.window.replay")
    if replay_artifact.sha256 is None:
        _fail(context, "selected replay artifact has no SHA-256")
    if replay_artifact.sha256 != run.trace.sha256:
        _fail(context, "replay trace digest differs from campaign")
    payload_lines = replay.get("payload_lines")
    if (
        payload_lines is not None
        and _int(payload_lines, context, "payload_lines")
        != trace_features["trace_payload_records"]
    ):
        _fail(context, "replay payload_lines differs from parsed trace")


def _validate_sidecar_counts(run: RunRecord) -> None:
    if run.accesses is None:
        if run.sidecar_event_counts is not None:
            _fail("sidecar", "event counts exist without parsed demand rows")
        return
    if run.sidecar_event_counts is None:
        _fail("sidecar", "parsed demand rows lack event counts")
    context = f"sidecar {run.expected.sidecar.path if run.expected.sidecar else ''}"
    counts = Counter(access.outcome for access in run.accesses)
    sidecar_schema3 = "demand_response" in run.sidecar_event_counts
    result_schema3 = run.counters["schema"] == 3
    completed_event = "demand_response" if sidecar_schema3 else "demand"
    _check_equal(
        context,
        f"event={completed_event} rows = accesses",
        run.sidecar_event_counts.get(completed_event, 0),
        run.counters["accesses"],
    )
    if sidecar_schema3:
        for event in ("demand_present", "demand_accept"):
            _check_equal(
                context,
                f"event={event} rows = accesses",
                run.sidecar_event_counts.get(event, 0),
                run.counters["accesses"],
            )
    _check_equal(context, "demand rows = accesses", len(run.accesses), run.counters["accesses"])
    _check_equal(context, "l1_hit rows = hits", counts["l1_hit"], run.counters["hits"])
    _check_equal(
        context, "victim_hit rows = victim_hits", counts["victim_hit"], run.counters["victim_hits"]
    )
    if result_schema3:
        _check_equal(
            context,
            "lower_memory rows = demand_mem_reads + pf_merged",
            counts["lower_memory"],
            run.counters["demand_mem_reads"] + run.counters["pf_merged"],
        )
    else:
        _check_equal(
            context,
            "lower_memory rows = demand_mem_reads",
            counts["lower_memory"],
            run.counters["demand_mem_reads"],
        )
    _check_equal(
        context,
        "prefetch_issue rows = prefetch_mem_reads",
        run.sidecar_event_counts.get("prefetch_issue", 0),
        run.counters["prefetch_mem_reads"],
    )
    if run.sidecar_event_counts.get("prefetch_return", 0):
        _check_equal(
            context,
            "prefetch_return rows = pf_returned",
            run.sidecar_event_counts.get("prefetch_return", 0),
            run.counters["pf_returned"],
        )
    if run.sidecar_event_counts.get("prefetch_install", 0):
        _check_equal(
            context,
            "prefetch_install rows = pf_installed",
            run.sidecar_event_counts.get("prefetch_install", 0),
            run.counters["pf_installed"],
        )
    else:
        _check_equal(
            context,
            "prefetch_fill rows = fills",
            run.sidecar_event_counts.get("prefetch_fill", 0),
            run.counters["fills"],
        )
    optional_lifecycle = {
        "prefetch_candidate": "pf_candidates",
        "prefetch_admit": "pf_admitted",
        "prefetch_merge": "pf_merged",
        "prefetch_discard": "pf_discarded",
        "prefetch_cancel": "pf_cancelled",
        "prefetch_use": "timely_useful",
        "prefetch_evict": "pf_unused_evicted",
    }
    for event, counter in optional_lifecycle.items():
        if run.sidecar_event_counts.get(event, 0):
            _check_equal(
                context,
                f"{event} rows = {counter}",
                run.sidecar_event_counts[event],
                run.counters[counter],
            )
    if run.sidecar_event_counts.get("prefetch_suppressed", 0):
        _check_equal(
            context,
            "prefetch_suppressed rows = quota + unsafe suppressions",
            run.sidecar_event_counts["prefetch_suppressed"],
            run.counters["pf_suppressed_quota"] +
            run.counters["pf_suppressed_unsafe"],
        )
    if run.sidecar_event_counts.get("prefetch_writeback", 0):
        _check_equal(
            context,
            "prefetch_writeback rows = pf_caused_writebacks",
            run.sidecar_event_counts["prefetch_writeback"],
            run.counters["pf_caused_writebacks"],
        )


def _validate_sidecar_trace_identity(run: RunRecord) -> None:
    """Match every measurement demand row to the canonical replay record."""

    if run.accesses is None:
        return
    trace_records, _total_payload = _trace_records(
        run.expected.trace.path,
        phase="measure",
    )
    context = (
        f"sidecar {run.expected.sidecar.path if run.expected.sidecar else ''}"
        f" / trace {run.expected.trace.path}"
    )
    _check_equal(
        context,
        "sidecar demand rows = measurement trace records",
        len(run.accesses),
        len(trace_records),
    )
    for seq, (access, (op, size, addr)) in enumerate(
        zip(run.accesses, trace_records)
    ):
        expected_identity = (seq, addr, op, size)
        if access.identity != expected_identity:
            _fail(
                context,
                f"demand identity mismatch at row {seq}: "
                f"sidecar={access.identity!r}, trace={expected_identity!r}",
            )


def load_run(expected: ExpectedRun) -> RunRecord:
    counters, strings = parse_log(expected.log.path)
    validate_counters(counters, strings, expected)
    features = analyze_trace(
        expected.trace.path,
        line_bytes=expected.line_bytes,
        sets=expected.sets,
        ways=expected.ways,
        phase="measure",
    )
    if features["trace_sha256"] != expected.trace.sha256:
        _fail(f"trace {expected.trace.path}", "parsed trace digest differs from manifest")
    if features["trace_accesses"] != counters["accesses"]:
        _fail(
            f"trace {expected.trace.path}",
            f"measurement access count {features['trace_accesses']} != log accesses {counters['accesses']}",
        )
    _validate_capture_manifest(expected, features)
    if expected.sidecar:
        accesses, sidecar_event_counts = parse_sidecar(
            expected.sidecar.path,
            line_bytes=expected.line_bytes,
        )
    else:
        accesses = None
        sidecar_event_counts = None
    record = RunRecord(
        expected,
        counters,
        strings,
        features,
        accesses,
        sidecar_event_counts,
    )
    _validate_sidecar_counts(record)
    _validate_sidecar_trace_identity(record)
    return record


def ratio(numerator: int | float, denominator: int | float) -> float | None:
    return None if denominator == 0 else numerator / denominator


def _metric_fields(counters: Mapping[str, int]) -> dict[str, float | None]:
    return {
        "hit_rate": ratio(counters["hits"], counters["accesses"]),
        "victim_hit_rate": ratio(counters["victim_hits"], counters["accesses"]),
        "accuracy": ratio(counters["useful"], counters["fills"]),
        "timeliness": ratio(
            counters["timely_useful"],
            counters["timely_useful"] + counters["late_useful"],
        ),
        "bytes_per_demand": ratio(
            counters["read_bytes"] + counters["write_bytes"], counters["accesses"]
        ),
        "cycles_per_demand": ratio(counters["replay_service_cycles"], counters["accesses"]),
    }


def _pair_sidecars(off: RunRecord, on: RunRecord) -> dict[str, int | None]:
    if off.accesses is None and on.accesses is None:
        return {
            "true_l1_help": None,
            "true_l1_pollution": None,
            "true_lower_help": None,
            "true_lower_pollution": None,
        }
    if off.accesses is None or on.accesses is None:
        _fail(f"pair {off.expected.pair_key!r}", "sidecars must be present for both runs or neither")
    assert off.accesses is not None and on.accesses is not None
    if len(off.accesses) != len(on.accesses):
        _fail(f"pair {off.expected.pair_key!r}", "off/on sidecar lengths differ")

    l1_help = l1_pollution = lower_help = lower_pollution = 0
    for index, (off_access, on_access) in enumerate(zip(off.accesses, on.accesses)):
        if off_access.identity != on_access.identity:
            _fail(
                f"pair {off.expected.pair_key!r}",
                f"demand identity mismatch at row {index}: "
                f"{off_access.identity!r} != {on_access.identity!r}",
            )
        off_l1 = off_access.outcome == "l1_hit"
        on_l1 = on_access.outcome == "l1_hit"
        off_lower = off_access.outcome == "lower_memory"
        on_lower = on_access.outcome == "lower_memory"
        if not off_l1 and on_l1:
            l1_help += 1
        elif off_l1 and not on_l1:
            l1_pollution += 1
        if off_lower and not on_lower:
            lower_help += 1
        elif not off_lower and on_lower:
            lower_pollution += 1

    l1_delta = on.counters["misses"] - off.counters["misses"]
    # A schema-3 late merge still observes a lower-level demand outcome, but
    # the already-issued prefetch owns the physical read.  Include merged
    # responses when reconciling causal outcome tiers, while retaining the
    # raw demand-read delta as the bandwidth-facing metric below.
    off_required_lower = off.counters["demand_mem_reads"] + off.counters["pf_merged"]
    on_required_lower = on.counters["demand_mem_reads"] + on.counters["pf_merged"]
    lower_delta = on_required_lower - off_required_lower
    _check_equal(
        f"pair {off.expected.pair_key!r}",
        "L1 miss delta(on-off) = pollution - help",
        l1_delta,
        l1_pollution - l1_help,
    )
    _check_equal(
        f"pair {off.expected.pair_key!r}",
        "required-lower delta(on-off) = pollution - help",
        lower_delta,
        lower_pollution - lower_help,
    )
    return {
        "true_l1_help": l1_help,
        "true_l1_pollution": l1_pollution,
        "true_lower_help": lower_help,
        "true_lower_pollution": lower_pollution,
    }


def build_pair(off: RunRecord, on: RunRecord) -> dict[str, Any]:
    context = f"pair {off.expected.pair_key!r}"
    if off.expected.prefetch != 0 or on.expected.prefetch != 1:
        _fail(context, "internal off/on ordering error")
    for field in ("trace_id", "timing_profile", "cold_warm_mode"):
        left = getattr(off.expected, field)
        right = getattr(on.expected, field)
        if left != right:
            _fail(context, f"{field} mismatch: {left!r} != {right!r}")
    if off.expected.trace.sha256 != on.expected.trace.sha256:
        _fail(context, "off/on trace SHA-256 differs")
    if off.counters["accesses"] != on.counters["accesses"]:
        _fail(context, "off/on access counts differ")

    row = {field: getattr(off.expected, field) for field in PAIR_KEY_FIELDS}
    row.update(
        {
            "cold_warm_mode": off.expected.cold_warm_mode,
            "trace_id": off.expected.trace_id,
            "trace_sha256": off.expected.trace.sha256,
            "off_config_id": off.expected.config_id,
            "on_config_id": on.expected.config_id,
        }
    )
    for prefix, record in (("off", off), ("on", on)):
        for field in RAW_COUNTER_FIELDS:
            row[f"{prefix}_{field}"] = record.counters[field]

    off_bytes = off.counters["read_bytes"] + off.counters["write_bytes"]
    on_bytes = on.counters["read_bytes"] + on.counters["write_bytes"]
    row.update(
        {
            "accuracy": ratio(on.counters["useful"], on.counters["fills"]),
            "l1_coverage": ratio(
                off.counters["misses"] - on.counters["misses"], off.counters["misses"]
            ),
            "lower_coverage": ratio(
                off.counters["demand_mem_reads"] - on.counters["demand_mem_reads"],
                off.counters["demand_mem_reads"],
            ),
            "bandwidth_overhead": ratio(on_bytes - off_bytes, off_bytes),
            "bytes_on_minus_off": on_bytes - off_bytes,
            "cycles_on_minus_off": on.counters["replay_service_cycles"]
            - off.counters["replay_service_cycles"],
            "cycle_delta_fraction": ratio(
                on.counters["replay_service_cycles"]
                - off.counters["replay_service_cycles"],
                off.counters["replay_service_cycles"],
            ),
            "timeliness": ratio(
                on.counters["timely_useful"],
                on.counters["timely_useful"] + on.counters["late_useful"],
            ),
        }
    )
    cycle_delta = row["cycles_on_minus_off"]
    row["cycle_class"] = "harmful" if cycle_delta > 0 else "helpful" if cycle_delta < 0 else "neutral"
    row.update(_pair_sidecars(off, on))
    for field, value in off.trace_features.items():
        row[field] = value
    return row


def pair_runs(
    records: Sequence[RunRecord],
    *,
    expected_pairs: int | None = None,
    paired_config_ids: set[str] | None = None,
    standalone_config_ids: set[str] | None = None,
) -> list[dict[str, Any]]:
    grouped: dict[tuple[Any, ...], dict[int, RunRecord]] = defaultdict(dict)
    for record in records:
        key = record.expected.pair_key
        if record.expected.prefetch in grouped[key]:
            _fail("campaign", f"duplicate parsed run for pair {key!r}, prefetch={record.expected.prefetch}")
        grouped[key][record.expected.prefetch] = record
    pairs: list[dict[str, Any]] = []
    for key in sorted(grouped, key=lambda item: tuple(str(value) for value in item)):
        variants = grouped[key]
        if set(variants) == {0, 1}:
            config_ids = {record.expected.config_id for record in variants.values()}
            if paired_config_ids is not None and config_ids != paired_config_ids:
                _fail(
                    "campaign",
                    f"pair {key!r} uses configs {sorted(config_ids)}, "
                    f"expected {sorted(paired_config_ids)}",
                )
            pairs.append(build_pair(variants[0], variants[1]))
        elif set(variants) == {0}:
            # Capacity-control geometries may intentionally be baseline-only.
            # expected_pairs prevents a missing pf1 from being silently
            # reclassified as standalone in a fixed campaign matrix.
            config_id = variants[0].expected.config_id
            if standalone_config_ids is not None and config_id not in standalone_config_ids:
                _fail(
                    "campaign",
                    f"baseline-only config {config_id!r} is not declared standalone",
                )
            continue
        else:
            _fail(
                "campaign",
                f"prefetch-on run for {key!r} requires exactly one matching prefetch-off run",
            )
    if expected_pairs is not None and len(pairs) != expected_pairs:
        _fail(
            "campaign",
            f"expected_pairs={expected_pairs}, but validated {len(pairs)} off/on pairs",
        )
    return pairs


def _sum_prefixed(rows: Sequence[Mapping[str, Any]], prefix: str, field: str) -> int:
    return sum(int(row[f"{prefix}_{field}"]) for row in rows)


def aggregate_pairs(pairs: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[Any, ...], list[Mapping[str, Any]]] = defaultdict(list)
    for pair in pairs:
        key = tuple(pair[field] for field in AGGREGATE_KEY_FIELDS)
        grouped[key].append(pair)

    aggregates: list[dict[str, Any]] = []
    for key in sorted(grouped, key=lambda item: tuple(str(value) for value in item)):
        rows = grouped[key]
        aggregate = dict(zip(AGGREGATE_KEY_FIELDS, key))
        aggregate["pair_count"] = len(rows)
        for prefix in ("off", "on"):
            for field in RAW_COUNTER_FIELDS:
                aggregate[f"{prefix}_{field}"] = _sum_prefixed(rows, prefix, field)
        off_misses = aggregate["off_misses"]
        on_misses = aggregate["on_misses"]
        off_lower = aggregate["off_demand_mem_reads"]
        on_lower = aggregate["on_demand_mem_reads"]
        off_required_lower = off_lower + aggregate["off_pf_merged"]
        on_required_lower = on_lower + aggregate["on_pf_merged"]
        off_bytes = aggregate["off_read_bytes"] + aggregate["off_write_bytes"]
        on_bytes = aggregate["on_read_bytes"] + aggregate["on_write_bytes"]
        aggregate.update(
            {
                "accuracy": ratio(aggregate["on_useful"], aggregate["on_fills"]),
                "l1_coverage": ratio(off_misses - on_misses, off_misses),
                "lower_coverage": ratio(off_lower - on_lower, off_lower),
                "bandwidth_overhead": ratio(on_bytes - off_bytes, off_bytes),
                "bytes_on_minus_off": on_bytes - off_bytes,
                "cycles_on_minus_off": aggregate["on_replay_service_cycles"]
                - aggregate["off_replay_service_cycles"],
                "cycle_delta_fraction": ratio(
                    aggregate["on_replay_service_cycles"]
                    - aggregate["off_replay_service_cycles"],
                    aggregate["off_replay_service_cycles"],
                ),
                "timeliness": ratio(
                    aggregate["on_timely_useful"],
                    aggregate["on_timely_useful"] + aggregate["on_late_useful"],
                ),
                "harmful_pairs": sum(row["cycle_class"] == "harmful" for row in rows),
                "neutral_pairs": sum(row["cycle_class"] == "neutral" for row in rows),
                "helpful_pairs": sum(row["cycle_class"] == "helpful" for row in rows),
            }
        )
        sidecars_available = all(row["true_l1_help"] is not None for row in rows)
        aggregate["true_pollution_available"] = sidecars_available
        for field in (
            "true_l1_help",
            "true_l1_pollution",
            "true_lower_help",
            "true_lower_pollution",
        ):
            aggregate[field] = sum(int(row[field]) for row in rows) if sidecars_available else None
        if sidecars_available:
            _check_equal(
                f"aggregate {key!r}",
                "L1 miss delta(on-off) = pollution - help",
                on_misses - off_misses,
                aggregate["true_l1_pollution"] - aggregate["true_l1_help"],
            )
            _check_equal(
                f"aggregate {key!r}",
                "required-lower delta(on-off) = pollution - help",
                on_required_lower - off_required_lower,
                aggregate["true_lower_pollution"] - aggregate["true_lower_help"],
            )
        aggregates.append(aggregate)
    return aggregates


def flatten_run(record: RunRecord) -> dict[str, Any]:
    expected = record.expected
    row: dict[str, Any] = {
        "benchmark": expected.benchmark,
        "command": expected.command,
        "window": expected.window,
        "config_id": expected.config_id,
        "trace_id": expected.trace_id,
        "trace_sha256": expected.trace.sha256,
        "log": str(expected.log.path),
        "log_sha256": expected.log.sha256,
        "sidecar": str(expected.sidecar.path) if expected.sidecar else None,
        "sidecar_sha256": expected.sidecar.sha256 if expected.sidecar else None,
        "simulation_binary": str(expected.simulation_binary.path),
        "simulation_binary_sha256": expected.simulation_binary.sha256,
        "simulator_sha256": expected.simulator.sha256,
        "simulation_cwd": str(expected.simulation_cwd),
        "simulation_command_sha256": expected.simulation_command_sha256,
        "timing_profile": expected.timing_profile,
        "cold_warm_mode": expected.cold_warm_mode,
        "prefetch_policy": expected.prefetch_policy,
        "pf_opt_level": expected.pf_opt_level,
        "producer_profile": expected.producer_profile,
        "producer_gap": expected.producer_gap,
        "status": record.strings["status"],
    }
    row.update(record.counters)
    row.update(_metric_fields(record.counters))
    row.update(record.trace_features)
    return row


def _csv_value(value: Any) -> Any:
    if value is None:
        return NA
    if isinstance(value, float):
        return f"{value:.9f}"
    if isinstance(value, bool):
        return "true" if value else "false"
    return value


def write_csv(rows: Sequence[Mapping[str, Any]], path: Path) -> None:
    if not rows:
        raise ValueError(f"cannot write empty CSV {path}")
    fields: list[str] = []
    seen: set[str] = set()
    for row in rows:
        for field in row:
            if field not in seen:
                seen.add(field)
                fields.append(field)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="raise")
        writer.writeheader()
        for row in rows:
            writer.writerow({field: _csv_value(row.get(field)) for field in fields})


def _md_metric(value: Any) -> str:
    if value is None:
        return NA
    if isinstance(value, float):
        return f"{value:.4f}"
    return str(value)


def write_markdown(
    pairs: Sequence[Mapping[str, Any]],
    aggregates: Sequence[Mapping[str, Any]],
    path: Path,
    *,
    validated_runs: int | None = None,
) -> None:
    run_count = len(pairs) * 2 if validated_runs is None else validated_runs
    lines = [
        "# SPEC Replay Paired Analysis",
        "",
        "Validation status: **PASS**",
        "",
        f"Validated {run_count} runs and {len(pairs)} exact prefetch off/on pairs; "
        f"{run_count - len(pairs) * 2} run(s) are standalone capacity controls.",
        "Ratios are computed after summing raw counters; `N/A` denotes a zero "
        "denominator or unavailable paired sidecars.",
        "",
        "## Aggregate results",
        "",
        "| sets | ways | line B | VC | policy/level | producer | timing | pairs | accuracy | L1 coverage | "
        "lower coverage | bandwidth overhead | cycles on-off | harmful / neutral / helpful |",
        "| ---: | ---: | ---: | ---: | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for row in aggregates:
        lines.append(
            f"| {row['sets']} | {row['ways']} | {row['line_bytes']} | {row['victim_entries']} | "
            f"{row['prefetch_policy']}/{row['pf_opt_level']} | "
            f"{row['producer_profile']}:{row['producer_gap']} | "
            f"{row['timing_profile']} | {row['pair_count']} | {_md_metric(row['accuracy'])} | "
            f"{_md_metric(row['l1_coverage'])} | {_md_metric(row['lower_coverage'])} | "
            f"{_md_metric(row['bandwidth_overhead'])} | {row['cycles_on_minus_off']} | "
            f"{row['harmful_pairs']} / {row['neutral_pairs']} / {row['helpful_pairs']} |"
        )

    lines.extend(
        [
            "",
            "## Per-window pairs",
            "",
            "| benchmark | cmd | window | accuracy | L1 coverage | lower coverage | "
            "bytes on-off | cycles on-off | class | L1 help/pollution | "
            "lower help/pollution |",
            "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: |",
        ]
    )
    for row in pairs:
        lines.append(
            f"| {row['benchmark']} | {row['command']} | {row['window']} | "
            f"{_md_metric(row['accuracy'])} | {_md_metric(row['l1_coverage'])} | "
            f"{_md_metric(row['lower_coverage'])} | {row['bytes_on_minus_off']} | "
            f"{row['cycles_on_minus_off']} | {row['cycle_class']} | "
            f"{_md_metric(row['true_l1_help'])}/{_md_metric(row['true_l1_pollution'])} | "
            f"{_md_metric(row['true_lower_help'])}/{_md_metric(row['true_lower_pollution'])} |"
        )
    lines.extend(
        [
            "",
            "## Metric definitions",
            "",
            "- Accuracy is fill accuracy: useful prefetches / all fills, including unused resident fills in the denominator. A merge-only run may therefore report N/A even when every issued PF merges.",
            "- L1 coverage = (baseline misses - prefetch-on misses) / baseline misses.",
            "- `lower_coverage` is the legacy-named reduction in demand-owned lower reads. Under schema 3, add `pf_merged` back before interpreting required physical reads; bandwidth and paired causal help/pollution remain authoritative.",
            "- Bandwidth overhead and cycle deltas are `on - off`; positive cycle delta is harmful.",
            "- True pollution/help compares identical demand identities `(seq, addr, op, size)` in paired sidecars.",
            "- For both L1 misses and lower reads, `delta(on-off) = pollution - help` is a validation invariant.",
            "",
        ]
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def analyze_campaign(
    manifest_path: Path,
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
    dict[str, Any],
]:
    manifest, expected_runs = load_campaign(manifest_path)
    records = [load_run(expected) for expected in expected_runs]
    expected_pair_count = _int(
        manifest["expected_pairs"], "manifest", "expected_pairs"
    )
    pairs = pair_runs(
        records,
        expected_pairs=expected_pair_count,
        paired_config_ids=set(manifest["paired_config_ids"]),
        standalone_config_ids=set(manifest["standalone_config_ids"]),
    )
    if "actual_pairs" in manifest and _int(
        manifest["actual_pairs"], "manifest", "actual_pairs"
    ) != len(pairs):
        _fail("manifest", "actual_pairs does not match validated pair count")
    aggregates = aggregate_pairs(pairs)
    missing_sidecars = sum(pair["true_l1_help"] is None for pair in pairs)
    if manifest["require_sidecars"] and missing_sidecars:
        _fail("campaign", "required paired sidecars are missing")
    validation = {
        "schema": 3,
        "status": "PASS",
        "manifest": str(manifest_path.resolve()),
        "manifest_sha256": _sha256(manifest_path.resolve()),
        "campaign_schema": manifest["schema"],
        "expected_runs": _int(manifest["expected_runs"], "manifest", "expected_runs"),
        "validated_runs": len(records),
        "expected_pairs": expected_pair_count,
        "validated_pairs": len(pairs),
        "pairs_without_sidecars": missing_sidecars,
        "checks": {
            "manifest_expected_matrix_complete": True,
            "workload_result_schema_2_or_3": True,
            "sidecar_schema_2_or_3": True,
            "artifact_hashes": True,
            "geometry_and_timing_pairing": True,
            "counter_conservation": True,
            "status_and_protocol": True,
            "sidecar_identity_and_delta": missing_sidecars == 0,
        },
        "warnings": (
            []
            if missing_sidecars == 0
            else [f"{missing_sidecars} pair(s) have no sidecars; true help/pollution is N/A"]
        ),
    }
    return [flatten_run(record) for record in records], pairs, aggregates, validation


def _output_paths(args: argparse.Namespace) -> dict[str, Path]:
    out_dir = args.out_dir
    return {
        "runs": args.runs_csv or out_dir / "runs.csv",
        "pairs": args.pairs_csv or out_dir / "pairs.csv",
        "aggregate": args.aggregate_csv or out_dir / "aggregate.csv",
        "markdown": args.markdown or out_dir / "summary.md",
        "classification": args.classification_csv or out_dir / "classification.csv",
        "cycles_svg": args.cycles_svg or out_dir / "cycles-on-minus-off.svg",
        "validation": args.validation or out_dir / "validation.json",
    }


def _validate_output_paths(paths: Mapping[str, Path]) -> None:
    names_by_path: dict[Path, list[str]] = defaultdict(list)
    for name, path in paths.items():
        names_by_path[path.resolve()].append(name)
    aliases = {
        resolved: names
        for resolved, names in names_by_path.items()
        if len(names) > 1
    }
    if aliases:
        details = "; ".join(
            f"{','.join(sorted(names))}={resolved}"
            for resolved, names in sorted(
                aliases.items(), key=lambda item: str(item[0])
            )
        )
        raise ValidationError(f"output paths alias after resolve: {details}")


def _remove_output_paths(
    paths: Mapping[str, Path], *, include_validation: bool
) -> list[str]:
    """Attempt every removal so one bad target cannot preserve stale evidence."""

    findings: list[str] = []
    for name, path in paths.items():
        if name == "validation" and not include_validation:
            continue
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:
            findings.append(f"could not remove output {name}={path}: {exc}")
    return findings


def _write_failure_validation(
    path: Path, manifest: Path, error: str
) -> None:
    failure = {
        "schema": 2,
        "status": "FAIL",
        "manifest": str(manifest.resolve()),
        "error": error,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(failure, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _report_failure(
    paths: Mapping[str, Path], manifest: Path, error: str
) -> int:
    try:
        _write_failure_validation(paths["validation"], manifest, error)
    except (OSError, UnicodeError, ValueError) as write_error:
        print(
            f"validation failed: {error}; could not write FAIL validation: "
            f"{write_error}",
            file=sys.stderr,
        )
        return 2
    print(f"validation failed: {error}", file=sys.stderr)
    return 2


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True, help="schema-v2 replay campaign JSON")
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--runs-csv", type=Path)
    parser.add_argument("--pairs-csv", type=Path)
    parser.add_argument("--aggregate-csv", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--classification-csv", type=Path)
    parser.add_argument("--cycles-svg", type=Path)
    parser.add_argument("--validation", type=Path)
    args = parser.parse_args(argv)
    paths = _output_paths(args)
    preflight_errors: list[str] = []
    try:
        _validate_output_paths(paths)
    except (OSError, RuntimeError, ValidationError) as exc:
        preflight_errors.append(str(exc))
    # A failed validation must never leave a previous PASS artifact set in
    # place.  Attempt every target even when an earlier removal fails.
    preflight_errors.extend(
        _remove_output_paths(paths, include_validation=True)
    )
    if preflight_errors:
        return _report_failure(paths, args.manifest, "; ".join(preflight_errors))

    try:
        runs, pairs, aggregates, validation = analyze_campaign(args.manifest)
        write_csv(runs, paths["runs"])
        write_csv(pairs, paths["pairs"])
        write_csv(aggregates, paths["aggregate"])
        write_markdown(
            pairs,
            aggregates,
            paths["markdown"],
            validated_runs=len(runs),
        )
        write_plot_outputs(
            pairs,
            paths["classification"],
            paths["cycles_svg"],
        )
        validation["outputs"] = {name: str(path.resolve()) for name, path in paths.items() if name != "validation"}
        paths["validation"].parent.mkdir(parents=True, exist_ok=True)
        paths["validation"].write_text(json.dumps(validation, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (OSError, UnicodeError, ValidationError, ValueError) as exc:
        cleanup_errors = _remove_output_paths(
            paths, include_validation=False
        )
        error = str(exc)
        if cleanup_errors:
            error = "; ".join([error, *cleanup_errors])
        return _report_failure(paths, args.manifest, error)
    print(
        f"validated {validation['validated_runs']} runs / {validation['validated_pairs']} pairs; "
        f"wrote {paths['runs']}, {paths['pairs']}, {paths['aggregate']}, "
        f"{paths['markdown']}, {paths['classification']}, {paths['cycles_svg']}, "
        f"and {paths['validation']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
