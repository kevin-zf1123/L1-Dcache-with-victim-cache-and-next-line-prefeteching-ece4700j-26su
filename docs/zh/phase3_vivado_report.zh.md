# Phase 3 Vivado 验证报告

英文 `docs/phase3_vivado_report.md` 是权威版本。

## 部署收尾（2026-07-22）

本节取代 7 月 13 日的 performance 和 PPA 结论，但保留后文旧证据作为历史。
当前部署 profile 为 `l1d_cache_deploy`，默认 `ENABLE_PREFETCH=0`。Full P3
和 P3-lite 是必须显式选择的研究配置，不是默认值。

### 正确性与证据完整性

收尾工作在测量前先修复了 prefetch lifecycle：

- controller token/cost 只在 PF 下级内存请求真正 handshake 时计费；
- late merge 获得 causal shadow credit，而不是 timing proxy；
- runtime disable 之后返回的 response 会被 discard，不会 install；
- candidate address/generation snapshot 在 FIFO head 切换时保持稳定，且同一个
  edge 先记录 suppression 再 cancellation，使每个 sidecar event 保留正确 sequence
  identity；
- PF scheduler 使用注册化 S0 capture/S1 issue，request valid 和 address 可在任意
  下级内存 backpressure 期间保持稳定；
- 显式 lower-port ownership grant 避免将 state-owned demand read 或 write-back
  错误分类并计费为 PF handshake。

精确的 5,028-access sqlite gap-4 复现通过：1,425 个 candidate、1,425 次
admission/cancellation、1,033 次 unsafe suppression 和 392 次 same-line coalesce。
随后，完整单通道 matrix 以 `MATRIX_ALL_PASS` 结束：26 个 campaign 全部重新执行。
每个 campaign 验证 50 run/25 个精确 pair；full P3
还包含 standalone geometry control，共 100 run/25 pair。没有任何 run 报告 watchdog、
protocol、duplicate-line 或 lifecycle-conservation failure。

### Replay 结论

| 变体 | Off cycles | On cycles | Delta | Byte overhead | Harmful / neutral / helpful | Issued / merged / installed |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| legacy | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| P1 | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| P2 | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| full P3 | 850,547 | 850,546 | -1 | 0% | 4 / 16 / 5 | 508 / 508 / 0 |
| P3-lite | 850,547 | 850,578 | +31 | 0% | 9 / 8 / 8 | 1,301 / 1,301 / 0 |

Full P3 的 0.000118% improvement 和 P3-lite 的 0.003645% slowdown 都未达到
1% 要求。P3-lite 只有 16/25 non-slow window，低于 20/25 门禁。它通过了
零 bandwidth overhead、单 window 最大 slowdown 和零 PF-caused write-back 门禁。
调参不改变决策：最佳 `PF_ON_REFILL=16` sweep 点仍增加 17 cycle。

Sensitivity 说明不能只依赖一种 main timing model。Legacy prefetch 在 sequential 和
fixed-gap 1/2/4/8 producer 下分别增加 33.66%、33.66%、25.48%、14.10% 和
0.74% cycle，byte overhead 为 53.80%。P3-lite 安全 suppress 或 cancel 这些机会，
保持 byte-neutral，但没有 improvement。Zero-bubble latency 0 下为 neutral；latency 8
下，periodic ready 增加 9 cycle，deterministic-random ready 增加 146 cycle。

### OOC Synthesis 与结构归因

除显式标记 legacy top 的行外，所有配置均使用 2-way、4-set、16-byte line、
VC4 和同一部署 seam。

| 配置 | LUT | FF | 10 ns WNS | Vectorless dynamic |
| --- | ---: | ---: | ---: | ---: |
| `optimized_pf0_deploy`（VC swap format） | 6,048 | 2,047 | +0.363 ns | 0.023 W |
| `optimized_pf0_deploy_vc_lookup` | 5,647 | 2,034 | -0.675 ns | 0.015 W |
| `p3_research` | 9,740 | 4,817 | -5.186 ns | 0.044 W |
| `p3_deploy` | 9,488 | 3,928 | -5.404 ns | 0.042 W |
| `p3_no_shadow_proxy` | 9,048 | 3,161 | -6.123 ns | 0.042 W |
| `p3_lite_mshr_fixed` | 10,055 | 3,095 | -5.896 ns | 0.040 W |
| `stream_detector_only` | 7,302 | 2,549 | -5.688 ns | 0.021 W |
| `legacy_matched` | 5,349 | 2,074 | -2.007 ns | 0.014 W |

