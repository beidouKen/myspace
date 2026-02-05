# 运维说明 (OPERATIONS)

## 环境变量

详见 **[ENVIRONMENT.md](../ENVIRONMENT.md)**：MODEL_DIR、OUTPUTS_DIR、PORT、队列与超时、默认推理参数、日志与输出、BACKEND_URLS 等。

## 输入图像预处理语义 (Gateway)

img2img (`/v1/images/edits`) 对输入图片执行统一的合规化处理，确保后端模型获得一致的输入。

**规则顺序：**
1. **RGB 转换**：强制转为 RGB 格式。
2. **等比缩放**：
   - 若 `max(W, H) > MAX_SIDE`，则按比例缩放到 `max(W', H') = MAX_SIDE`。
   - 否则保持原尺寸。
3. **倍数补边 (Pad)**：
   - 向上取整到 `REQUIRE_MULTIPLE` 的倍数：`W_final = ceil(W/MULTIPLE)*MULTIPLE`。
   - 居中粘贴到黑色背景，**不裁剪、不拉伸**。
   - 最终约束：`max(final_side) <= MAX_SIDE` (若 PAD 后超过 MAX_SIDE，预处理逻辑会自动调整缩放目标以满足此约束)。

**严格模式 (`STRICT_IMAGE_SIZE=1`)：**
- 若原始尺寸不满足 `倍数约束` 或 `最长边约束`，直接拒绝 (400 Bad Request)。
- Error Code: `invalid_image_size`。

**相关环境变量：**
- `REQUIRE_MULTIPLE` (默认 64)
- `MAX_SIDE` (默认 1024)
- `AUTO_RESIZE` (默认 1, 开启自动修正)
- `STRICT_IMAGE_SIZE` (默认 0, 关闭严格拒绝)

**验收方法：**
运行 `cli_tests/bin/85_img2img_validation.sh`，脚本会自动生成测试用例并验证 Gateway 日志中的 `final_size` 和 `action`。

## 幂等与去重语义 (Idempotency & Deduplication)

Gateway 在进程内实现请求幂等/去重，避免客户端因超时、失败、重试或轮询产生多个独立推理任务，保证同一语义请求只对应一个任务。

### 幂等键来源

- **推荐**：客户端在请求头中提供 **Idempotency-Key**（大小写不敏感）。同一 Key 的重复请求会复用同一任务或结果。
- **未提供 Key 时**：Gateway 根据「规范化后的请求体」计算 **fingerprint** 作为幂等键：
  - **txt2img**（`/v1/images/generations`）：至少包含 prompt、size、steps、n，以及若存在的 guidance/seed/model 等；字段排序/规范化后做稳定 hash。
  - **img2img**（`/v1/images/edits`）：除上述参数外，**必须包含输入图片内容指纹**（对预处理后的图片 bytes 做 hash；多图时按稳定顺序组合）。

### 去重行为

- **相同幂等键且状态为 pending/processing**：不再入队，直接返回**同一 task_id** 的任务对象/响应（与 `GET /v1/tasks/{id}` 语义一致）。
- **相同幂等键且状态为 completed**：直接复用完成结果（返回同样的 data/url 列表或同一 task_id 可查询到结果）。
- **相同幂等键且状态为 failed（或 expired）**：允许**重新创建任务**（避免永久卡死），并清理该键的旧映射。

### 映射生命周期与容量

- **TTL**：幂等映射在内存中保留一定时间（如 30～60 分钟）后自动清理，由 `IDEMPOTENCY_TTL_SEC` 控制。
- **容量上限**：最大条目数由 `IDEMPOTENCY_MAX_ITEMS` 控制；超出后按**最旧优先**（by 时间戳）淘汰，避免内存无限增长。
- 不依赖外部存储（无 Redis/DB），单容器内 1×Gateway 进程的进程内内存结构即可。

### 可观测性

