# SPEC CPU 2026 Trace Campaign

英文 `docs/spec2026_trace_campaign.md` 是权威版本。

## 有效性状态（2026-07-13）

后文置于历史标题下的 campaign 仅作为旧版 replay 流程的证据
保留，**不能作为可归因到 benchmark 的有效证据**：

- QEMU 使用四个 vCPU，plugin 把所有 vCPU callback 串接后送入单 cache 流；
- tracing 由另一个进程开启，没有过滤 privilege 或 address-space context；
- 保留的 120,000 条 payload 中有 108,387 条（90.323%）使用 RISC-V Linux
  kernel virtual-address range；
- direct-mapped 与 two-way replay 没有保持 L1 capacity 一致。

因此，下文带 benchmark 标签的表格和结论不能引用为 sqlite、gcc、nest 或 zstd
行为，只能描述四次旧版全系统捕获 session。替代 campaign 只有在 target-process
marker 将单 vCPU 上的一个 U-mode SATP context 绑定为 ROI、replay 使用物理地址、
simulation 与 PPA 使用完整相同 geometry，且 manifest/run/pair 守恒检查全部通过
后才有效。许可 raw/derived trace 只保存在本地；公开仓库只保存脱敏证据。

## 范围

本文记录 Phase 3 的获许可 SPEC CPU 2026 trace campaign。所有许可 raw 与
replay-derived capture 只保存在被忽略的本地 `build/spec2026/` 下。公开仓库
不跟踪任何许可样本，也不得再次提交。

本次 campaign 使用 `config/codex-gcc-linux-riscv64.cfg` 中的 SPEC 默认
base 优化配置。该配置基于 `Example-gcc-linux-riscv64.cfg`，编译参数为
`-g -O3 -march=rv64gc`。

旧 session 标签（不能归因到 benchmark）：

- `708.sqlite_r`
- `721.gcc_r`
- `767.nest_r`
- `777.zstd_r`

`723.llvm_r` 不在用户为该历史运行缩小后的标签集中。

## 当前已验证流程

替代流程使用 QEMU 11.0.1 / Plugin API 6 的 `riscv64` system emulation，
固定 `-smp 1,maxcpus=1` 并使用 `-snapshot`。每个 dynamic timed command
都由带版本的 `a0..a5` ROI marker 包装，其中包含 nonce、command index、
PID 和 TID。Plugin 绑定 vCPU 0、U privilege 与一个 non-Bare SATP，过滤并
计数 kernel/其他 SATP access，记录物理地址、删除 store data，并拒绝不完整
或 identity 存疑的 capture。执行 target 前，`trace_exec` 会设置并验证
`ADDR_NO_RANDOMIZE`；若无法关闭 target ASLR 就立即失败，从 count/capture 控制
路径中消除依赖地址布局的 pointer hashing。Schema-3 raw row 保留每条 source operation 及其两个
物理端点。Splitter 将同 line 未对齐操作映射为一条 byte-sized cache-line touch，
跨 line 操作在独立翻译最后一个 byte 后映射为两条 touch；source 与 canonical
replay count 均可独立审计。它还会独立重新绑定 context/start/stop/summary identity，
并要求每条 payload row 都携带 ROI 的精确 SATP、vCPU 与 privilege。

从仓库根目录运行：

```sh
scripts/build_qemu_memtrace_plugin.sh
python3 scripts/capture_spec_qemu_windows.py \
  --out-dir build/spec2026/qemu-private \
  --size test --label codexrv64 \
  708.sqlite_r 721.gcc_r 767.nest_r 777.zstd_r
scripts/run_spec_trace_replay.sh \
  build/spec2026/qemu-private/campaign_manifest.json \
  build/spec2026/replay/logs
```

Replay sensitivity control 是 fail-closed 的环境输入：

| 变量 | 默认值 | 允许值 |
| --- | --- | --- |
| `L1D_REPLAY_SCOPE` | `full` | `full` 四配置 matrix，或仅 paired off/on |
| `L1D_PREFETCH_POLICY` / `L1D_PF_OPT_LEVEL` | `1` / `3` | legacy `0/0`，optimized `1/1..3` |
| `L1D_PRODUCER_PROFILE` | `zero-bubble` | `sequential`、`zero-bubble`、`fixed-gap` |
| `L1D_PRODUCER_GAP` | `0` | fixed-gap `1`、`2`、`4` 或 `8` |
| `L1D_MEM_LATENCY` | `2` | 非负整数 |
| `L1D_MEM_READY_MODE` | `periodic` | `always-ready`、`periodic`、`deterministic-random` |
| `L1D_SIDECAR_SCHEMA` | `3` | `2` 或 `3` |

