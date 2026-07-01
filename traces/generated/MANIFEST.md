# Phase 3 Generated Trace Manifest

These traces are deterministic, redistributable cache-interface samples.
They are not licensed SPEC traces.

| Trace | Lines | SHA-256 | Generator |
| --- | ---: | --- | --- |
| `phase3_matrix_row_major.trace` | 64 | `400ed1afb8775561e46c10856461fffa13b5bbc6a0ab57f33887d9b8c06f0445` | `scripts/generate_phase3_traces.py` |
| `phase3_matrix_column_major.trace` | 64 | `ae8a522c6c87328ba93c4472ab37fbffa20daacbdbf00c211d1a6e99ca74c8bf` | `scripts/generate_phase3_traces.py` |
| `phase3_pointer_permutation.trace` | 64 | `5c8039c1e6a8f40d376fa2787a6ce85378ab07bcae8e115a51a980206ee50d08` | `scripts/generate_phase3_traces.py` |
| `phase3_pointer_mixed_update.trace` | 64 | `7e52cd734e4f9a36f7e30c4bef858853e0be15bb213fabebecca782ae6033c0e` | `scripts/generate_phase3_traces.py` |

Replay with the class-based Vivado harness using:

```text
+TRACE=traces/generated/<trace-name>
```

Regenerate from the repository root with:

```bash
scripts/generate_phase3_traces.py
```
