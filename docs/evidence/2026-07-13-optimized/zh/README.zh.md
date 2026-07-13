# 自适应 Direct-L1 Prefetch 证据（2026-07-13）

英文 `../README.md` 是权威版本。本目录发布最终 25-window、
125,511-demand、zero-bubble campaign 的无地址结果。获许可 trace、逐 demand
sidecar、simulation log、binary 和私有 manifest 仍保存在被忽略的
`build/spec2026/` 路径下。

四个 campaign 均验证了 100 个 run、25 个精确 off/on pair 和 50 个独立
capacity control。每个 paired comparison 使用 2 way、4 set、16-byte line 与
4-entry victim cache；下级内存 read latency 为 2，带 periodic ready backpressure。

| Policy | Cycle delta | Byte overhead | Harmful / neutral / helpful | PF issue | Merge | Install | PF-caused WB |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| 冻结 legacy（`0/0`） | 0 | 0 | 0 / 25 / 0 | 0 | 0 | 0 | 0 |
| Safe next-line P1（`1/1`） | 0 | 0 | 0 / 25 / 0 | 0 | 0 | 0 | 0 |
| Adaptive stream P2（`1/2`） | 0 | 0 | 0 / 25 / 0 | 0 | 0 | 0 | 0 |
| Shadow + PF MSHR P3（`1/3`） | **-724** | **0** | **0 / 7 / 18** | 544 | 544 | 0 | 0 |

P3 将 demand-owned read 从 59,275 降到 58,731，同时发出 544 个同地址
prefetch read，因此总 read/write byte 与 optimized-off 完全相同。25 个 window
全部不退化；最佳 window 节省 80 cycles，最差 delta 为零。该结果在本
timing profile 下通过 cycle、bandwidth、逐 window、slowdown、dirty write-back
和 legacy comparison 主门槛。

`../aggregate.csv` 是精简的公开汇总；`../classification.csv` 在不公开地址的
情况下发布每个 P3 window 的 cycle classification；`../provenance.json` 通过
SHA-256 将这些公开记录与私有的已验证 campaign/analyzer artifact 绑定。

`../sensitivity.csv` 发布 14 条 legacy/P3 sensitivity aggregate。7 组 profile pair
全部通过。在 latency-2/periodic-ready 下，P3 对 sequential 和 fixed-gap
1/2/4/8 全部为 neutral，而 legacy 同时增加 cycles 和 672,032 bytes，因此
P3 对两项指标均严格改善。在 zero-bubble latency-0/always-ready 和
latency-8/deterministic-random-ready 下，P3 分别节省 570 和 859 cycles，
但 legacy 和 P3 的 byte overhead 均为零。因此，这两个 timing 结果是
cycle 改善、bandwidth 持平（Pareto/non-regressing），而不是 bandwidth 严格
降低。Latency-8 结果中有一个 +71-cycle（+0.1282%）harmful window，
但 aggregate 仍节省 859 cycles。完整本地测试和 gate 记录见
`../validation.md`。

全部 650 条 schema-3 主结果/sensitivity run row 都封闭了 admission lifecycle：
每个 admission 在报告前均已 issue 或 cancel，每个 issue 均 return 到唯一的
install、merge 或 discard outcome。

## 远程 XSim 与综合证据

最终 Vivado 2024.2.1 运行生成了 `PASS` manifest，且没有 finding。
11 个 simulation log 由 8 个 workload configuration 和 3 个定向辅助 top
组成。83 条 workload row 全部为 schema 3，均报告 `PASS` 并通过了
排空后的 optimized-prefetch lifecycle 校验。4 个 synthesis configuration
生成了预期的全部 12 份 utilization、timing 和 power report。去敏的
公开 manifest 为
[`../../vivado-2026-07-13-optimized.json`](../../vivado-2026-07-13-optimized.json)，
提取后的指标位于 [`../vivado-ppa.csv`](../vivado-ppa.csv)。

| Configuration | LUT | LUT memory | Register | BRAM | WNS (ns) | 估算 Fmax (MHz) | Power (W) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `dm_s8_vc4_pf0` | 5,679 | 57 | 2,897 | 2 | -1.019 | 90.752 | 0.124 |
| `2w_s4_vc4_pf0` | 7,137 | 372 | 3,214 | 0 | -2.130 | 82.440 | 0.125 |
| `2w_s4_vc8_pf0` | 7,891 | 372 | 4,227 | 0 | -2.500 | 80.000 | 0.128 |
| `2w_s4_vc4_pf1` | 10,882 | 372 | 4,757 | 0 | -9.342 | 51.701 | 0.139 |

与几何一致的 optimized-off `2w_s4_vc4_pf0` 对比点相比，P3 增加
3,745 个 LUT（+52.473%）和 1,543 个 register（+48.009%），LUT memory
和 BRAM 没有增加。WNS 恶化 7.212 ns，估算 Fmax 降低 30.739 MHz
（-37.287%），估算总功耗增加 0.014 W（+11.2%）。这些代价表明，
功能验证成功的 P3 policy 在支持 100 MHz implementation 声明之前，仍需
优化 datapath 和 control。

## PPA 局限

这些数值是 `xc7a35tcpg236-1` 在 10 ns clock 约束下仅综合、未布局的
估算。4 个 configuration 均未通过 100 MHz setup timing，但 hold timing
均通过。`估算 Fmax` 只是根据 slack 计算的近似值
`1000 / (10 - WNS)`，不是 post-route 实际达到的频率。该研究 top 还存在
I/O delay 不完整且 bonded-I/O 需求超过目标器件的情况，因此 timing
report 不是 board sign-off 证据。Power 没有使用 simulation activity file，
Vivado 将所有估算标记为 `Low` confidence。因此，PPA 表只是用于
对比的研究快照；它不会覆盖本地 cycle/bandwidth gate，也不能证明
timing closure、布线后资源使用或实测功耗。