`VC_FORMAT_IN_SWAP=1` 比 lookup-stage format 多 401 LUT 和 13 register，但 WNS 改善
1.038 ns，且是唯一满足 10 ns OOC setup 约束的 PF0 变体，因此保留。

Hierarchical OOC utilization 隔离出主要 speculative 结构：

| 配置 / module | LUT | FF |
| --- | ---: | ---: |
| P3 deploy controller | 264 | 73 |
| P3 deploy shadow | 368 | 741 |
| P3 deploy stream detector | 1,006 | 414 |
| P3-lite controller | 8 | 5 |
| P3-lite stream detector | 977 | 414 |
| stream-only controller | 6 | 5 |
| stream-only detector | 882 | 414 |

Constant folding 在 P3-lite 中移除了几乎全部 controller 和 shadow state，但面积和
WNS 仍远超门禁。因此，在当前接口下，stream detector 和 candidate 逻辑是结构
限制，而不是参数调整问题。

### 独立 Post-route Implementation 与 Activity Power

标量 I/O FPGA harness 消除了先前 raw-cache I/O top 无法放置的问题。每行都在
10 ns 时钟下独立 synthesis、place 和 route；SAIF 由匹配的 deploy-profile simulation 生成。

| 配置 | LUT | FF | WNS | WHS | Activity dynamic | Matched nets |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `optimized_pf0_deploy` | 751 | 748 | -0.407 ns | +0.118 ns | 0.008 W | 128 / 1,646 |
| `p3_deploy` | 3,593 | 3,146 | -3.721 ns | +0.019 ns | 0.020 W | 565 / 7,525 |
| `p3_lite_mshr_fixed` | 2,955 | 2,280 | -4.169 ns | +0.065 ns | 0.015 W | 575 / 5,804 |
| `legacy_matched` | 1,259 | 1,411 | -0.444 ns | +0.106 ns | 0.008 W | 488 / 2,956 |

四行的 hold 都满足要求，unconstrained path 都为零，但 setup 全部失败。相对 PF0，
P3-lite 增加 66.25% OOC LUT、51.20% OOC FF 和 87.5% activity dynamic power，
并得到 -36.154% 的 achieved-Fmax execution-time proxy。因此硬件门禁中只有 hold 和
constraint completeness 通过。

最终远程执行退出状态为 0。`l1d-vivado-evidence-v3` manifest 验证了
15 份 XSim log、8 个 OOC synthesis、4 个 implementation、必需 VCD/SAIF/checkpoint/report
artifact 和 121 个下载的 log/report，finding 为零。综合 evaluator 决策是
`DISABLE_DEPLOY_PREFETCH_STRUCTURAL_LIMIT`；设计门禁失败是实验结果，不是
collector failure。公开无地址证据位于
[`../evidence/2026-07-22-prefetch-ppa/`](../evidence/2026-07-22-prefetch-ppa/README.md)。

## 历史证据状态（2026-07-13）

下文 2026-07-01 simulation/PPA 与 SPEC 表格属于历史结果。Simulation 使用
`NUM_SETS=4`，而 synthesis 静默采用 RTL 默认 `NUM_SETS=8`；direct-mapped 与
two-way replay 还同时改变了 L1 capacity。SPEC trace 是全系统多 vCPU capture，
不能归因到所标 benchmark。这些表格不能用于受控 associativity、benchmark 或
最终 PPA 结论。替代证据必须由 Icarus、XSim、synthesis、timing 和 power 共用
一份显式完整 geometry record。

当前替代证据已满足该规则。无旧报告混入的 Vivado 运行，以及私有、
可归因到进程的 SPEC capture/replay/analyzer 证据链均为 `PASS`。
历史表格仍然无效，仅作历史记录。

## 历史 Optimized P3 验证状态（2026-07-13）

自适应 direct-L1 实现已通过本地 Icarus matrix、定向 P3 回归、真正的
zero-bubble replay 和 82 个 Python analyzer/runner 测试。Vivado 流程已升级为
使用 `PREFETCH_POLICY=1`、`PF_OPT_LEVEL=3` 编译 wrapper，验证 schema-3
record，运行 8 个 OOP workload point 加 3 个定向 auxiliary XSim top，
并综合 4 个受控 geometry。

