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
- [ ] 增加独立的 issue/fill/accept prefetch timeliness 测量。
- [x] 增加 SPEC CPU 2017/2026 区间 trace replay driver。
- [x] 运行历史 `782.lbm_r` extraction/replay 流程检查（不是权威 benchmark
  证据）。
- [x] 捕获并 replay 旧版 20-window/四配置 SPEC matrix（历史全系统混合
  trace，不能归因到 benchmark）。
- [x] 在 dynamic RV64 smoke workload 上验证目标进程、vCPU、privilege 和
  address-space 归因。
- [x] 输出统一 workload schema 并实现严格 paired-run 分析。
- [x] 通过 paired replay sidecar 增加逐 demand true-pollution 归因。
- [ ] 增加独立的逐 demand prefetch timeliness 分析。
- [x] 使用验证后的 process-scoped 流程 capture 并 replay 获许可
  SPEC 区间。
- [x] 对有效 window 分类，并在 `docs/evidence/2026-07-13/` 发布
  paired metric 与图表。

## Vivado 与 PPA

- [x] 对 direct-mapped 和 2-way 配置运行 RV64 Vivado 仿真。
- [x] 对 VC4、VC8、next-line prefetch 和 trace replay 运行 Vivado OOP workload 矩阵。
- [ ] 检查所有 hit、miss、swap、fill 和 write-back 波形。
- [x] 捕获代表性的通过 next-line prefetch VCD artifact。
- [x] 对 RV64 RTL 综合并记录 LUT、FF、推断存储和时序报告。
- [x] 添加基线 10 ns 时钟约束。
- [x] 根据 RV64 Vivado STA 报告计算近似综合后 Fmax。
- [x] 运行 RV64 vectorless FPGA power estimation 并记录其假设。
- [ ] 运行 implementation/post-route timing 和基于 activity 的功耗分析。
- [x] 比较 baseline、victim cache、prefetch 和组合配置。
- [x] 使用相同 L1 容量及完全一致的 simulation/PPA geometry 重跑比较。

## 发布范围

仓库保持公开。进一步的 Git 历史、cached ref、LFS object 或 fork 清理已明确
不属于本次修复计划；获许可 capture artifact 继续保存在被忽略的私有
build directory 中。