Elaboration 后的 latency/ready 值还会作为 runtime provenance plusarg 传入。
Testbench 会拒绝不匹配，每个 campaign manifest 也会记录派生 timing profile。

`capture_spec_qemu_windows.py` 会对每个 timed command 先运行 source-event count pass，
再运行新的 snapshot capture pass。长 ROI 生成五个每个含“5,000 source warmup +
5,000 source measurement”的 percentile window；短 ROI 整体 replay。Window manifest
另行记录跨 line 展开后的 canonical replay-access count。在每个 snapshot 中，runner
先清除 SPEC authoritative `compare.cmd` 声明的所有输出，再运行一个 timed command，
并仅选择该命令实际生成输出（包括 side output）对应的 comparison，在 ROI stop 后
要求该子集通过。Count 与 capture pass 必须选出逐字节相同的 comparison 子集；
两份 command 和 log 都是强制哈希 artifact。Benchmark plan 会哈希原始
`speccmds.cmd`、要求 timed-command index 连续，并证明每个 command 的 comparison
子集互不重叠且并集恰好覆盖完整 `compare.cmd` plan。脚本在
`build/spec2026/qemu-private` 下写入 hash 完整的 unit/campaign manifest。
证据图用 SHA-256 绑定 QEMU executable、plugin、capture/split/build/start source、
ROI source、不可变 base VM/QEMU firmware input、target ELF 及每条 command/artifact。
完整临时 campaign 图验证通过后，authoritative PASS JSON 才会原子发布。
Replay runner 只消费该 authoritative campaign，拒绝 stale、缺失或额外
window，运行下列矩阵、写入含 demand 与 prefetch issue/fill event 的 sidecar、生成
`build/spec2026/replay/campaign_manifest.json` 及其 SHA-256，并自动调用严格
analyzer：

| config ID | sets | ways | line bytes | L1 bytes | victim entries | prefetch | 用途 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `dm_s8_vc4_pf0` | 8 | 1 | 16 | 128 | 4 | 0 | 等容量 associativity baseline |
| `2w_s4_vc4_pf0` | 4 | 2 | 16 | 128 | 4 | 0 | prefetch pair 的 off member |
| `2w_s4_vc8_pf0` | 4 | 2 | 16 | 128 | 8 | 0 | victim-capacity baseline |
| `2w_s4_vc4_pf1` | 4 | 2 | 16 | 128 | 4 | 1 | prefetch pair 的 on member |

直接调用 analyzer 时，当前 CLI 为：

```sh
python3 scripts/summarize_spec_replay.py \
  --manifest build/spec2026/replay/campaign_manifest.json \
  --out-dir build/spec2026/replay/analysis
```

Analyzer 强制要求已哈希的 trace、log、sidecar、capture manifest、simulation
binary、simulator、command/cwd identity 和精确 command-to-artifact path 绑定；检查
每个 window 声明的四配置矩阵、严格 off/on pairing、counter/sidecar-event 守恒、
trace/sidecar demand identity、零 protocol/watchdog/duplicate-line error，并从 sidecar
得出真实 L1/lower-memory help 与 pollution。
在保留的 schema-2 legacy campaign 中，`timely_useful=useful`、
`late_useful=0` 是结构性 proxy。下方 optimized schema-3 campaign 用 demand 与
PF lifecycle timing 取代该 proxy。

每个有效 pair 还会生成 `classification.csv` 和 `cycles-on-minus-off.svg`。
分类刻意只使用一个维度：`cycles_on_minus_off < 0` 为 helpful，等于零为
neutral，大于零为 harmful。其他指标仍保留在 paired 与 aggregate 表中，不会
暗中改变该标签。

## Optimized P0–P3 Campaign（2026-07-13）