最终本地主 profile replay 中，legacy、P1、P2 和 P3 每组均通过 100/100
runs 与 25/25 精确 pair。P3 将 aggregate cycles 从 850,547 降至 849,823
（`-724`），总 byte 不变，18 个 helpful、7 个 neutral、零 harmful window，
544 个 issued prefetch 全部 merge，且不引发 dirty write-back。公开汇总见
[optimized 证据](../evidence/2026-07-13-optimized/README.md)。

Sequential、fixed-gap 1/2/4/8、latency-0/always-ready 和
latency-8/deterministic-random sensitivity campaign 也全部通过，共 700 个
run 和 350 个精确 pair。P3 在每个 profile 中的 byte overhead 都为零；
在全部 sequential/fixed-gap window 中为 neutral，在 latency-0 和 latency-8
zero-bubble profile 中分别节省 570 和 859 aggregate cycles。最终本地
regression 包括 10 个 cache simulation、20/20 个 workload row、62 个 P3 MSHR
check、10 个 optimized edge scenario、76 个 stream/controller check 和 82 个
Python test，全部通过。

Optimized 远程 campaign 也报告 `PASS`。Vivado 2024.2.1 生成了
11 份 XSim log：8 个 class-based OOP workload point 和 3 个定向
auxiliary top。8 份 OOP log 共包含 83 行 `WORKLOAD_RESULT schema=3`；
每一行都报告 `status=PASS`、watchdog/protocol/duplicate-line error 为零，
且在 drain 时 candidate/admit/issue/return/install/merge/discard/cancel 生命周期
守恒全部闭合。Auxiliary log 显示 76 个 stream/controller check、62 个
PF-MSHR check 与 optimized P3 edge scenario 全部通过。同一次运行
综合了 4 个受控配置，并下载了预期的全部 12 份
utilization/timing/power report。Evidence manifest 生成于
`2026-07-13T06:58:25.192439Z`，状态为 `PASS` 且无 finding，记录远程
退出状态为 0、无下载失败，并对 Vivado log、journal 和一份
901,858-byte 代表性 VCD 记录了哈希。此处 `PASS` 表示 simulation、
lifecycle、流程完成与 artifact 验证通过；它不表示 100 MHz timing
约束已闭合。

OOP workload matrix 使用 sequential producer；它是功能与生命周期证据，
而非 zero-bubble 性能测量。真正的 zero-bubble 行为由定向
`tb_l1d_cache_optimized_p3` 测试在 Icarus 与 XSim 中跨仿真器验证
（远程 matrix 中的 `p3_prefetch_edges`）。上述性能结论仍来自本地
真正 zero-bubble 的 25-window trace campaign，而不是 sequential OOP row。

4 个 optimized-wrapper 配置的逻辑 L1 data capacity 均为 128 bytes。
当前综合后报告如下：

| 配置 | Slice LUT | LUT as memory | FF | Block RAM tile | Bonded IOB / 可用数 | 10 ns 下 WNS | 近似 Fmax | Vectorless power | Dynamic | Static |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `dm_s8_vc4_pf0` | 5,679 | 57 | 2,897 | 2 | 1,447 / 106 | -1.019 ns | 90.752 MHz | 0.124 W | 0.053 W | 0.070 W |
| `2w_s4_vc4_pf0` | 7,137 | 372 | 3,214 | 0 | 1,447 / 106 | -2.130 ns | 82.440 MHz | 0.125 W | 0.055 W | 0.070 W |
| `2w_s4_vc8_pf0` | 7,891 | 372 | 4,227 | 0 | 1,447 / 106 | -2.500 ns | 80.000 MHz | 0.128 W | 0.058 W | 0.070 W |
| `2w_s4_vc4_pf1` | 10,882 | 372 | 4,757 | 0 | 1,510 / 106 | -9.342 ns | 51.701 MHz | 0.139 W | 0.068 W | 0.070 W |

匹配的 P3 enable 比较为 `2w_s4_vc4_pf1` 相对
`2w_s4_vc4_pf0`：

