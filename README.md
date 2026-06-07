# L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su
Design and Evaluation of a High-Performance L1 Data Cache with Victim Cache and Next-Line Prefetching

This repository currently includes a parameterizable SystemVerilog outline for an L1 data cache in [rtl/l1_dcache.sv](rtl/l1_dcache.sv). The design is structured as a set-associative cache with configurable sets, ways, line size, and data width, plus optional victim-cache support and next-line prefetch hooks.

The module provides a basic CPU-side request/response interface, a backing-memory refill interface, cache tag/data arrays, replacement state, and an FSM scaffold for hit handling, miss refill, and writeback flow. It is intended as a starting point for completing the full cache policy and verification environment.