最终 optimized campaign 复用相同 25 个可归因 window，以及相同的 2-way、
4-set、16-byte-line、VC4 paired geometry。Producer 改为真正的 zero-bubble
source：当 response `i` 尚未完成时，request `i+1` 已保持 valid，并在第一个
ready edge 传输。Sidecar 和 result row 升级为 schema 3，analyzer 仍可读取
历史 schema-2 证据。

四个 policy campaign 均验证通过 100/100 runs 和 25/25 精确 pair：

| Policy / level | Cycles off | Cycles on | Delta | Byte overhead | Harmful / neutral / helpful | PF issued / merged / installed | PF-caused WB |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| 冻结 legacy `0/0` | 850,547 | 850,547 | 0 | 0 | 0 / 25 / 0 | 0 / 0 / 0 | 0 |
| Safe next-line P1 `1/1` | 850,547 | 850,547 | 0 | 0 | 0 / 25 / 0 | 0 / 0 / 0 | 0 |
| Adaptive stream P2 `1/2` | 850,547 | 850,547 | 0 | 0 | 0 / 25 / 0 | 0 / 0 / 0 | 0 |
| Shadow + PF MSHR P3 `1/3` | 850,547 | **849,823** | **-724** | **0** | **0 / 7 / 18** | **544 / 544 / 0** | **0** |

P1 和 P2 会正确拒绝 zero-bubble 中的单 cycle opportunity，因为它们的
2-cycle idle guard 无法隐藏 blocking prefetch。P3 只在已出现的下一 demand
与 candidate 同地址，且 tag-only L1/VC lookup 证明该行不存在时，才在
response cycle 后台 issue。544 个 issued read 全部与同地址 demand merge：
demand-owned read 从 59,275 降到 58,731，总 read byte 保持 948,400，
write byte 保持 300,736，且没有 speculative install 或归因 dirty write-back。

P3 通过主 profile 的所有硬门槛：

- aggregate cycle delta 为负；
- read+write bandwidth overhead 为 0%，低于 10%；
- 25/25 window 不退化，超过 20/25 要求；
- 最大 slowdown 为 0%，最佳 window 节省 80 cycles；
- prefetch-caused dirty write-back 为零；
- P3 aggregate cycles 低于 legacy，bandwidth 相同。

完整的 paired sensitivity matrix 也全部通过验证。下表给出每个
policy 的 on-minus-off cycle delta；所有 P3 byte delta 和
prefetch-caused write-back 都为零。

加强后的 drain check 也通过了每条 schema-3 row：admitted request 必须在
报告前 issue 或 cancel，每个 issue 必须 return 到唯一的 install、merge 或
discard outcome。

| Producer / memory profile | Legacy cycle delta | Legacy byte overhead | P3 cycle delta | P3 harmful / neutral / helpful | P3 issued / merged |
| --- | ---: | ---: | ---: | --- | ---: |
| Sequential、latency 2、periodic ready | +328,996 | +672,032（53.80%） | 0 | 0 / 25 / 0 | 0 / 0 |
| Fixed gap 1、latency 2、periodic ready | +328,996 | +672,032（53.80%） | 0 | 0 / 25 / 0 | 0 / 0 |
| Fixed gap 2、latency 2、periodic ready | +280,654 | +672,032（53.80%） | 0 | 0 / 25 / 0 | 0 / 0 |
| Fixed gap 4、latency 2、periodic ready | +190,854 | +672,032（53.80%） | 0 | 0 / 25 / 0 | 0 / 0 |
| Fixed gap 8、latency 2、periodic ready | +13,745 | +672,032（53.80%） | 0 | 0 / 25 / 0 | 0 / 0 |
| Zero-bubble、latency 0、always ready | 0 | 0 | **-570** | 0 / 2 / 23 | 570 / 570 |
| Zero-bubble、latency 8、确定性 random ready | 0 | 0 | **-859** | 1 / 9 / 15 | 422 / 422 |

因此，optimized engine 不会在无法隐藏请求的 gap 中消耗流量，而冻结的
blocking engine 在每个 sequential/fixed-gap profile 中仍执行 44,193 次
speculative read。在 latency-8 profile 中，P3 唯一的 harmful window 为
+71 cycles（+0.1282%），低于 5% guardrail；aggregate 仍节省 859 cycles。
在主 profile 与全部 sensitivity profile 中，P3 cycle 不高于 optimized-off
且不高于 legacy，bandwidth 相同或更低。这里将 legacy-comparison
gate 解释为 bandwidth 上的 Pareto 不退化，并要求在 legacy 实际执行
speculative work 时获得严格 cycle 改善。

