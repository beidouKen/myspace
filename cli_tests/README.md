# CLI Test Suite

本目录为 GLM-Image 服务的命令行验收脚本。

## 结构

- **bin/**：可执行测试脚本（00/70/90/95/96~103 等）。
- **out/**：运行输出目录（proof、FINAL_DELIVERY_REPORT.md），仓库默认空，由 `run_all_v2.sh` 写入。
- **assets/**：固定测试资源（如 img2img 用的小图）。
- **archive/**：已废弃脚本（如 run_all.sh），请使用 **run_all_v2.sh**。

## Requirements

- `curl`
- `python3` (for JSON parsing)
- `file` (for mime type check)
- The service running on `http://127.0.0.1:8000` (default).

## 封板验收（交付证据）

```bash
./run_all_v2.sh
```

- 主服务需已启动（`./start.sh`），8000/8001 在监听。
- 最终报告：`out/FINAL_DELIVERY_REPORT.md`，**ALL PASS** 为交付证据。
- 详见根目录 [docs/TESTING.md](../docs/TESTING.md)。

## 单脚本运行

可从项目根目录或本目录执行，脚本会自动解析路径。

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `BASE_URL` | `http://127.0.0.1:8000` | Gateway URL |
| `API_KEY` | (Empty) | Bearer Token for Auth |

### Scripts

1. **Check Health**:
   ```bash
   bash cli_tests/bin/00_check.sh
   ```

2. **Sync URL Generation**:
   ```bash
   bash cli_tests/bin/10_sync_url.sh
   ```

3. **Sync Base64 Generation**:
   ```bash
   bash cli_tests/bin/11_sync_b64.sh
   ```

4. **Async Workflow**:
   ```bash
   bash cli_tests/bin/20_async_flow.sh
   ```

5. **Batch Load Test**:
   ```bash
   bash cli_tests/bin/30_batch_submit.sh
   ```
