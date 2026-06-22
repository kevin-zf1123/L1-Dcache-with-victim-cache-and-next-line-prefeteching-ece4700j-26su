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
- [x] 验证 64 位高地址 tag 和 RV64 trace replay 格式。
- [x] 检查 backpressure 下 CPU response 和下级内存请求稳定性。
- [x] 增加 handshake stability 和 line uniqueness 仿真检查。
- [x] 验证 4-entry 和 8-entry victim cache 配置。
- [x] 增加确定性 synthetic workload boundary 回归和 CSV 输出。
- [ ] 增加零 entry victim cache bypass 配置。
- [ ] 增加 LRU victim replacement 选项。
- [ ] 增加独立 prefetch buffer 放置方案。
- [ ] 增加真实 pollution、timeliness 和内存带宽测量。
- [x] 增加 SPEC CPU 2017/2026 区间 trace replay driver。
- [ ] 运行获许可的 SPEC trace extraction 和 workload 分类。

## Vivado 与 PPA

- [ ] 对 direct-mapped 和 2-way 配置运行 RV64 Vivado 仿真。
- [ ] 检查所有 hit、miss、swap、fill 和 write-back 波形。
- [ ] 对 RV64 RTL 综合并记录 LUT、FF、推断存储和时序报告。
- [x] 添加基线 10 ns 时钟约束。
- [ ] 根据 RV64 Vivado STA 报告计算近似综合后 Fmax。
- [ ] 运行 RV64 vectorless FPGA power estimation 并记录其假设。
- [ ] 运行 implementation/post-route timing 和基于 activity 的功耗分析。
- [ ] 比较 baseline、victim cache、prefetch 和组合配置。