无地址的公开结果位于
[optimized 证据目录](../evidence/2026-07-13-optimized/README.md)。该结果保留而不是覆盖
下方有害的 sequential legacy baseline。独立的 optimized Vivado 2024.2.1
campaign 现已通过：11 份 XSim log 包含 83 行生命周期守恒全部闭合的
schema-3 workload row，4 个综合配置产生了预期的全部 12 份 PPA
report。其 OOP workload matrix 使用 sequential producer；定向
`tb_l1d_cache_optimized_p3` 测试提供了跨仿真器的真正 zero-bubble
覆盖。因此本节性能结论仍来自本地真正 zero-bubble trace campaign，
而不是 OOP matrix。综合后 PPA 及其 setup-timing 未闭合、I/O 超额与
vectorless-power 局限记录在 [Phase 3 Vivado 报告](../phase3_vivado_report.md)。

## Legacy Next-Line 权威 Baseline（2026-07-13）

完整的替代流程已通过。4 个 benchmark plan 包含 5 个 timed-command
capture unit 和 25 个采样 window。每个 count/capture snapshot 与 SPEC
comparison 都已通过，top-level campaign 也在其 `PASS` manifest 原子发布
前完成验证。25 个 window 全部使用 `demand-warm-measure`：在 ROI
10%、30%、50%、70% 和 90% 分位点，先执行 5,000 条关闭 prefetch 的
warmup source event，再执行 5,000 条 measurement source event。本次
campaign 中没有 `whole-roi-short` window。跨 line canonicalization 将
250,000 条采样 source event 展开为 250,971 条 replay access。

| benchmark | command | ROI source event | misaligned | cross-line | canonical access | sampled source→replay | 选中的 compare ID | 完整 compare-plan SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| `708.sqlite_r` | 0 | 568,742,855 | 6,684,478 | 3,232,848 | 571,975,703 | 50,000→50,259 | `[0]` | `3600fe4088d3967d4de7c1da062fd2534baf859c8a50d8a87b310f768b833f59` |
| `721.gcc_r` | 0 | 15,001,579 | 11,283 | 2,889 | 15,004,468 | 50,000→50,000 | `[0]` | `b9169d2aeee7689a5e5183a8a580665dd067a11b01a169821b83d27d3314af68` |
| `767.nest_r` | 0 | 1,109,373,742 | 167,455 | 14,757 | 1,109,388,499 | 50,000→50,000 | `[0,2]` | `30eeb5b41f4fa3f3491b3b29fc1018bd399cf3043ad20ff014177ab86a6ea4a4` |
| `767.nest_r` | 1 | 9,370,927,478 | 14,557 | 4,518 | 9,370,931,996 | 50,000→50,000 | `[1]` | `30eeb5b41f4fa3f3491b3b29fc1018bd399cf3043ad20ff014177ab86a6ea4a4` |
| `777.zstd_r` | 0 | 662,301,894 | 19,893,851 | 7,849,609 | 670,151,503 | 50,000→50,712 | `[0]` | `e7dbd4b27675c86bde1f74add3fdb88fc6cf3567c98c4fbb34ca91841cab8144` |

对于 `767.nest_r`，command 0 选择 compare command `[0,2]`，command 1 选择
`[1]`；这些子集互不重叠，且恰好完整覆盖其由 3 个 command 组成的
完整 comparison plan。其余 3 个 benchmark 均只有 1 个 timed command 和
1 个 comparison。

随后，replay 完成了精确的四配置矩阵：100/100 个 run 与 25/25 个
prefetch off/on pair 全部通过，其中 50 个 run 是独立的 direct-mapped
或 VC8 control。所有已哈希 log 和 sidecar 都完整存在；watchdog、protocol
和 duplicate-line 计数均为零。严格 analyzer 的 artifact、matrix、
geometry/timing、counter-conservation、status、trace/sidecar identity 和 true-
pollution delta 检查全部通过。

在全部 125,511 次被测 demand access 中，受控配置的汇总结果为：

