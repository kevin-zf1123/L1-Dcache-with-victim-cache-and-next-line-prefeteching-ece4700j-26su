# Prefetch 与 PPA 收尾证据（2026-07-22）

本目录是 7 月 22 日 replay、sensitivity、synthesis、implementation、timing
和 power 收尾结果的公开无地址汇总。英文
[`../README.md`](../README.md) 为权威版本；本文是面向读者的忠实中文译本。

## 决策

综合门禁决策为 `DISABLE_DEPLOY_PREFETCH_STRUCTURAL_LIMIT`。因此部署 wrapper
默认保持 `ENABLE_PREFETCH=0`。Full P3 与 P3-lite 继续作为研究 profile，只有在
elaboration 时显式选择才会启用。

这是经过测量得到的负面结论，不是验证失败。所有 replay campaign 和 Vivado
证据 manifest 都通过完整性检查；未通过的是设计要求的性能、面积、setup
timing、功耗和按实际频率折算的执行时间门禁。

## 主 Replay 结果

所有行均使用相同的 25 个可归因 window、2-way/4-set/16-byte-line/VC4
geometry、真正的 zero-bubble producer，以及 latency-2、periodic-ready 内存模型。

| 变体 | Off cycles | On cycles | Delta | Byte overhead | Harmful / neutral / helpful | Issued / merged / installed |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| legacy | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| P1 | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| P2 | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| full P3 | 850,547 | 850,546 | -1 | 0% | 4 / 16 / 5 | 508 / 508 / 0 |
| P3-lite | 850,547 | 850,578 | +31 | 0% | 9 / 8 / 8 | 1,301 / 1,301 / 0 |

P3-lite 的 aggregate replay 慢 0.0036447%，non-slow window 为 16/25。它通过
bandwidth、单 window 最大 slowdown 和 attributed write-back 门禁，但未达到
aggregate 至少改善 1% 以及至少 20/25 non-slow window 的要求。参数 sweep 也
没有扭转结论：最佳点 `PF_ON_REFILL=16` 仍增加 17 cycle。

Sensitivity 明确了结构边界。冻结的 legacy policy 在 sequential/fixed-gap
producer 下激进 issue 并 install，最多增加 33.66% cycle 和 53.80% byte。
P3-lite 抑制全部不安全的 sequential/gap-1/gap-2 工作，并在 issue 前取消已
admit 的 gap-4/gap-8 工作。在 zero-bubble timing profile 下，它仍为 neutral
或略慢，且从未 install prefetch line。

## Vivado 结果

Vivado 2024.2.1 以 `xc7a35tcpg236-1` 和 10 ns 时钟为目标。证据 manifest
验证了 15 份 XSim log、8 个 OOC synthesis 配置、4 个独立 post-route
implementation、SAIF activity、全部必需报告和 121 个下载的 log/report
文件，finding 为零。

| 门禁指标 | Optimized PF0 | P3-lite | Delta / 结果 | 门禁 |
| --- | ---: | ---: | ---: | --- |
| OOC slice LUT | 6,048 | 10,055 | +66.253% | 失败（`<=15%`） |
| OOC register | 2,047 | 3,095 | +51.197% | 失败（`<=15%`） |
| OOC WNS | +0.363 ns | -5.896 ns | -6.259 ns | 失败（`>=0`） |
| post-route WNS | -0.407 ns | -4.169 ns | -3.762 ns | 失败（`>=0`） |
| post-route WHS | +0.118 ns | +0.065 ns | hold clean | 通过 |
| activity dynamic power | 0.008 W | 0.015 W | +87.5% | 失败（`<=10%`） |
| achieved-Fmax time proxy | — | — | -36.154% | 失败（`>0%`） |

四个 post-route implementation 都有非负 hold slack，且没有 unconstrained
path。PF0 和 legacy 已无法闭合 setup，而 P3 与 P3-lite 明显更差。Stream
detector 占据大部分新增逻辑与关键路径；只移除 adaptive 和 shadow 逻辑，不足以
在不改变接口或架构的前提下达到部署门禁。

## 文件

- [`../aggregate.csv`](../aggregate.csv)：5 个主 replay 变体。
- [`../pairs.csv`](../pairs.csv) 与
  [`../classification.csv`](../classification.csv)：精确 P3-lite off/on window
  及 helpful/neutral/harmful 标签。
- [`../sweep.csv`](../sweep.csv)：P3-lite controller 参数 sweep。
- [`../sensitivity.csv`](../sensitivity.csv)：legacy 与 P3-lite producer/timing
  sensitivity matrix。
- [`../vivado-ppa.csv`](../vivado-ppa.csv)：OOC 与 post-route 面积、时序和
  vectorless/activity power 指标。
- [`../gate-result.json`](../gate-result.json)：脱敏、机器可读的门禁决策。
- [`../provenance.json`](../provenance.json)：公开 artifact 与私有 source hash，
  不包含许可 trace、地址、凭据或私有路径。
- [`validation.zh.md`](validation.zh.md)：验证命令与结果。

许可 trace、raw sidecar、simulator log、checkpoint、VCD/SAIF 和私有 Vivado
manifest 继续留在被忽略的 build directory 中。本目录的 CSV/JSON 不包含 replay
地址或本地/远程主机路径。