| 指标 | 匹配 PF0 | P3 PF1 | PF1 - PF0 |
| --- | ---: | ---: | ---: |
| Slice LUT | 7,137 | 10,882 | +3,745（+52.473%） |
| FF | 3,214 | 4,757 | +1,543（+48.009%） |
| LUT as memory | 372 | 372 | 0 |
| Block RAM tile | 0 | 0 | 0 |
| Bonded IOB | 1,447 | 1,510 | +63（+4.354%） |
| 10 ns 下 WNS | -2.130 ns | -9.342 ns | -7.212 ns |
| 近似 Fmax | 82.440 MHz | 51.701 MHz | -30.739 MHz（-37.287%） |
| Vectorless 总功耗 | 0.125 W | 0.139 W | +0.014 W（+11.200%） |
| 动态功耗 | 0.055 W | 0.068 W | +0.013 W（+23.636%） |

这些数字是综合阶段估算，而非 implementation 或 post-route 签核结果。
4 个配置全部未通过 100 MHz setup timing，但 hold check 都通过。
Cache interface 被直接暴露为 synthesis top，因此报告的 1,447 或
1,510 个 bonded I/O 超过所选器件的 106 个 I/O；按当前形式，
设计不是可放置的板级 top。功耗使用 vectorless activity propagation，
confidence 为 `Low`，因此不能取代 activity-driven power run。
Optimized PF1 的大幅面积与时序代价，可作为它与匹配 PF0 之间有效的
综合后比较，但不是 post-route implementation 结果。

## 先前 Legacy 替代证据（2026-07-13）

替代流程使用远程 Vivado 2024.2.1、器件 `xc7a35tcpg236-1` 和 10 ns
约束，并在 XSim 与 synthesis 中使用相同的显式 geometry。
`scripts/run_vivado.tcl` 每次运行前会删除旧 report directory；
先前的远程 runner 也会清理本地下载，强制要求恰好 8 个 simulation
log、4 个 synthesis directory 且每个都有 utilization/timing/power report，
并检查每条 `WORKLOAD_RESULT schema=2` 的 geometry、timing、`PASS` 和零
watchdog/protocol/duplicate-line error。脚本还会写入
`build/vivado/evidence_manifest.json`，其中包含 source 与 artifact SHA-256。

2026-07-13 的无旧报告混入运行以状态码 0 退出，并扫描了恰好 22 份
log/report：8 份 simulation log、12 份 synthesis report、Vivado log 和
Vivado journal。代表性 VCD 另行验证并记录哈希。验证未发现旧报告
或缺失报告，并生成了状态为 `PASS`、解析时钟周期为 10.0 ns 的
manifest。

被跟踪的[脱敏 Vivado manifest](../evidence/vivado-2026-07-13.json) 的
SHA-256 为
`3182fe968485c01dcbafd6e82a08dfc5e1c2ec0869f440a230af7f493ce44bab`。
它保留全部 input、simulation、synthesis、report 和 artifact 哈希；仅脱敏
远程执行 command 与 launcher 绝对路径。其私有 source manifest 的 SHA-256 为
`879d61773f47ebdd06c2971d29da99d975d93d5ca6c76afb7dc7f918711d328b`。
[公开 provenance 索引](../evidence/2026-07-13/provenance.json)记录了隐私审计
与未公开的私有 artifact。

八个 simulation point 为：

| 配置 | Geometry / timing |
| --- | --- |
| `dm_s8_vc4_pf0` | 1 way、8 sets、16-byte line、VC4、prefetch off、latency 2、periodic backpressure |
| `2w_s4_vc4_pf0` | 2 ways、4 sets、16-byte line、VC4、prefetch off、latency 2、periodic backpressure |
| `2w_s4_vc8_pf0` | 2 ways、4 sets、16-byte line、VC8、prefetch off、latency 2、periodic backpressure |
| `2w_s4_vc4_pf1` | 2 ways、4 sets、16-byte line、VC4、prefetch on、latency 2、periodic backpressure |
| `trace_replay_smoke_2w_s4_vc4_pf0` | 在匹配 2-way geometry 上 replay 可再分发 smoke trace |
| `trace_replay_generated_pointer_2w_s4_vc4_pf1` | 在匹配 prefetch geometry 上 replay generated pointer trace |
| `2w_s4_vc4_pf1_low_latency` | prefetch on、latency 0、无 memory backpressure |
| `2w_s4_vc4_pf1_high_latency_random_bp` | prefetch on、latency 8、randomized memory backpressure |

四个主要 L1 均为 128 bytes，因此 direct-mapped 与 2-way 比较保持逻辑 L1
capacity 不变。先前 legacy 综合后报告为：