| config ID | hit rate | victim hit / access | demand read / access | all read / access | replay cycle / access |
| --- | ---: | ---: | ---: | ---: | ---: |
| `dm_s8_vc4_pf0` | 0.4528 | 0.0713 | 0.4759 | 0.4759 | 7.8261 |
| `2w_s4_vc4_pf0` | 0.4699 | 0.0578 | 0.4723 | 0.4723 | 7.7873 |
| `2w_s4_vc8_pf0` | 0.4699 | 0.0982 | 0.4319 | 0.4319 | 7.5258 |
| `2w_s4_vc4_pf1` | 0.4963 | 0.0632 | 0.4405 | 0.7926 | 10.4086 |

因此，在这些采样区间中，等 128-byte L1 容量的 direct-mapped/2-way
对比中 hit rate 和 replay cost 变化都不大。VC8 不改变 L1 hit rate，但会
增加 victim rescue 并减少 demand read。Next-line prefetch 整体上提高 hit rate
且减少 demand read，但其额外 prefetch read 主导了总流量与串行 replay
cycle。

| benchmark | pair | accuracy | L1 coverage | lower coverage | bandwidth overhead | cycles on−off | harmful / neutral / helpful |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `708.sqlite_r` | 5 | 25.70% | +5.49% | +7.32% | +45.98% | +61,554 | 5 / 0 / 0 |
| `721.gcc_r` | 5 | 13.62% | −0.63% | −2.64% | +62.39% | +80,784 | 5 / 0 / 0 |
| `767.nest_r` | 10 | 21.83% | +8.27% | +11.14% | +52.72% | +156,639 | 10 / 0 / 0 |
| `777.zstd_r` | 5 | 31.31% | −1.28% | +0.55% | +57.94% | +30,019 | 5 / 0 / 0 |
| **all** | **25** | **21.57%** | **+4.96%** | **+6.72%** | **+53.80%** | **+328,996** | **25 / 0 / 0** |

Paired sidecar 识别出 8,079 个 true L1-help event 和 4,776 个 true L1-
pollution event，以及 9,018 个 lower-memory-help event 和 5,032 个 true lower-
memory-pollution event。因此，net miss coverage 整体为正，但按已记录的
blocking replay-cycle 分类标准，每个采样 pair 都是 harmful。这是 policy
与 model 结果，不是整程序 CPU time：当前 single-miss FSM 会串行化
demand、prefetch 和 write-back 流量。

公开的 [paired metrics](../evidence/2026-07-13/pairs.csv) 包含逐 window 的
load/store mix、stride、reuse distance、footprint 和 set-pressure feature。在 25 个
window 中，next-line stride fraction 的范围为 0.0062 到 0.3793，
reuse-distance p90 为 8 到 156 个 unique line，set-access imbalance 为
1.059 到 2.354。[Classification 表](../evidence/2026-07-13/classification.csv)
和 [cycle-delta 图](../evidence/2026-07-13/cycles-on-minus-off.svg) 在不公开地址的
前提下发布了完整的 helpful/neutral/harmful 结果。

Provenance anchor：

- 公开证据及未公开项索引：
  [provenance.json](../evidence/2026-07-13/provenance.json)；
- capture implementation commit：`2d144658ae69a80333ef7e94411b6cad924f49cf`；
- replay/parser commit：`d2c3a8d977135ded40c1bc9067cd0a5987e45888`；
- capture campaign SHA-256：`057965ff31234bac274ce81fc719780dbd2e7d60a59ccceb359b3b7ac64a7f9f`；
- capture replay-list SHA-256：`3eaf06a196b7eb6a34db814ae0815de0eb424a3dfd96e511684a25026642cb98`；
- replay campaign SHA-256：`e593bd279361036e4cb75c4cf9d1b959afb2071fb0d7c4ca1e425323a8f9cc78`；
- 公开 pairs / aggregate / classification / SVG SHA-256：
  `f33ef79f760baaa1351df79349aa659c0a703fbdb9332da750a4c5e186f45c11`、
  `5cc709794c1e5d2b03e267f87df308a758d9bae34c1edf9c6a831d90776f1d5a`、
  `a25012f292b50ffc4143e261660c5d458bf439f8cc0f4033a182d597565b23b5`
  和 `8475251a909a609c384ac53f0bf8268b7bf12ad60b01d7bafeb0246bcf585ac6`。

