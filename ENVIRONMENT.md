# 环境配置一本通 (ENVIRONMENT)

本文档汇总 GLM-Image 服务所需的环境变量、自检与默认值。

## 必须项 (Required for Startup)

| 项 | 说明 | 自检 |
|----|------|------|
| **MODEL_DIR** | 模型权重目录，必须存在 | `start.sh` 启动时检查目录存在，否则 `exit 1` 并打印错误 |
| **OUTPUTS_DIR** | 生成图片输出目录，必须可写 | `start.sh` 启动时 `mkdir -p` 并检查可写，否则 `exit 1` |

未设置时使用默认值（见下表）；自检失败即退出并提示设置正确路径。

## 端口与进程

| 变量 | 默认 | 说明 |
|------|------|------|
| `PORT` | 8000 | 网关 HTTP 端口 |
| `BACKEND_PORT_START` | 8001 | 后端起始端口；多 GPU 时依次 8001、8002、… |

- **CUDA_VISIBLE_DEVICES**：服务 **不覆盖** 外部已设置值，仅据此决定 backend 数量与设备分配。  
  - 例：`CUDA_VISIBLE_DEVICES=0` → 1 个 backend；`0,1` → 2 个 backend。  
  - 未设置时由 `start.sh` 通过 nvidia-smi 自动检测。

## 队列与超时

| 变量 | 默认 | 说明 |
|------|------|------|
| `QUEUE_SIZE` | 100 | 网关全局队列容量；满时返回 429 queue_full |
| `TASK_TIMEOUT_SEC` | 300 | 任务最大存活时间（排队+推理），超时返回 504 task_timeout |
| `SYNC_WAIT_TIMEOUT_SEC` | 120 | 旧版同步等待上限（仍可读）；实际由下述 IMAGES/CHAT 覆盖 |
| `IMAGES_SYNC_WAIT_TIMEOUT_SEC` | 300 | **图片接口**（/v1/images/generations、/v1/images/edits）同步等待上限（秒）；超时返回 202 + task_id + poll_url，不返回 504 |
| `CHAT_SYNC_WAIT_TIMEOUT_SEC` | 300 | **Chat**（/v1/chat/completions）同步等待上限（秒）；超时返回 202 + task_id + poll_url，不返回 504 |
| `INFERENCE_TIMEOUT_SEC` | 180 | 单次推理超时（backend），超时网关映射为 504 task_timeout |

## 输入图像预处理 (img2img)

| 变量 | 默认 | 说明 |
|------|------|------|
| `REQUIRE_MULTIPLE` | 64 | 输入宽高必须为该值的倍数，否则补边 (Pad) |
| `MAX_SIDE` | 1024 | 输入最长边限制，超限则等比缩小 |
| `AUTO_RESIZE` | 1 | 1=自动修正（缩放+补边）；0=不修正 |
| `STRICT_IMAGE_SIZE` | 0 | 1=严格模式，不合规直接返回 400 invalid_image_size；0=宽松 |

## 默认推理参数

| 变量 | 默认 | 说明 |
|------|------|------|
| `DEFAULT_STEPS` | 45 | 默认步数 |
| `DEFAULT_SIZE` | 1024x1024 | 默认分辨率 |
| `DEFAULT_GUIDANCE` | 4.0 | CFG scale |
| `MIN_STEPS` / `MAX_STEPS` | 20 / 80 | 步数范围 |
| `DEFAULT_STRENGTH` | 0.65 | 图生图默认强度 |
| `MIN_STRENGTH` / `MAX_STRENGTH` | 0.1 / 0.95 | 强度范围 |

## 幂等与去重 (Gateway)

| 变量 | 默认 | 说明 |
|------|------|------|
| `IDEMPOTENCY_TTL_SEC` | 1800 | 幂等映射在内存中的 TTL（秒），超时条目被清理；约 30 分钟 |
| `IDEMPOTENCY_MAX_ITEMS` | 1000 | 幂等表最大条目数，超出后按最旧优先淘汰 |

详见 **docs/OPERATIONS.md** 中「幂等与去重语义」章节。

## 日志与输出

| 变量 | 默认 | 说明 |
|------|------|------|
| `OUTPUTS_DIR` | `./outputs` | 生成图存储目录，网关静态托管 `/outputs/{id}.png` |
| `OUTPUT_TTL_SEC` | 3600 | 生成文件在盘上的 TTL（秒）后清理 |
| 日志 | `logs/` | `start.sh` 将 gateway/backend 输出写入 `logs/gateway.log`、`logs/backend_*.log` |

## 平台与可选注入

| 变量 | 说明 |
|------|------|
| `BACKEND_URLS` | 可选；平台注入时指定后端 URL 列表（逗号分隔），覆盖 start.sh 自动构造 |
| `PLATFORM_MODE` | 1（默认）为 async-first；0 为 dev 行为 |
| `MODEL_ID` | 覆盖 /v1/models 中的模型 ID，默认 glm-image |
| `API_KEY` | 设置后要求请求头 `Authorization: Bearer <KEY>` |
| `NO_PROXY` | start.sh 中设为 localhost,127.0.0.1，保证网关与后端不走外网代理 |

## 103 验收 Part C（504 task_timeout）兜底

- **默认**：真实 backend + `INFERENCE_TIMEOUT_SEC=1` 等触发 504 task_timeout。
- **无 GPU 兜底**：仅当显式启用 `USE_SLOW_INFER_FALLBACK=1` 或 103 脚本带 `--fallback` 时使用 slow_infer_server；proof/报告中须标注 `RUN_MODE=slow_infer_fallback`。
