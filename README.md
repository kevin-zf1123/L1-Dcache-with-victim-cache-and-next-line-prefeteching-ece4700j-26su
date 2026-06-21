# L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su
Design and Evaluation of a High-Performance L1 Data Cache with Victim Cache and Next-Line Prefetching

Current RTL refactor status is documented in [docs/l1d_baseline.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/l1d_baseline.md). The cache has been decomposed into dedicated request-arbiter, controller, lookup, array-bank, victim-cache, and shared-package files while keeping `bash scripts/run_iverilog.sh` passing as the baseline regression checkpoint.
