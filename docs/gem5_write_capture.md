# gem5 Write Capture

This project uses a text-based intermediate trace for memory-access capture:

```text
tick op addr size wstrb data [pc]
```

- `op` is `w` for store records and `r` for captured load records.
- `addr` is the byte address of the committed store.
- `size` is the byte count of the original store fragment.
- `wstrb` is a byte-enable mask, least-significant bit = lowest addressed byte.
- `data` is hex bytes in little-endian order.

The replay converter in `scripts/convert_gem5_write_trace.py` splits records on
32-bit boundaries and emits the existing RTL trace format used by
`tb_l1d_cache.sv`. Pass `--allow-reads` when converting mixed traces.

Important constraint:

- stock gem5 packet traces do not include store payload bytes;
- the trace hook therefore has to be a gem5-side logger attached at or above
  the LSQ completion path, where store payload bytes and byte enables are still
  available.

The recommended workflow is:

1. run gem5 with the repo-local capture config;
2. collect the ASCII read/write trace;
3. convert it with `scripts/convert_gem5_write_trace.py --allow-reads`;
4. replay the converted file with `vvp sim/two_way_vc4.vvp +TRACE=...`.