| 配置 | LUT | FF | Block RAM tile | 10 ns 下 WNS | 近似 Fmax | Vectorless power | Dynamic | Static |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `dm_s8_vc4_pf0` | 5,189 | 1,852 | 2 | -1.581 ns | 86.3 MHz | 0.114 W | 0.044 W | 0.070 W |
| `2w_s4_vc4_pf0` | 5,699 | 2,246 | 0 | -2.068 ns | 82.9 MHz | 0.106 W | 0.035 W | 0.070 W |
| `2w_s4_vc8_pf0` | 5,783 | 3,004 | 0 | -1.516 ns | 86.8 MHz | 0.106 W | 0.036 W | 0.070 W |
| `2w_s4_vc4_pf1` | 6,222 | 2,407 | 0 | -1.626 ns | 86.0 MHz | 0.111 W | 0.041 W | 0.070 W |

这些都是综合后估算，且全部未满足 100 MHz 约束。Fmax 按
`1000 / (10 - WNS)` 估算；功耗为 vectorless 且 confidence 为 `Low`。
Vivado 为 8-set direct-mapped array 推断了 2 个 block-RAM tile，却把每个
way 深度只有 4 的 2-way array 映射为 distributed logic/register。因此逻辑
capacity 已受控，但 FPGA primitive mapping 并未匹配；LUT/FF/timing 差异不能
只归因于 associativity。若要进行物理实现等价实验，需要显式统一 RAM style
或 primitive mapping。

代表性 legacy waveform 为 `build/vivado/reports/2w_s4_vc4_pf1.vcd`。

可归因的私有 SPEC campaign 也在 2026-07-13 通过。它覆盖 4 个
benchmark、5 个 timed command、25 个采样 window 和 100 次四配置 replay。
Analyzer 验证接受了 25 对严格 prefetch off/on pair。

| Accuracy | L1 coverage | 下级 coverage | 带宽开销 | Bytes on-off | Service cycles on-off | Harmful / neutral / helpful |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 0.215690268 | 0.049647522 | 0.067245888 | 0.537997464 | 672,032 | 328,996 | 25 / 0 / 0 |

这些是采样 blocking model 结果，不是整程序 CPU 时序。不含地址的输出包括
[aggregate CSV](../evidence/2026-07-13/aggregate.csv)、
[pair CSV](../evidence/2026-07-13/pairs.csv)、
[classification CSV](../evidence/2026-07-13/classification.csv) 和
[cycle-delta SVG](../evidence/2026-07-13/cycles-on-minus-off.svg)。

许可 trace 和私有 manifest 仍保留在 Git 之外。下方历史 SPEC 表不属于
替代证据。

## 历史 2026-07-01 证据

### 历史摘要

本报告记录 2026-07-01 收集的 Phase 3 workload-driven Vivado 证据。本次
运行使用 `192.168.1.101` 上的远程 Vivado 2024.2.1，工程暂存于 ASCII
Windows 路径 `C:/Users/<remote-user>/l1d_codex_ascii_20260701_r10`。Vivado Tcl
source 使用 Windows `C:/...` 路径传入，远程密码没有写入仓库文件或日志。

最终远程流程返回状态码 0，下载了仿真日志、波形、资源、时序和 vectorless
power 报告，并扫描 22 个下载的日志/报告文件，未发现 `ERROR:`、
`CRITICAL WARNING:`、`FATAL`、source failure 或 testbench failure。

旧全系统 capture session 带有 `708.sqlite_r`、`721.gcc_r`、`767.nest_r` 和
`777.zstd_r` 标签，并使用 SPEC 默认 O3 base 优化。它们在机械意义上完成，
但不能归因到这些 benchmark。`723.llvm_r` 不在用户缩小后的标签集中。

### 历史已实现的 Phase 3 变更

- 增加 `scripts/run_remote_vivado.py`，用于 Paramiko 上传、ASCII 远端暂存、
  Windows 路径 Tcl 调用、报告下载和日志扫描。
- 增加 `src/tb_l1d_cache_oop.sv`，作为 class-based Vivado harness，包含
  CPU driver、memory model、scoreboard、monitor、workload sequence library、
  trace replay 和 `WORKLOAD_RESULT` 输出。
- 在 `traces/generated/` 中增加确定性 replay traces，并在
  `traces/generated/MANIFEST.md` 中记录 SHA-256。
- 在 `src/l1d_cache.sv` 中增加 FSM debug 输出，使 OOP monitor 能报告带状态
  信息的 protocol 和 watchdog failure。
