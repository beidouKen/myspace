# GLM-Image 镜像式模型服务

**这不是 Web 前端应用，而是镜像式模型推理服务**：提供 OpenAI 兼容的图像生成与编辑 API，供网关/平台或 CLI 调用。主线能力为 txt2img、img2img、队列与健康检查。

## 快速启动（最少命令）

```bash
./start.sh
```

启动后等待就绪：

```bash
curl -sS http://127.0.0.1:8000/readyz
# 等到返回 200
```

## 验收方式（交付证据）

```bash
./cli_tests/run_all_v2.sh
```

- **最终交付证据**：`cli_tests/out/FINAL_DELIVERY_REPORT.md` 显示 **ALL PASS**。
- 禁止在仓库中使用 pkill/killall/pgrep+kill 宽杀主服务；`run_all_v2.sh` 会做静态扫描。

## API 概览

| 端点 | 说明 |
|------|------|
| **POST** `/v1/images/generations` | 文生图（OpenAI 兼容 JSON） |
| **POST** `/v1/images/edits` | 图生图（Multipart，image 必填） |
| **GET** `/v1/tasks/{task_id}` | 查询异步任务状态 |
| **POST** `/v1/tasks/{task_id}/cancel` | 取消任务 |
| **GET** `/v1/models` | 列出模型 |
| **POST** `/v1/chat/completions` | Chat 适配（OpenWebUI 等，txt2img/img2img 映射） |
| **GET** `/healthz` | 存活探针 |
| **GET** `/readyz` | 就绪探针（所有 backend 加载完成才 200） |
| **GET** `/metrics` | Prometheus 指标 |

- **返回格式原则**：images 响应 **url-first**（`data[0].url` 必填，b64 可选）；错误为 OpenAI error envelope（`message` / `type` / `code` / `param`）。

## 目录说明

| 路径 | 说明 |
|------|------|
| `app/gateway/` | 网关：路由、队列、/v1/*、healthz/readyz/metrics |
| `app/backend/` | 推理后端：单 GPU 串行推理 |
| `cli_tests/bin/` | 验收脚本（00/70/90/95/96~103） |
| `cli_tests/assets/` | 测试用固定小图（如 img2img） |
| `cli_tests/out/` | 运行输出目录（proof、FINAL_DELIVERY_REPORT.md），仓库默认空 |
| `cli_tests/archive/` | 已废弃脚本（如 run_all.sh） |
| `outputs/` | 网关静态托管生成图，运行产物，默认空 |
| `logs/` | 运行时日志，默认空 |
| `docs/` | 架构、API、验收、运维说明；`docs/archive/` 为历史文档 |

## 常见环境变量

| 变量 | 说明 |
|------|------|
| `MODEL_DIR` | 模型权重目录（必须存在） |
| `OUTPUTS_DIR` | 生成图输出目录（必须可写） |
| `PORT` | 网关端口，默认 8000 |
| `BACKEND_PORT_START` | 后端起始端口，默认 8001 |
| `QUEUE_SIZE` | 网关队列容量，默认 100 |
| `TASK_TIMEOUT_SEC` / `SYNC_WAIT_TIMEOUT_SEC` | 任务/同步等待超时 |
| `CUDA_VISIBLE_DEVICES` | 不覆盖，仅用于决定 backend 数量与设备 |

详见 **[ENVIRONMENT.md](ENVIRONMENT.md)**。

## 文档索引

- [ENVIRONMENT.md](ENVIRONMENT.md) — 环境配置、队列、超时、默认参数
- [DELIVERABLE_SPEC.md](DELIVERABLE_SPEC.md) — 交付验收口径与 proof 要求
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Gateway/Backend、队列、端口
- [docs/API.md](docs/API.md) — 接口说明与示例
- [docs/TESTING.md](docs/TESTING.md) — 如何运行验收、proof 含义
- [docs/OPERATIONS.md](docs/OPERATIONS.md) — 健康检查、日志、运维

## 版本与变更

- 版本号：根目录 `VERSION`
- 变更记录：`CHANGELOG.md`
