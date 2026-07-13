# L1 数据缓存、Victim Cache 与 Prefetch 文献审查

## 目的

本文档记录 baseline RTL 的研究依据。英文
`docs/literature_review.md` 是权威版本。公开论文和实现快照的本地副本
列在被 Git 忽略的 `ref/README.md` 中。

## Baseline L1 数据缓存

本项目查阅了 Rocket Chip 的 `DCache.scala`，重点参考同步 array 分阶段
访问、metadata、write-back、request replay，以及存储和控制路径分离。
Rocket 还包含 coherence 和更复杂的非阻塞集成，本 baseline 不直接复制
这些能力。

GS464E 论文及 Intel、Qualcomm 架构资料说明实际高性能 L1D 通常采用更高
相联度、多个访问通路和更复杂的缓存层次。这些资料用于确定规模和研究方向，
而不是直接作为 RTL 模板。

结论：同步 SRAM wrapper 配合多周期 FSM 是合理的 FPGA baseline，但不能
宣称商业处理器式单周期 L1 hit。应先完成 blocking baseline 测量，再增加
MSHR、replay queue、store buffer 或 hit-under-miss。

## Victim Cache

Jouppi 在 ISCA 1990 提出的核心语义是：

- 保存最近从 L1 驱逐的缓存行；
- L1 miss 时查询小型全相联 victim 结构；
- victim hit 时交换 victim 行和冲突的 L1 行。

当前 RTL 与此一致：保存完整缓存行地址、数据、valid、dirty 和 prefetched
metadata；执行全相联比较；victim hit 时交换；覆盖 dirty victim entry 前
先 write-back。

当前设计把原本主要面向 direct-mapped 的方法扩展到 2-way L1。结构上可行，
但收益必须实测，因为 L1 相联度提高后可由 victim cache 捕获的 conflict
miss 会减少。因此 workload 计划直接比较 direct-mapped 和 2-way 设计，
而不假定 victim cache 在两者中有相同收益。

当前简化包括：

- victim replacement 使用 round-robin，而非 LRU；
- victim rescue 经过 FSM 周期，不是为单周期路径优化的组合网络；
- 暂不支持零 victim entry bypass。

## Next-Line 与 Stream Prefetch

Jouppi 的工作也研究了 prefetch buffer 和 stream buffer。其中的关键
设计选择是 prefetch 数据放置位置：

- 独立 prefetch/stream buffer 减少直接污染 L1，但需要第二次查询和提升路径；
- 直接安装到 L1 在预测正确时延迟低，但可能驱逐有用 demand 数据。

冻结的 policy-0 RTL 是原始 one-block-lookahead next-line baseline：它与
ChampSim `next_line` 的候选生成一致，即观察 block `N` 后生成 `N+1`。
Optimized 默认则使用 4-entry Gaze-lite 相邻 stream detector、adaptive admission、
安全 cold direct-L1 insertion、shadow feedback 和单 PF MSHR。两者都保留 direct-L1
data placement，因此仍需 prefetched-line metadata 以及 useful/useless/displacement
event 来控制和测量 pollution。

Chen 和 Baer 的硬件 prefetch 研究及后续综述区分了 accuracy、
coverage、timeliness 和 bandwidth cost。只统计 useful prefetch 并不
充分。严格 paired replay 计算以下指标。历史 schema 2 使用结构性
timely/late proxy；schema 3 会独立记录 demand present/accept/response 与 PF
lifecycle event：

- `accuracy = useful prefetches / filled prefetches`；
- `L1 coverage = (baseline L1 misses - prefetch-on L1 misses) / baseline L1 misses`；
- legacy `lower_coverage = (baseline demand-owned reads - prefetch-on demand-owned
  reads) / baseline demand-owned reads`。存在 MSHR merge 时，必须把 merged
  PF-owned read 加回后才能解读 required physical read；
- `timeliness = timely useful / (timely useful + late useful)`，其中 late
  prefetch 指 demand 首次拉高 valid 时该 prefetch 仍在 flight；
- `bandwidth overhead = (prefetch-on bytes - baseline bytes) / baseline bytes`；
- true L1 pollution 是“baseline 为 L1 hit、prefetch-on 为 L1 miss”的逐 demand 事件；
- true lower-memory pollution 是“baseline 不读下级内存、prefetch-on demand 需要读下级内存”的逐 demand 事件。

所有比例在分母为 0 时必须记为 `N/A`，不能记为 0。同理，
`useful / fills` 特指 fill accuracy；merge-only P3 run 的 fill accuracy 可为
N/A，同时 `useful / issued` 为 100%。当前
`stat_prefetch_pollution` 只是压力 proxy，因为被 prefetch 移出 L1 的行
仍可能存在 victim cache 中。真正污染需要与关闭 prefetch 的同 trace 运行
逐访问配对；aggregate miss delta 只能说明净损益，不能识别具体污染事件。

## Adaptive 接口

Feedback-directed prefetch 和 Pythia 表明 prefetcher 应利用系统反馈，而
不是把单一策略硬编码在主 FSM 中。Gaze 进一步说明空间模式识别和
over-prefetch 抑制的价值。