- 修复 replacement path：当被驱逐 L1 行复制到 victim cache 时立即将对应
  L1 行置 invalid，消除 incoming fill 安装前的 transient duplicate valid
  line。
- 在 Vivado OOP harness 中增加静态 duplicate-line 检查；每个 workload 现在
  都报告 `duplicate_lines`。
- 增加用于获许可 SPEC CPU 2026 样本的 QEMU memory-trace 窗口采集和 replay
  辅助脚本：`scripts/capture_spec_qemu_windows.py`、
  `scripts/run_spec_trace_replay.sh`、`scripts/split_qemu_memtrace_windows.py`
  和 `scripts/summarize_spec_replay.py`。

### 历史 Vivado 矩阵

所有 8 个 XSim 配置均通过：

| 配置 | 关键参数 | 证据 |
| --- | --- | --- |
| `direct_mapped_vc4` | `NUM_WAYS=1`，关闭 prefetch，VC4，latency 2，确定性 memory backpressure | `build/vivado/reports/direct_mapped_vc4_simulation.log` |
| `two_way_vc4` | `NUM_WAYS=2`，关闭 prefetch，VC4，latency 2，确定性 memory backpressure | `build/vivado/reports/two_way_vc4_simulation.log` |
| `two_way_vc8` | `NUM_WAYS=2`，关闭 prefetch，VC8，latency 2，确定性 memory backpressure | `build/vivado/reports/two_way_vc8_simulation.log` |
| `next_line_prefetch_vc4` | `NUM_WAYS=2`，开启 next-line prefetch，VC4，latency 2，确定性 memory backpressure | `build/vivado/reports/next_line_prefetch_vc4_simulation.log` |
| `trace_replay_smoke_two_way_vc4` | smoke trace replay，关闭 prefetch | `build/vivado/reports/trace_replay_smoke_two_way_vc4_simulation.log` |
| `trace_replay_generated_pointer_prefetch_vc4` | generated pointer trace replay，开启 next-line prefetch | `build/vivado/reports/trace_replay_generated_pointer_prefetch_vc4_simulation.log` |
| `next_line_prefetch_vc4_low_latency` | 开启 next-line prefetch，latency 0，无 memory backpressure | `build/vivado/reports/next_line_prefetch_vc4_low_latency_simulation.log` |
| `next_line_prefetch_vc4_high_latency_random_bp` | 开启 next-line prefetch，latency 8，随机 memory backpressure | `build/vivado/reports/next_line_prefetch_vc4_high_latency_random_bp_simulation.log` |

最终运行中，每一行 `WORKLOAD_RESULT` 都报告 `status=PASS`、`watchdogs=0`、
`protocol=0` 和 `duplicate_lines=0`。

### 历史 Workload 覆盖

OOP harness 覆盖：

- 定向 RV64 load/store size、符号/零扩展、高地址 tag 和未对齐 response；
- dirty victim replacement 和 write-back preservation；
- CPU response backpressure；
- matrix row-major、column-major、blocked/tiled、超过 L1 容量的 same-set
  pressure、超过 L1 加 victim 容量的 same-set pressure，以及 store-heavy dirty
  matrix update；
- pointer random permutation、victim-cache conflict chain、击败 next-line 的
  irregular chase，以及 mixed load/store pointer update；
- 确定性 external prefetch candidate injection；
- smoke trace 和 generated pointer trace replay。

生成的 trace artifact 是可重新分发的 synthetic trace，不是获许可 SPEC trace：

| Trace | 行数 | SHA-256 |
| --- | ---: | --- |
| `phase3_matrix_row_major.trace` | 64 | `400ed1afb8775561e46c10856461fffa13b5bbc6a0ab57f33887d9b8c06f0445` |
| `phase3_matrix_column_major.trace` | 64 | `ae8a522c6c87328ba93c4472ab37fbffa20daacbdbf00c211d1a6e99ca74c8bf` |
| `phase3_pointer_permutation.trace` | 64 | `5c8039c1e6a8f40d376fa2787a6ce85378ab07bcae8e115a51a980206ee50d08` |
| `phase3_pointer_mixed_update.trace` | 64 | `7e52cd734e4f9a36f7e30c4bef858853e0be15bb213fabebecca782ae6033c0e` |