Capture manifest 记录 `dirty=true`，原因是 working tree 中存在与本次执行
无关的文档 artifact。11 个可执行 capture input 分别记录了哈希，它们的
aggregate 为
`409764c38342f3693e301f91e7ccda45ddc4eb9bbd09e770f6217a42baa3f161`。Raw
capture、地址、command text、log 和逐 demand sidecar 仍保留在被忽略的
私有 build directory 中，不属于公开证据。

## 历史命令（禁止作为当前流程使用）

下列命令只能复现已废弃的 mixed-system campaign，并使用过时的 capture/replay
接口；这里只为 provenance 保留，不是操作说明。

Build 和 run setup 在 Debian RV64 VM 的 `/home/debian/spec2026` 中执行：

```sh
runcpu --action=build --config=codex-gcc-linux-riscv64 \
  --define gcc_dir=/usr --define build_ncpus=4 --define label=codexrv64 \
  --size=test --iterations=1 --tune=base --noreportable \
  708.sqlite_r 721.gcc_r

runcpu --action=build --config=codex-gcc-linux-riscv64 \
  --define gcc_dir=/usr --define build_ncpus=4 --define label=codexrv64 \
  --size=test --iterations=1 --tune=base --noreportable \
  767.nest_r 777.zstd_r

runcpu --action=runsetup --config=codex-gcc-linux-riscv64 \
  --define gcc_dir=/usr --define build_ncpus=4 --define label=codexrv64 \
  --size=test --iterations=1 --tune=base --noreportable \
  708.sqlite_r 721.gcc_r 767.nest_r 777.zstd_r
```

Trace 采集使用本地 QEMU 插件和 marker wrapper：

```sh
scripts/build_qemu_memtrace_plugin.sh
scripts/capture_spec_qemu_windows.py 708.sqlite_r 721.gcc_r 767.nest_r 777.zstd_r
```

Replay 和汇总使用：

```sh
scripts/run_spec_trace_replay.sh
scripts/summarize_spec_replay.py build/spec2026/replay/logs \
  --csv build/spec2026/replay/spec_replay_summary.csv \
  --markdown build/spec2026/replay/spec_replay_summary.md
```

旧 runner 曾扫描 `traces/spec2026/` 下的 LFS 文件；这些文件现在已不存在。
当前 runner 会拒绝目录扫描，只接受 authoritative capture campaign manifest。

## 历史 Capture Manifest（无效）

每个 benchmark 生成一个 startup-after-warmup 的 10,000 payload trace line 样本，
以及四个后续 in-run 的 5,000 payload trace line 样本。采集窗口为：

```text
10000:10000;50000:5000;100000:5000;200000:5000;400000:5000
```

每个原始 benchmark trace 都报告 `captured=30000`、`valid_seen=405000`，
且五个窗口均达到请求行数。每个 benchmark 的 `speccmds.cmd` 和
`compare.cmd` 阶段都以 `rc=0` 退出。

这些样本过去曾通过 Git LFS 保存，现在已不再被公开仓库跟踪或包含。下列
hash 只用于标识无效的历史证据。

