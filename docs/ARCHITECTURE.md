# 架构说明 (ARCHITECTURE)

## Gateway / Backend 拆分

- **Gateway**（`app/gateway/main.py`）：对外 HTTP 入口，负责路由、队列、OpenAI 兼容格式、健康与就绪探针、Prometheus 指标。
- **Backend**（`app/backend/main.py`）：单 GPU 推理进程，接收网关下发的任务，串行执行推理，结果回写网关。

## 队列与路由

- 网关维护一个 **全局 FIFO 队列**（容量由 `QUEUE_SIZE` 控制）。
- 请求到达时，若队列未满则入队并分配 task_id；若满则立即返回 **429 Too Many Requests**（body 为 OpenAI error envelope，code=queue_full）。
- 多个 Backend 时，网关将任务轮询或按策略分发到空闲 backend；每个 backend 内部串行执行，不并行占同一 GPU。

## 多 GPU：1 Gateway + N Backend

- `start.sh` 根据 `CUDA_VISIBLE_DEVICES`（或 nvidia-smi）启动 N 个 backend，端口从 `BACKEND_PORT_START` 起递增（8001、8002、…）。
- 网关通过环境变量 `BACKEND_URLS` 获取后端列表（start.sh 自动构造，或由平台注入）。

## Readiness 语义：/readyz vs /healthz

- **GET /healthz**：存活探针，网关进程在即返回 200。
- **GET /readyz**：就绪探针，当且仅当所有配置的 backend 均可用（如可连通且模型加载完成）时返回 200，否则 503。  
  验收与编排应使用 **/readyz** 判断是否可接收流量。

## 端口与部署

| 角色 | 默认端口 | 说明 |
|------|----------|------|
| Gateway | 8000 | 对外 API |
| Backend-0 | 8001 | 仅本机，由网关调用 |
| Backend-1 | 8002 | 多 GPU 时 |