因此 RTL 提供：

- `cfg_prefetch_enable`：运行时 master enable；
- `cfg_next_line_enable`：运行时 built-in next-line enable；
- `ext_prefetch_valid/ready/addr`：接入 stride、region、Gaze-like 或其他
  adaptive candidate generator；
- hit、miss、victim hit、write-back、prefetch fill/useful/useless/
  pollution/drop 的单周期事件；
- 用于离线分析和硬件控制环的累计计数器。

该接口现已接入实现的 Gaze-lite 相邻 stream detector 和轻量 feedback
controller。Candidate generation 仍是 metadata-only，CPU 和下级内存协议不变。

### 已实现的自适应 Direct-L1 策略

Optimized policy 用有界机制实现文献思路，不复制大型学习表：

- 四 entry stream table 仅确认相邻 `+1/-1` stream，使用两 entry candidate
  FIFO，保留 stream-generation 归因，candidate 在 16 次 demand 后过期，
  且不跨 4 KiB page；
- OFF/PROBE/ON controller 使用两 token bucket、1/16 PROBE/弱 ON rate、
  1/8 正常 ON rate、连续两个负 epoch 滞回和 512-demand OFF cooldown；
- direct-L1 insertion 是 cold insertion，并受 clean-victim 安全性、每 set 一条
  unused speculative line、response-time revalidation 和 unused-line VC bypass 约束；
- demand-only tag/dirty shadow L1/VC 在不复制 line data 的情况下提供在线
  causal help/pollution 分类；
- 单个 metadata-only PF MSHR 实现 hit-under-prefetch、同地址 load/store
  merge、立即 response capture 与有界 discard，同时保留一 outstanding
  lower-memory 协议。

Controller 评估以 cycle-like 为单位的 `saved` 和 `cost`。Penalty 初值为
8 cycles，使用 1/8 EWMA 校准。Level 2 通过统一 feedback 接口使用 raw
useful/pollution proxy；level 3 将该接口切换为 shadow causal event，并加入
late-merge credit、blocked demand cycle、speculative issue cost 和归因 write-back cost。

数据始终保持 direct-L1 放置。Stream table、candidate queue、shadow model 和
PF MSHR 只包含地址、tag、dirty bit、confidence、generation 与 control
metadata；返回数据只出现在普通 transient refill register 中。

## 当前 RTL 审查结论

已有文献支持的部分：

- victim hit 时全相联查询并交换；
- victim entry 被覆盖时延迟 dirty write-back；
- write-back 加 write-allocate；
- 同步 SRAM 与 metadata/control 分离；
- demand 优先于 best-effort prefetch；
- 显式 prefetched metadata 和反馈事件；
- 可替换的 prefetch candidate 接口。

当前实现已包含分开的 demand/prefetch 下级内存计数、完整 schema-3
lifecycle 归因、paired 逐 demand true-pollution 归因、在线 shadow causal
feedback、line-uniqueness assertion 和 randomized golden-memory reference model。
剩余工作是：

- 增加独立 prefetch buffer 放置方案，与直接 L1 安装对比；
- 将 lifecycle timing 扩展为多种 CPU timing model 下的完整分位数分布；
- 增加 victim entry 的 0/4/8 配置；零 entry 仍需 bypass 实现；
- 比较 round-robin 与 LRU victim replacement；
- 在现有 simulation assertion 之上增加 dirty-data-preservation formal property；
- 评估是否有必要增加多 demand MSHR；已实现的单 PF MSHR 故意不将
  demand cache 变为完全 non-blocking。

## Proposal 引用审查

- Jouppi、GS464E、Gaze 和 XiangShan 是相关技术来源；
- Intel 和 Qualcomm deck 是有价值的厂商一手资料，但不是同行评审论文；
- DeviceBeast 是二手规格网站，不应作为 Apple cache 结构的主要证据；
- Loongson manual 引用需要精确版本和稳定官方 URL；
- 教材应通过学校图书馆合法获取。

最终 proposal bibliography 应尽量用官方厂商资料或同行评审测量替换较弱
网页来源，并为会变化的网页补充访问日期。

## 主要链接

- [Jouppi victim cache, ISCA 1990](https://doi.org/10.1109/ISCA.1990.134547)
- [Chen and Baer hardware prefetching, IEEE TC 1995](https://doi.org/10.1109/12.381947)
- [Feedback Directed Prefetching, HPCA 2007](https://doi.org/10.1109/HPCA.2007.346185)
- [When Prefetching Works, TACO 2012](https://doi.org/10.1145/2133382.2133384)
- [Pythia, MICRO 2021](https://arxiv.org/abs/2109.12021)
- [Gaze, HPCA 2025](https://arxiv.org/abs/2412.05211)
- [XiangShan, MICRO 2022](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- [Rocket Chip DCache](https://github.com/chipsalliance/rocket-chip/blob/master/src/main/scala/rocket/DCache.scala)
- [ChampSim next-line prefetcher](https://github.com/ChampSim/ChampSim/tree/master/prefetcher/next_line)
