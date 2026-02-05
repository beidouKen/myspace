# 验收说明 (TESTING)

## 运行验收（封板）

```bash
./cli_tests/run_all_v2.sh
```

- 主服务需已启动（`./start.sh`），且 **8000/8001** 在监听。
- 脚本按序执行：00 → 70 → 90 → 95 → 96 → 97 → 98 → 99 → 100 → 101 → 102 → 103。
- 输出与 proof 写入 `cli_tests/out/`；最终报告为 **`cli_tests/out/FINAL_DELIVERY_REPORT.md`**，**ALL PASS** 为交付证据。

## 各脚本验证内容

| 脚本 | 验证内容 |
|------|----------|
| 00_check.sh | 环境与依赖基础检查 |
| 70_run_default_stable_and_save.sh | 默认配置文生图并落盘 |
| 90_chat_adapter_smoke.sh | Chat 适配基础通路 |
| 95_chat_img2img_smoke.sh | Chat 图生图通路 |
| 96_ready_probe.sh | /readyz 返回与结构 |
| 97_openai_error_format.sh | 错误响应 OpenAI envelope |
| 98_async_first_platform_flow.sh | 异步 task_id 与状态轮询 |
| 99_idempotency_smoke.sh | Idempotency-Key 去重 |
| 100_probe_alias_compat.sh | 别名/兼容探针 |
| 101_images_url_priority.sh | url-first：data[0].url 存在且可下载 |
| 102_queue_full_429.sh | 队列满时 429，code=queue_full |
| 103_timeout_504_and_backend_502.sh | 502 backend_unreachable、504 sync_wait_timeout、504 task_timeout |

## Proof 文件含义

- **101**：`101_images_url_priority_proof.txt`、`101_downloaded.png` — url-first 可下载证明。
- **102**：`102_queue_full_429_proof.txt` — 429 body 含 type=rate_limit_error、code=queue_full、param=null。
- **103**：`103_timeout_504_502_proof.txt`、`103_timeout_task_timeout_proof.txt` — 502/504 场景与 RUN_MODE 标注。

## 已废弃脚本

- `cli_tests/archive/run_all.sh`：已废弃，请使用 **run_all_v2.sh**。