| sample | payload lines | skip | requested lines | captured lines | sha256 |
| --- | ---: | ---: | ---: | ---: | --- |
| `spec2026_708_sqlite_r_test_w00_skip10000_n10000.trace` | 10000 | 10000 | 10000 | 10000 | `e2734306a7896d23128cd422737fbf560fefe12285f5a4b09669db29b04c33bc` |
| `spec2026_708_sqlite_r_test_w01_skip50000_n5000.trace` | 5000 | 50000 | 5000 | 5000 | `c6b96b0098a3c149893f076dacb2fae1de9fd032656e6b00d23da094aa3c1022` |
| `spec2026_708_sqlite_r_test_w02_skip100000_n5000.trace` | 5000 | 100000 | 5000 | 5000 | `139f07cdb2325476284e394ef273effef7fc4d0938926d8aa7674dae8f4ac7c5` |
| `spec2026_708_sqlite_r_test_w03_skip200000_n5000.trace` | 5000 | 200000 | 5000 | 5000 | `1a7ad0cf8f51839ee0b1afba29ef002453cdde0f43789c544ae65ede3a486c9a` |
| `spec2026_708_sqlite_r_test_w04_skip400000_n5000.trace` | 5000 | 400000 | 5000 | 5000 | `94b9804e03b6daecdcec0792c7420784c483f7c485c9bc4368e60cc4587d6c09` |
| `spec2026_721_gcc_r_test_w00_skip10000_n10000.trace` | 10000 | 10000 | 10000 | 10000 | `9a2960abeb6cde5323552dcf7bc9e58acafa0af43e97ada58edbca70e3b47d86` |
| `spec2026_721_gcc_r_test_w01_skip50000_n5000.trace` | 5000 | 50000 | 5000 | 5000 | `8f447569dccd89b52593258572b77dbfd685e36e4c6d4bafb981b10c4f36595c` |
| `spec2026_721_gcc_r_test_w02_skip100000_n5000.trace` | 5000 | 100000 | 5000 | 5000 | `1481a9af40a2724bc244e805612daf23d71fb0a93a72f130d4cd8723d851c9e8` |
| `spec2026_721_gcc_r_test_w03_skip200000_n5000.trace` | 5000 | 200000 | 5000 | 5000 | `d7e10e8a49067f442cd101274aa2bda2b62d5ca9f10d3d5eaf0e39084e92b73b` |
| `spec2026_721_gcc_r_test_w04_skip400000_n5000.trace` | 5000 | 400000 | 5000 | 5000 | `ead9d16d9150633030feb8a9a82fc9b75a2fa70f19d6d1f96fe2512cf8cbe7fe` |
| `spec2026_767_nest_r_test_w00_skip10000_n10000.trace` | 10000 | 10000 | 10000 | 10000 | `ab3cece5c983f63ee7ab41ab62cb1fb7c6fb9d02b9d243cb9bb21ab4692e2987` |
| `spec2026_767_nest_r_test_w01_skip50000_n5000.trace` | 5000 | 50000 | 5000 | 5000 | `2aeab176813bd9a577d17f96c60a8d5132965d411264b515153f63e6817a8af0` |
| `spec2026_767_nest_r_test_w02_skip100000_n5000.trace` | 5000 | 100000 | 5000 | 5000 | `cc39372f101c8bddedea72f1f6379bbe2cb8a76dcf2d7d7f01caab429062e131` |
| `spec2026_767_nest_r_test_w03_skip200000_n5000.trace` | 5000 | 200000 | 5000 | 5000 | `1d5492458ee0d92517b556d88e583579201c2afbaa3456dc8dc56c1f405a553c` |
| `spec2026_767_nest_r_test_w04_skip400000_n5000.trace` | 5000 | 400000 | 5000 | 5000 | `5b9e291e0ff2f1751b14b7c5e01235209ebb9d0d5d0d9bc2b9a02b723c7b7baa` |
| `spec2026_777_zstd_r_test_w00_skip10000_n10000.trace` | 10000 | 10000 | 10000 | 10000 | `e32fc5b9fb30edb0ece6236aaa1108159d46881cfdb353482ca9ace276c35a63` |
| `spec2026_777_zstd_r_test_w01_skip50000_n5000.trace` | 5000 | 50000 | 5000 | 5000 | `96b46c71cf98bc9b1471b666ccbb6daebebcb1ecce526aeac313060c11eb2ac0` |
| `spec2026_777_zstd_r_test_w02_skip100000_n5000.trace` | 5000 | 100000 | 5000 | 5000 | `3e8b9a2d72faa0d84da0735812bc5c798d50d47d01ce5cd094053f345d6f8c65` |
| `spec2026_777_zstd_r_test_w03_skip200000_n5000.trace` | 5000 | 200000 | 5000 | 5000 | `81b2a3ec67a874b83a1b521d5a743b11a71b11e7b9d3feaee234c364876224c4` |
| `spec2026_777_zstd_r_test_w04_skip400000_n5000.trace` | 5000 | 400000 | 5000 | 5000 | `7afab0ca928947442111e2b39739e803c493d115cd1717486e8708a0eeab4c84` |

## 历史 Replay 结果（无效）

20 个样本全部通过以下四个 cache 配置 replay：

- `direct_mapped_vc4`
- `two_way_vc4`
- `two_way_vc8`
- `next_line_prefetch_vc4`

全部 80 个 Icarus replay 日志都报告 `ALL TESTS PASSED`。由于这些样本从真实
程序执行中段开始，不包含完整初始内存镜像，replay 使用
`+TRACE_SKIP_LOAD_CHECKS` 关闭 load-data 检查。

