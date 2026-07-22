# 项目任务

英文 `docs/tasks.md` 是权威版本。

## Baseline

- [x] 定义 blocking ready/valid CPU 和缓存行内存接口。
- [x] 实现 RV64 load/store 请求字段、64 位地址和 XLEN 数据宽度。
- [x] 实现可配置 direct-mapped / 2-way L1D。
- [x] 实现同步 tag/data SRAM wrapper。
- [x] 实现 write-back / write-allocate FSM。
- [x] 实现全相联 victim cache 和 swap 路径。
- [x] 验证 dirty victim replacement write-back。
- [x] 实现 next-line prefetch baseline。
- [x] 增加运行时和外部 prefetch adaptation 接口。
- [x] 增加硬件事件脉冲和累计计数器。
- [x] 完成 direct-mapped、2-way 和 prefetch Icarus 回归。
- [x] 完成架构、使用、workload 和文献审查文档。

## 验证与高级功能

### 自适应 Direct-L1 Prefetcher（P0–P3）

- [x] 在 `PREFETCH_POLICY=0` 后保留原 blocking next-line engine，将
  optimized policy level 3 保留为研究 wrapper 默认，并提供默认关闭
  prefetch 的部署 wrapper。
- [x] 增加真正的 zero-bubble、sequential 和固定 gap 1/2/4/8 producer。
- [x] 将 replay sidecar 与守恒检查升级为 schema 3，同时保留 schema-2
  输入兼容性。
- [x] 增加 candidate/admit/issue/return/install/use/evict/cancel/discard/merge、
  suppression、controller、shadow、write-back 归因和 blocked-cycle 可观测性。
- [x] 实现 P1 安全 cold insertion、每 set 一条 unused line quota、dirty guard、
  response revalidation、VC bypass、TTL、独立 external skid、idle guard 和
  token admission。
- [x] 实现 P2 四 entry Gaze-lite 相邻 stream detection 和带滞回的
  OFF/PROBE/ON controller。
- [x] 实现 P3 demand-only tag/dirty shadow L1/VC 与单 metadata-only PF MSHR，
  包括 hit-under-prefetch、load/store merge 和有界 discard。
- [x] 增加可在综合时常量折叠的部署特性参数，以及默认关闭 prefetch 的
  `l1d_cache_deploy` 和 `l1d_fpga_harness` 接缝。
- [x] 寄存 prefetch S0 candidate capture，并在下级内存 backpressure 和
  candidate turnover 期间保持稳定的 S1 PF-MSHR issue identity；同时将
  issue/token 记账绑定到显式的 lower-port ownership grant。
- [x] 通过 A/B 综合比较 swap-register 与 VC-lookup formatter，并保留可使
  OOC timing 收敛的 swap-register 实现。
- [x] 为 stream/controller、安全 insertion、shadow attribution、zero-bubble merge、
  TTL、EWMA、response backpressure、runtime disable 与 discard/revalidation 路径
  增加定向和 randomized Icarus 回归。
- [x] 完成并发布最终 25-window legacy/P1/P2/P3 zero-bubble campaign，
  并检查所有 performance 与 bandwidth 门槛。
- [x] 完成 sequential、fixed-gap 1/2/4/8、latency-0/always-ready 和
  latency-8/random-backpressure paired sensitivity campaign。
- [x] 运行部署收尾 Vivado campaign：15 份 XSim log、八种 OOC synthesis
  配置、四次相互独立的 post-route implementation，以及由 evidence manifest
  验证的 121 份下载 artifact。

- [x] 增加 deterministic randomized golden-memory scoreboard。
- [x] 验证 RV64 load/store size、符号/零扩展和未对齐错误。
- [x] 验证 CPU/external/next-line 在重叠请求下的 handshake 必须互斥。
- [x] 验证 64 位高地址 tag 和 RV64 trace replay 格式。
- [x] 检查 backpressure 下 CPU response 和下级内存请求稳定性。
- [x] 增加 handshake stability 和 line uniqueness 仿真检查。
- [x] 验证 4-entry 和 8-entry victim cache 配置。
- [x] 增加确定性 synthetic workload boundary 回归和 CSV 输出。
- [x] 增加用于 Phase 3 workload 的 class-based Vivado OOP harness。
- [x] 增加确定性生成的 Phase 3 matrix 和 pointer trace。
- [x] 增加带 read/write byte 与 latency summary 的 Phase 3 workload record。
- [x] 为 Vivado workload 增加 watchdog、protocol 和 duplicate-line failure 报告。
- [ ] 增加零 entry victim cache bypass 配置。
- [ ] 增加 LRU victim replacement 选项。
- [ ] 增加独立 prefetch buffer 放置方案。
- [x] 增加 paired true-pollution 分析和分开统计的 demand/prefetch 内存带宽
  测量；RTL displacement counter 仍明确作为 proxy。
- [x] 增加独立 candidate/accept/issue/return/install/merge/discard prefetch
  lifecycle counter 与 event record。
- [ ] 增加逐 prefetch transaction identity 和 candidate-to-issue-to-return
  latency distribution。
- [x] 增加 SPEC CPU 2017/2026 区间 trace replay driver。
- [x] 运行历史 `782.lbm_r` extraction/replay 流程检查（不是权威 benchmark
  证据）。
- [x] 捕获并 replay 旧版 20-window/四配置 SPEC matrix（历史全系统混合
  trace，不能归因到 benchmark）。
- [x] 在 dynamic RV64 smoke workload 上验证目标进程、vCPU、privilege 和
  address-space 归因。
- [x] 输出统一 workload schema 并实现严格 paired-run 分析。
- [x] 通过 paired replay sidecar 增加逐 demand true-pollution 归因。
- [x] 增加逐 demand present/accept/response latency 和 prefetch lifecycle sidecar
  分析。
- [x] 使用验证后的 process-scoped 流程 capture 并 replay 获许可
  SPEC 区间。
- [x] 对有效 window 分类，并在 `docs/evidence/2026-07-13/` 发布
  paired metric 与图表。
- [x] 在 `docs/evidence/2026-07-22-prefetch-ppa/` 发布 2026-07-22
  deployment-gate replay、sensitivity、OOC、post-route timing 和
  activity-power 证据。

## Vivado 与 PPA

- [x] 对 direct-mapped 和 2-way 配置运行 RV64 Vivado 仿真。
- [x] 对 VC4、VC8、next-line prefetch 和 trace replay 运行 Vivado OOP workload 矩阵。
- [ ] 检查所有 hit、miss、swap、fill 和 write-back 波形。
- [x] 捕获代表性的通过 prefetch-on VCD artifact。
- [x] 对 RV64 RTL 综合并记录 LUT、FF、推断存储和时序报告。
- [x] 添加基线 10 ns 时钟约束。
- [x] 根据 RV64 Vivado STA 报告计算近似综合后 Fmax。
- [x] 运行 RV64 vectorless FPGA power estimation 并记录其假设。
- [x] 运行 implementation/post-route timing 和基于 activity 的功耗分析。
- [x] 比较 baseline、victim cache、prefetch 和组合配置。
- [x] 使用相同 L1 容量及完全一致的 simulation/PPA geometry 重跑比较。

## 发布范围

仓库保持公开。进一步的 Git 历史、cached ref、LFS object 或 fork 清理已明确
不属于本次修复计划；获许可 capture artifact 继续保存在被忽略的私有
build directory 中。