- 结构化日志事件：**IDEMPOTENCY_HIT**（含 key 截断、task_id、status、hit_type：inflight/completed）、**IDEMPOTENCY_MISS**。
- **GET /metrics** 中提供 `idempotency_hits`、`idempotency_misses` 计数，可作为验收证据。

**验收方法：** 运行 `cli_tests/bin/86_idempotency_dedup.sh`，验证相同请求（无 Key 依赖 fingerprint、有 Key 依赖 header）不产生新 task，且 proof 中有 IDEMPOTENCY_HIT 证据。

## 默认 compat 与 prefer_async（工程兼容）

为兼容不支持 202 的调用方（如 OpenWebUI、部分 SDK/前端），服务采用**默认同步优先（compat 模式）**；能处理 202 的调用方可显式 **prefer_async** 获得异步语义。

### 默认 compat 模式（尽量 200）

- **`/v1/images/generations`**、**`/v1/images/edits`**、**`/v1/chat/completions`** 默认均采用「同步等待更长」策略，在对应超时阈值内尽量返回 **200 + 最终结果**（含图片 url）。
- 超时阈值由环境变量控制：
  - **IMAGES_SYNC_WAIT_TIMEOUT_SEC**（默认 300）：images/generations、images/edits 的同步等待上限。
  - **CHAT_SYNC_WAIT_TIMEOUT_SEC**（默认 300）：chat/completions 的同步等待上限。
- 当耗时超过对应阈值时，才返回 **202 Accepted**，响应体包含 `task_id`、`status`、`poll_url=/v1/tasks/{task_id}`；客户端可轮询 `GET /v1/tasks/{id}` 获取最终结果（不要求普通调用方必须处理 202）。

### 显式异步偏好（prefer_async）

- 若请求**显式携带 `prefer_async=true`**（请求体字段或请求头 `X-Prefer-Async: true`），则不进行长时间同步等待，**直接返回 202 + 任务句柄**。
- 能处理 202 的调用方建议使用 `prefer_async=true`；普通调用方无需关心，默认即得 200 路径。

### 幂等去重

无论同步/异步/重试，同一请求（相同幂等键）必须复用同一 **task_id**。

**验收方法：**  
- **Gate 93**：`cli_tests/bin/93_compat_default_returns_200.sh` — 设置 IMAGES/CHAT_SYNC_WAIT_TIMEOUT_SEC=300，发起 chat 与 images txt2img 请求，断言两者均为 200 且含可渲染图片 url；证据输出到 `cli_tests/out/proof_93.txt`。  
- **Gate 94**：`cli_tests/bin/94_prefer_async_returns_202.sh` — 同样请求但带 prefer_async=true，断言立即返回 202 + task_id + poll_url，轮询至 completed；证据输出到 `cli_tests/out/proof_94.txt`。

## stream 参数兼容说明

**`/v1/chat/completions`** 的 `stream=true` 在本服务中为**兼容参数**，不启用真 SSE 流式（服务端记录 `stream_requested=true`，但 `stream_effective=false`）。客户端（含 OpenWebUI）带 `stream=true` 时不会被拒绝，也不会收到 4xx/5xx。

- **长任务**：若在 **CHAT_SYNC_WAIT_TIMEOUT_SEC** 内未完成，统一返回 **202 Accepted**，响应体包含 `task_id`、`status`、`poll_url=/v1/tasks/{task_id}`；客户端应轮询 `GET /v1/tasks/{id}` 获取最终结果。
- **这不是失败**；重试会复用同一任务（幂等），同一请求无论 `stream=true` 或 `stream=false` 均命中同一 `task_id`。

## Chat Completions 与图片任务超时语义

**`/v1/chat/completions`** 在用于图片生成（txt2img/img2img）时，采用「同步等待」：网关会等待任务完成再返回聊天格式结果。若等待时间超过 **CHAT_SYNC_WAIT_TIMEOUT_SEC**（默认 300 秒），返回 **202 Accepted**（非 504），响应体含 `task_id`、`poll_url`。