获许可 SPEC 样本 hash、采样命令、replay 命令和详细聚合结果记录在
`docs/zh/spec2026_trace_campaign.zh.md`。所有许可 raw 与 replay-derived SPEC
sample 只保存在被忽略的本地 `build/spec2026/` 下，不通过 Git 或 Git LFS 分发。

### 历史 Prefetch 边界结果

中等 latency 的 `next_line_prefetch_vc4` 运行展示了预期边界：

下表 Coverage 使用 paired baseline miss reduction，而不是 `useful/accesses`；
没有匹配 prefetch-off run 的 workload 记为 N/A。

| Workload | Hits | Misses | Victim hits | Mem reads | Read bytes | Useful | Useless | Pollution | Accuracy | Coverage | Cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `matrix_row_major` | 8 | 8 | 0 | 16 | 256 | 8 | 0 | 4 | 100.00% | 50.00% | 174 |
| `matrix_column_major` | 0 | 16 | 8 | 16 | 256 | 8 | 0 | 0 | 100.00% | 0.00% | 193 |
| `matrix_blocked_tiled` | 8 | 8 | 0 | 16 | 256 | 8 | 0 | 4 | 100.00% | 50.00% | 174 |
| `pointer_random_permutation` | 4 | 12 | 1 | 19 | 304 | 5 | 1 | 5 | 62.50% | 25.00% | 208 |
| `pointer_irregular_defeats_next_line` | 0 | 24 | 0 | 48 | 768 | 0 | 18 | 10 | 0.00% | 0.00% | 474 |
| `external_prefetch_matrix_candidates` | 8 | 0 | 0 | 8 | 128 | 8 | 0 | 0 | 100.00% | N/A | 100 |

与关闭 prefetch 的 two-way VC4 baseline 相比，next-line prefetch 会把 row-major
和 blocked/tiled 中一半 demand access 转为 hit，但在当前 blocking 实现中不会
减少下级内存 read 数。Irregular pointer chase 是有害场景：中等 latency 下
memory read 从 24 翻倍到 48，cycle 从 275 增长到 474。

### 历史 SPEC CPU 2026 Trace Campaign（归因无效）

SPEC campaign 在 O3 build 和 test-size run setup 后采集了四个请求子项：

| Benchmark | Samples | Replay rows | Status |
| --- | ---: | ---: | --- |
| `708.sqlite_r` | 5 | 20 | PASS |
| `721.gcc_r` | 5 | 20 | PASS |
| `767.nest_r` | 5 | 20 | PASS |
| `777.zstd_r` | 5 | 20 | PASS |

每个 benchmark 包含一个 startup-after-warmup 的 10,000 行样本，以及四个后续
5,000 行 in-run 样本。所有原始采集都达到 `captured=30000`，所有 benchmark
的 `speccmds.cmd` 和 `compare.cmd` 阶段均以 `rc=0` 退出。全部 80 个
Icarus replay 日志都报告 `ALL TESTS PASSED`。

以下是每个 benchmark 五个样本聚合后的 replay 指标：

| Benchmark | Config | Hit rate | Victim hit rate | Mem/access | Cycles/access | Prefetch accuracy |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `708.sqlite_r` | `direct_mapped_vc4` | 0.4808 | 0.1097 | 0.5933 | 7.58 | 0.0000 |
| `708.sqlite_r` | `two_way_vc4` | 0.5762 | 0.0586 | 0.5319 | 7.22 | 0.0000 |
| `708.sqlite_r` | `two_way_vc8` | 0.5762 | 0.0912 | 0.4865 | 7.01 | 0.0000 |
| `708.sqlite_r` | `next_line_prefetch_vc4` | 0.5829 | 0.0579 | 0.8150 | 9.42 | 0.2011 |
| `721.gcc_r` | `direct_mapped_vc4` | 0.5057 | 0.0797 | 0.6027 | 7.60 | 0.0000 |
| `721.gcc_r` | `two_way_vc4` | 0.5824 | 0.0463 | 0.5452 | 7.27 | 0.0000 |
| `721.gcc_r` | `two_way_vc8` | 0.5824 | 0.0779 | 0.5017 | 7.06 | 0.0000 |
| `721.gcc_r` | `next_line_prefetch_vc4` | 0.5960 | 0.0502 | 0.8037 | 9.32 | 0.2214 |
| `767.nest_r` | `direct_mapped_vc4` | 0.4849 | 0.0780 | 0.6317 | 7.74 | 0.0000 |
| `767.nest_r` | `two_way_vc4` | 0.5672 | 0.0530 | 0.5517 | 7.31 | 0.0000 |
| `767.nest_r` | `two_way_vc8` | 0.5672 | 0.0889 | 0.5000 | 7.07 | 0.0000 |
| `767.nest_r` | `next_line_prefetch_vc4` | 0.5646 | 0.0435 | 0.8954 | 9.91 | 0.1787 |
| `777.zstd_r` | `direct_mapped_vc4` | 0.6226 | 0.0806 | 0.4419 | 6.90 | 0.0000 |
| `777.zstd_r` | `two_way_vc4` | 0.6976 | 0.0437 | 0.3865 | 6.59 | 0.0000 |
| `777.zstd_r` | `two_way_vc8` | 0.6976 | 0.0796 | 0.3353 | 6.35 | 0.0000 |
| `777.zstd_r` | `next_line_prefetch_vc4` | 0.7097 | 0.0417 | 0.5829 | 8.10 | 0.2175 |