| benchmark | config | accesses | hit rate | victim hit rate | mem/access | cycles/access | prefetch accuracy | useful | useless | pollution |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 708.sqlite_r | direct_mapped_vc4 | 30000 | 0.4808 | 0.1097 | 0.5933 | 7.58 | 0.0000 | 0 | 0 | 0 |
| 708.sqlite_r | two_way_vc4 | 30000 | 0.5762 | 0.0586 | 0.5319 | 7.22 | 0.0000 | 0 | 0 | 0 |
| 708.sqlite_r | two_way_vc8 | 30000 | 0.5762 | 0.0912 | 0.4865 | 7.01 | 0.0000 | 0 | 0 | 0 |
| 708.sqlite_r | next_line_prefetch_vc4 | 30000 | 0.5829 | 0.0579 | 0.8150 | 9.42 | 0.2011 | 1647 | 6543 | 5384 |
| 721.gcc_r | direct_mapped_vc4 | 30000 | 0.5057 | 0.0797 | 0.6027 | 7.60 | 0.0000 | 0 | 0 | 0 |
| 721.gcc_r | two_way_vc4 | 30000 | 0.5824 | 0.0463 | 0.5452 | 7.27 | 0.0000 | 0 | 0 | 0 |
| 721.gcc_r | two_way_vc8 | 30000 | 0.5824 | 0.0779 | 0.5017 | 7.06 | 0.0000 | 0 | 0 | 0 |
| 721.gcc_r | next_line_prefetch_vc4 | 30000 | 0.5960 | 0.0502 | 0.8037 | 9.32 | 0.2214 | 1745 | 6137 | 5341 |
| 767.nest_r | direct_mapped_vc4 | 30000 | 0.4849 | 0.0780 | 0.6317 | 7.74 | 0.0000 | 0 | 0 | 0 |
| 767.nest_r | two_way_vc4 | 30000 | 0.5672 | 0.0530 | 0.5517 | 7.31 | 0.0000 | 0 | 0 | 0 |
| 767.nest_r | two_way_vc8 | 30000 | 0.5672 | 0.0889 | 0.5000 | 7.07 | 0.0000 | 0 | 0 | 0 |
| 767.nest_r | next_line_prefetch_vc4 | 30000 | 0.5646 | 0.0435 | 0.8954 | 9.91 | 0.1787 | 1662 | 7636 | 6494 |
| 777.zstd_r | direct_mapped_vc4 | 30000 | 0.6226 | 0.0806 | 0.4419 | 6.90 | 0.0000 | 0 | 0 | 0 |
| 777.zstd_r | two_way_vc4 | 30000 | 0.6976 | 0.0437 | 0.3865 | 6.59 | 0.0000 | 0 | 0 | 0 |
| 777.zstd_r | two_way_vc8 | 30000 | 0.6976 | 0.0796 | 0.3353 | 6.35 | 0.0000 | 0 | 0 | 0 |
| 777.zstd_r | next_line_prefetch_vc4 | 30000 | 0.7097 | 0.0417 | 0.5829 | 8.10 | 0.2175 | 1268 | 4563 | 3724 |

## 历史结论（不得按 benchmark 引用）

- 在四条带旧 benchmark 标签的 mixed-system stream 中，从 direct-mapped
  VC4 切到 two-way VC4 使测得 hit rate 变化 +7.5 到 +9.5 个百分点，
  并降低了测得 memory traffic。这些变化不能归因到所标程序。
- Victim cache 从 VC4 增加到 VC8 不改变 L1 hit rate，但提高 victim-hit rate，
  并让四个无效标签组的每次 demand memory access 降低约 0.044 到 0.052。
- 当前 direct-L1D next-line prefetch 策略在这些 mixed stream 上总体有害。
  相对 two-way VC4，它带来 -0.26 到 +1.36 个百分点的 hit-rate 变化，却让每次
  demand memory access 增加 +0.196 到 +0.344，并让每次 access cycle 增加
  +1.51 到 +2.60。
- 带旧 `767.nest_r` 标签的 mixed stream 在该无效表中出现最大负向
  delta：memory/access 从 0.5517 变为 0.8954，cycles/access 从 7.31 变为
  9.91。这不能可靠说明 `767.nest_r` 本身的行为。
