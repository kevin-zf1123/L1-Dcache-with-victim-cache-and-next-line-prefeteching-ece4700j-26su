# Optimized Prefetcher 验证记录

英文 `../validation.md` 为权威版本。全部命令于 2026-07-13 在仓库根目录
运行。获许可的 trace、log、sidecar、binary 和完整 manifest 仍保存在被忽略的
私有 build tree 中。

## 本地功能验证

- `scripts/run_iverilog.sh`：10 个 cache simulation 报告 `ALL TESTS PASSED`；
  20/20 个 workload record通过；内含的 76-check prefetch-unit suite 通过。
- `scripts/run_p3_tests.sh`：62 个定向 PF-MSHR check、10 个 optimized edge
  scenario 和真正的 zero-bubble issue/merge replay 通过。
- `scripts/run_prefetch_unit_tests.sh`：76 个 stream/controller check 通过。
- `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`：82 个测试通过。
- Shell 语法检查、Python byte-code 编译和 `git diff --check` 通过。

Icarus 仅输出已知的 constant-select/unpacked-array sensitivity 以及 testbench
`$fatal` synthesis diagnostic。没有测试输出功能性 `FAIL`、`FATAL`、protocol、
watchdog、duplicate-line 或 conservation failure。

## Replay 门槛

主 P3 profile 通过 100/100 个 run 和 25/25 个精确 pair：aggregate cycle delta
为 -724，byte overhead 为零，25/25 个 window 不退化，最大 slowdown 为零，
prefetch-caused write-back 为零。7 组 sensitivity profile pair 另外通过 700 个
run 和 350 个精确 pair。P3 aggregate cycle delta 从未为正，byte overhead
始终为零。对 latency-2/periodic-ready 的 sequential 和 fixed-gap profile，
legacy 增加了 cycles 和 672,032 bytes，而 P3 两者均未增加，因此两项指标
都严格改善。对 zero-bubble latency-0/always-ready 和
latency-8/deterministic-random-ready，legacy 和 P3 的 byte overhead 均为零；
P3 节省 570 和 859 cycles，因此是 cycle 严格改善但 bandwidth 持平
（Pareto/non-regressing），而不是 bandwidth 严格改善。唯一的 harmful
sensitivity window 出现在 latency-8 确定性 random ready，为 +71 cycles
（+0.1282%），低于 5% guardrail；该 profile 整体节省 859 cycles。
在 650 条 schema-3 主结果/sensitivity row 中，没有 run 留下 orphan
admission、未 return issue、未匹配 response outcome 或终止时仍有效的 PF MSHR。

## 远程 XSim 封闭了 optimized 矩阵

最终远程 Vivado 2024.2.1 执行于 `2026-07-13T06:58:25.192439Z` 生成
`PASS` 私有 manifest，finding 为空、exit status 为零、没有 download failure，
且启用了下载 log 扫描。私有 manifest 的 SHA-256 为
`8a603dcff120f15114370e7556dd84d33e8bd9fc4028375d5ddedc97685e10cd`；
公开派生版删除了 execution command 和绝对 launcher path，但保留了相对
artifact path 和 hash。

- 11 个 simulation log 通过：8 个 workload configuration，加上
  stream/controller、PF-MSHR 和 optimized-edge 辅助 top。
- Workload log 中恰好包含 83 条 schema-3 `WORKLOAD_RESULT` row。
  每个预期 workload 只出现一次，每条 row 均报告 `PASS`，并通过
  admission、issue/return、response-outcome、install-residency、零 prefetch
  write-back 和终止时 MSHR 为空的校验。
- 4 个 synthesis configuration 按请求的参数绑定完成，并生成了 12/12 份
  预期 utilization、timing 和 power report。
- 必需的 optimized VCD 存在（901,858 bytes）。最终扫描没有发现功能性
  `FAIL`、`FATAL`、`ERROR` 或 `CRITICAL WARNING` 标记。

## 综合 PPA 暴露了 timing 代价

综合目标为 `xc7a35tcpg236-1`，clock 约束为 10 ns。下表数值直接来自
最终的 report triplet；估算 Fmax 为 `1000 / (10 - WNS)`，仅用于对比。

| Configuration | LUT | LUT memory | Register | BRAM | WNS / TNS (ns) | 估算 Fmax (MHz) | 总 / 动态 / 静态功耗 (W) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `dm_s8_vc4_pf0` | 5,679 | 57 | 2,897 | 2 | -1.019 / -45.732 | 90.752 | 0.124 / 0.053 / 0.070 |
| `2w_s4_vc4_pf0` | 7,137 | 372 | 3,214 | 0 | -2.130 / -101.115 | 82.440 | 0.125 / 0.055 / 0.070 |
| `2w_s4_vc8_pf0` | 7,891 | 372 | 4,227 | 0 | -2.500 / -139.521 | 80.000 | 0.128 / 0.058 / 0.070 |
| `2w_s4_vc4_pf1` | 10,882 | 372 | 4,757 | 0 | -9.342 / -2,571.288 | 51.701 | 0.139 / 0.068 / 0.070 |

对于匹配的 2 way、4 set、VC4 对比，启用 P3 增加 3,745 个 LUT
（+52.473%）和 1,543 个 register（+48.009%）；LUT memory 和 BRAM
没有增加。WNS 变化 -7.212 ns，TNS 变化 -2,470.173 ns，估算 Fmax
变化 -30.739 MHz（-37.287%）。估算总功耗增加 0.014 W（+11.2%），
动态功耗增加 0.013 W（+23.636%）；静态功耗保持为 0.070 W。

## PPA 解读局限

4 个对比点均未通过 100 MHz setup timing，hold timing 均通过。这些 report
来自已综合、未布局的 netlist，而不是 `opt_design`/place/route 结果，因此
Fmax 是根据 slack 估算的值，而不是实际达到的频率。3 个 prefetch-off
top 分别有 265 个 input 和 753 个 output 没有 I/O delay；prefetch-on top
对应为 328 和 1,141。Prefetch-off 的 bonded-I/O 需求为 1,447/106，
prefetch-on 为 1,510/106，这反映的是研究测量 top，而不是符合板级引脚现实的
wrapper。Report triplet 中 combinational loop 为零，且没有 literal
multiple-driver diagnostic，但这些观察本身并不是 driver 唯一性的形式化证明。
Vivado 未使用 simulation activity file，并将每个功耗估算标记为 `Low`
confidence。因此，这些结果只支持相对研究比较，不支持 100 MHz timing
closure、post-route utilization、板级可行性或实测功耗声明。