若仅按旧标签机械分组这些无效 mixed-system stream，two-way VC4 的测得
hit rate 高于 direct-mapped VC4，VC8 使测得的每次 demand memory access 降低
约 0.044 到 0.052，next-line prefetch 使 memory/access 增加 +0.196 到 +0.344。
这些只是 session-level 历史统计，既不能强化 SPEC workload 结论，也不能
证明包括 `767.nest_r` 在内的任何所标 benchmark 行为。

### 历史综合与功耗

Vivado 使用 10 ns 时钟约束，为 `xc7a35tcpg236-1` 综合了四个主要 RTL 配置。
这些是综合后估算，不是 post-route sign-off 数据。

| 配置 | LUT | FF | Block RAM tile | 10 ns 下 WNS | 综合后近似 Fmax | Vectorless power | Dynamic | Static |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Direct-mapped，VC4，关闭 prefetch | 5,178 | 1,853 | 2 | -1.291 ns | 88.6 MHz | 0.117 W | 0.046 W | 0.070 W |
| 2-way，VC4，关闭 prefetch | 4,721 | 2,008 | 4 | -0.417 ns | 96.0 MHz | 0.107 W | 0.036 W | 0.070 W |
| 2-way，VC8，关闭 prefetch | 5,395 | 2,767 | 4 | -1.462 ns | 87.2 MHz | 0.117 W | 0.047 W | 0.070 W |
| 2-way，VC4，开启 next-line prefetch | 5,789 | 2,168 | 4 | -1.981 ns | 83.5 MHz | 0.117 W | 0.047 W | 0.070 W |

四个综合后 timing report 均未满足 100 MHz 目标。Fmax 按
`1000 / (10 - WNS)` 计算，只应作为早期估算。功耗使用 Vivado vectorless
activity propagation，没有 SAIF/VCD switching activity file，confidence 为 `Low`。

### 历史波形 Artifact

代表性通过波形为：

```text
build/vivado/reports/next_line_prefetch_vc4.vcd
```

下载的 VCD 大小为 611 KiB，包含 top clock、DUT port 和 DUT 内部信号，例如
CPU、memory、prefetch、statistics 和 `debug_state`。

## 剩余缺口

当前 RTL 支持冻结的 next-line baseline、adaptive direct-L1 stream prefetch、
external candidate injection、shadow feedback 与单 PF MSHR。更大的
placement/replacement policy matrix 仍是设计缺口：

- 没有 `3:1` 或 `7:1` capacity reservation policy，因为当前 RTL 仅支持
  `NUM_WAYS=1` 或 `NUM_WAYS=2`，且没有 group-level slot indirection；
- 没有 whole-cache greedy prefetch pool；
- 没有 separate prefetch buffer 或 direct victim-cache prefetch placement；
- 没有 LRU 或 pointer-based replacement 选项；
- paired replay sidecar 现已提供真实 L1/下级内存 help 与 pollution，
  但 PF event 没有用于逐 prefetch candidate/issue/return latency distribution 的
  共享 transaction identity；
- post-route timing 和 activity-based power 现已完成，但未通过部署门禁；所有路径的
  手工 waveform 检查和任何架构重设仍是后续工作。

历史无效 campaign 覆盖了 `708`、`721`、`767` 和 `777` 标签，但不能
归因到 benchmark。这四个 benchmark 的可归因替代私有 campaign 已于
2026-07-13 完成并通过；`723` 保持在请求范围之外。
