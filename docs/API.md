# API 说明 (API)

OpenAI 兼容的图像生成与编辑接口，以及健康与指标端点。

## 图像生成与编辑

### POST /v1/images/generations

文生图，JSON body。

- **sync**：true 时同步等待并返回 `data[0].url`（及可选的 b64）；false 时立即返回 `task_id`，需再调 GET /v1/tasks/{id} 或轮询。
- **response_format**：`url`（默认）或 `b64_json`。响应 **url-first**：`data[0].url` 必填，b64 为可选回退。
- 其他参数：prompt、steps、size、seed 等，见请求体。

### POST /v1/images/edits

图生图，Multipart form-data。

- **image**（必填）、**mask**（可选）、**prompt**、**sync**、**strength**、**size**、**steps**、**seed** 等。

### GET /v1/tasks/{task_id}

查询异步任务状态与结果。

### POST /v1/tasks/{task_id}/cancel

取消未完成任务。

## 模型与 Chat 适配

### GET /v1/models

列出可用模型（如 glm-image）。

### POST /v1/chat/completions

Chat 适配（OpenWebUI 等）：根据 prompt 与消息内容映射到 txt2img 或 img2img；img2img 时 prompt 中需包含可下载的图片 URL 及关键词（如 img2img、edit、图生图）。

## 健康与指标

- **GET /healthz** — 存活，200 即进程在。
- **GET /readyz** — 就绪，所有 backend 可用才 200，否则 503。
- **GET /metrics** — Prometheus 格式指标。

## 错误格式

- 使用 OpenAI error envelope：`message`、`type`、`code`、`param`。  
- 例如 429 queue_full：`type=rate_limit_error`，`code=queue_full`，`param=null`。
