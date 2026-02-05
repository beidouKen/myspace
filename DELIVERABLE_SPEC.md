# 交付验收口径 (Deliverable Specification)

本文档定义平台镜像交付的验收口径与关键 proof 要求。

## 1. 验收范围

- **接口兼容性**：不破坏现有接口；00/70/90/95/96~99/100~103 脚本通过率保持。
- **一键验收**：`cli_tests/run_all_v2.sh` 按序执行 00、70、90、95、96、97、98、99、100、101、102、103，输出至 `cli_tests/out/`，并生成 `cli_tests/out/FINAL_DELIVERY_REPORT.md`。

## 2. 关键 Proof 要求

| 项目 | 验收标准 | Proof 位置 |
|------|----------|------------|
| **url-first 可下载** | `/v1/images/generations` 返回 `response_format=url` 时，`data[0].url` 存在且可下载为 PNG | `cli_tests/out/101_images_url_priority_proof.txt`、`101_downloaded.png` |
| **429 queue_full** | 队列满时返回 HTTP 429，body 为 OpenAI error envelope：`type=rate_limit_error`、`code=queue_full`、`param=null` | `cli_tests/out/102_queue_full_429_proof.txt` |
| **502 backend_unreachable** | 网关指向不可达后端时返回 502，`code=backend_unreachable` | `cli_tests/out/103_timeout_504_502_proof.txt` |
| **504 sync_wait_timeout** | 同步等待超时（hang 后端 + 短 SYNC_WAIT）返回 504，`code=sync_wait_timeout` | `cli_tests/out/103_timeout_504_502_proof.txt` |
| **504 task_timeout** | 任务/推理超时返回 504，`code=task_timeout`；默认优先真实 backend `INFERENCE_TIMEOUT_SEC=1` 触发；无 GPU 时仅可显式启用 `USE_SLOW_INFER_FALLBACK=1` 或 `--fallback` 使用 slow_infer_server 兜底，proof 中须标注 RUN_MODE | `cli_tests/out/103_timeout_task_timeout_proof.txt` |

## 3. 风险收口

- **103 Part C (504 task_timeout)**  
  - **默认**：使用真实 backend，通过 `INFERENCE_TIMEOUT_SEC=1` 触发推理超时 → 504 task_timeout。  
  - **兜底**：仅当显式启用（环境变量 `USE_SLOW_INFER_FALLBACK=1` 或 103 脚本参数 `--fallback`）时，使用 slow_infer_server 模拟超时；用于无 GPU 环境。  
  - proof/报告中必须标注运行模式：`RUN_MODE=real_backend` 或 `RUN_MODE=slow_infer_fallback`。

## 4. 版本与回滚

- 版本号见项目根目录 `VERSION` 文件（语义化版本或日期版本，可回滚）。
- 变更记录见 `CHANGELOG.md`。

## 5. 启动自检

- `start.sh` 启动前须自检：`MODEL_DIR` 存在、`OUTPUTS_DIR` 可写；失败即 `exit 1` 并打印明确错误；启动成功后仍打印有效配置摘要。

---

## 关键段落（交付用）

- **验收范围**：接口不破坏；`cli_tests/run_all_v2.sh` 按序跑 00/70/90/95/96~99/100~103，输出至 `cli_tests/out/`，生成 `FINAL_DELIVERY_REPORT.md`。
- **关键 Proof**：url-first 可下载（101）；429 queue_full（102）；502 backend_unreachable、504 sync_wait_timeout、504 task_timeout（103 A/B/C）；103 Part C 默认真实 backend `INFERENCE_TIMEOUT_SEC=1`，兜底仅 `USE_SLOW_INFER_FALLBACK=1` 或 `--fallback`，proof 标注 RUN_MODE。
- **版本**：`VERSION` + `CHANGELOG.md` 可回滚。
- **自检**：`start.sh` 自检 MODEL_DIR/OUTPUTS_DIR，失败 exit 1，成功打印配置摘要。
