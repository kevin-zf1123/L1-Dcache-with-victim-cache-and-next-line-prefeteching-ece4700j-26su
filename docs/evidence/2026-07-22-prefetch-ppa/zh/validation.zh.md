# 验证记录（2026-07-22）

英文 [`../validation.md`](../validation.md) 为权威版本。所有命令都从仓库根目录
运行。为避免本地工作站超额占用，replay 与本地回归均串行执行。许可 trace、raw
sidecar、simulator log、远程连接细节和 Vivado 工作产物继续保存在被忽略的私有
build directory 中。

## Replay 与门禁验证

```bash
./scripts/run_feedback_replay_matrix.sh
```

编排器从头执行全部 26 个 campaign，最后输出 `MATRIX_ALL_PASS`。每个 campaign
都通过了精确 off/on pairing、workload schema、lifecycle conservation、watchdog、
protocol、duplicate-line 和 source-hash
检查。

一个针对 fixed-gap-4 的 sidecar 审计覆盖 5,028 个 demand。它观察到 1,425 个
candidate；这些 candidate 全部 admit，并都在 issue 前 cancel；另有 1,033 个因
unsafe 被抑制，392 个为 same-line coalesce。Sidecar 解析期间 candidate identity
保持稳定，审计通过。

随后在五个主 profile、P3-lite 参数 sweep、全部 sensitivity profile 和已验证
Vivado manifest 上运行总评估器：

```bash
python3 scripts/evaluate_prefetch_evidence.py \
  --replay legacy=build/spec2026/current-2026-07-22/main/legacy \
  --replay p1=build/spec2026/current-2026-07-22/main/p1 \
  --replay p2=build/spec2026/current-2026-07-22/main/p2 \
  --replay p3=build/spec2026/current-2026-07-22/main/p3 \
  --replay p3-lite=build/spec2026/current-2026-07-22/main/p3-lite \
  --main-replay p3-lite \
  --vivado-manifest build/vivado/evidence_manifest.json \
  --out-dir build/spec2026/current-2026-07-22/gate
```

该命令成功完成，并生成结构有效的总决策。`combined_gate_pass=false` 是测得的
设计结果，不是评估器错误：决策为
`DISABLE_DEPLOY_PREFETCH_STRUCTURAL_LIMIT`。因此部署 wrapper 默认保持关闭
prefetch。

## Vivado 验证

远程 runner 使用 Vivado 2024.2.1 和仓库中的 10 ns 约束。连接 secret 只提供给
当前进程，没有写入仓库文件、命令行、log、manifest 或公开 artifact。

Batch execution 以状态码 0 退出。收集器下载并扫描了 121 个 log/report 文件，
其中包括 15 份 XSim log、8 个 OOC synthesis 配置、4 次独立 implementation，
以及 vectorless 和 SAIF-backed power report。最终 `l1d-vivado-evidence-v3`
manifest 报告 `PASS`、finding 为零、download failure 为零且远程退出状态为零。
精确的 Vivado 2024.2 `[Timing 38-282]` setup-gate 消息仅因数值 timing report
会被单独评估而获准通过；任何其他 critical warning 仍是致命错误。

## 最终本地回归

| 命令 | 结果 |
| --- | --- |
| `./scripts/run_iverilog.sh` | PASS：baseline geometry、workload row、randomized scoreboard 和 81 项 prefetch-unit 检查 |
| `./scripts/run_p3_tests.sh` | PASS：62 项 PF-MSHR 检查、显式 lower-port 仲裁、zero-bubble merge 和 optimized edge/backpressure 场景 |
| `./scripts/run_deploy_tests.sh` | PASS：6 种 deployment/feature-ablation 配置 |
| `./scripts/run_vc_formatter_ab.sh` | PASS：VC-lookup 与 swap-stage formatter 模式 |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | PASS：97 项测试 |
| `bash -n scripts/run_feedback_replay_matrix.sh scripts/run_spec_trace_replay.sh scripts/run_deploy_tests.sh scripts/run_vc_formatter_ab.sh` | PASS |
| `python3 -m py_compile scripts/evaluate_prefetch_evidence.py scripts/publish_prefetch_evidence.py scripts/run_remote_vivado.py scripts/summarize_spec_replay.py` | PASS |

Icarus 反复输出的 `always_*` constant-select 消息是已知 simulator 限制。所有
自检仿真均以状态码 0 完成。