### 行为说明

- **sync_wait_timeout ≠ task_failed**：等待超时仅表示本次 HTTP 响应不再阻塞，**任务仍在后端继续执行**，并非失败。
- 当触发超时时，接口返回 **202 Accepted**，响应体包含 **task_id**、**status**、**poll_url**。客户端可轮询直至 `status == completed`，再从任务结果中取 `output_urls` 或 `result` 得到图片。

### 与幂等的配合

同一请求（相同 prompt/参数）重试时，会命中幂等键并复用同一 **task_id**，不会产生新任务；重试后仍可轮询同一 task_id 拿到结果。

**验收方法：** 运行 `cli_tests/bin/87_chat_timeout_returns_202.sh`（建议以短 CHAT_SYNC_WAIT_TIMEOUT_SEC 启动以强制触发 202），断言返回 202、含 task_id 与 poll_url，轮询至 completed 且有 data/url；证据输出到 `cli_tests/out/proof_87.txt`。

## 健康检查

- **存活**：`GET http://<host>:8000/healthz` → 200 表示进程在。
- **就绪**：`GET http://<host>:8000/readyz` → 200 表示所有 backend 可用，可接收流量；503 表示未就绪。
- 编排与验收建议以 **/readyz** 为准。

## 如何确认运行中服务版本/特性

为保障镜像交付与验收对准正确版本，Gateway 在 **GET /healthz**（与 **GET /health**）的 JSON 中提供**版本/特性自证**字段，便于外部确定性识别当前进程是否包含指定能力（如 prefer_async）。

### 响应字段说明

- **build_id**：本次进程启动时生成（环境变量 `BUILD_ID` 若已设置则使用，否则为启动时间戳）。同一进程内不变；重启后变化。
- **features**：字符串数组，列出当前网关支持的特性标识，至少包含：`prefer_async`、`images_sync_wait_timeout`、`chat_sync_wait_timeout`、`idempotency`。**若 `features` 中包含 `prefer_async`，则当前网关已包含 prefer_async 能力**（默认 compat + 显式 prefer_async 返回 202）。
- **effective_config**：对象，包含当前生效的超时与同步相关配置，如 `IMAGES_SYNC_WAIT_TIMEOUT_SEC`、`CHAT_SYNC_WAIT_TIMEOUT_SEC`、`SYNC_WAIT_TIMEOUT_SEC`。

任何人只需调用 **GET /healthz** 并检查 `features` 是否包含 `prefer_async`，即可确认当前网关是否为新版本；无需猜测或依赖部署时间。

### Gate 95 的用途

**cli_tests/bin/95_gateway_rollout_verify.sh** 会请求 `/healthz`，断言 `features` 中包含 `prefer_async`，并记录 `build_id` 与 `effective_config` 到 `cli_tests/out/proof_95.txt`。若不包含则直接 **FAIL**，并提示「当前运行的仍是旧 Gateway，请重启/重新启动 start.sh」。  
Gate 94（prefer_async 返回 202）在执行 prefer_async 测试前会先运行 Gate 95；若 Gate 95 未通过，Gate 94 直接 FAIL，避免因旧进程导致的假失败。

## 日志

- 默认：`logs/gateway.log`、`logs/backend_0.log`、`logs/backend_1.log` 等，由 `start.sh` 重定向产生。
- 运行产物与临时日志不纳入版本库；`logs/`、`outputs/`、`cli_tests/out/` 可在 .gitignore 中忽略。

## 指标

- **GET /metrics**：Prometheus 格式，可被监控系统拉取。

## 安全与代理

- **API_KEY**：设置后需在请求头带 `Authorization: Bearer <KEY>`。
- **NO_PROXY**：start.sh 已设 localhost,127.0.0.1，保证网关与后端间不走外网代理。
