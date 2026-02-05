# 部署说明（单卡基础版）

**一句话定位**：单卡基础版 OpenAI-compatible 图片服务（文生图 / 图生图，兼容 `/v1/images/generations`、`/v1/images/edits` 等接口）。

---

## 必需环境变量

| 变量 | 说明 | 默认示例 |
|------|------|----------|
| **MODEL_DIR** | 模型权重目录，必须存在 | `/root/models/zai-org/GLM-Image` |
| **OUTPUTS_DIR** | 生成图输出目录，必须可写 | 镜像内默认 `/app/outputs`，可被环境变量覆盖 |
| **PORT** | 网关监听端口 | 8000 |
| **BACKEND_PORT_START** | 后端起始端口（多卡时依次递增） | 8001 |

启动时会对 `MODEL_DIR` 存在性、`OUTPUTS_DIR` 可写性做自检，失败则 `exit 1` 并提示。

---

## 模型挂载说明（Docker）

- **MODEL_DIR** 默认值为 `/root/models/zai-org/GLM-Image`。容器内该路径必须存在且含模型权重，否则启动自检报错退出。
- 运行镜像时需把宿主机模型目录挂载到该路径，或通过 `-e MODEL_DIR=/mnt/models/...` 指定并挂载到对应路径。示例：  
  `docker run -e MODEL_DIR=/models/zai-org/GLM-Image -v /宿主机/模型目录:/models ...`

- **Docker 构建与运行**：在项目根执行 `docker build -t glm-image-service .`（使用 `requirements.lock.docker.txt`）。运行示例：挂载模型并暴露端口  
  `docker run --rm -p 8000:8000 -e MODEL_DIR=/models/zai-org/GLM-Image -v /宿主机/模型:/models -v /宿主机/outputs:/app/outputs glm-image-service`

---

## 推荐环境变量

| 变量 | 说明 | 默认 |
|------|------|------|
| **DEFAULT_STEPS** | 默认推理步数 | 45 |
| **DEFAULT_SIZE** | 默认分辨率 | 1024x1024 |
| **QUEUE_SIZE** | 网关队列容量，满时返回 429 | 100 |
| **TASK_TIMEOUT_SEC** | 任务最大存活时间（排队+推理） | 300 |
| **SYNC_WAIT_TIMEOUT_SEC** | 同步等待上限（可被 IMAGES_SYNC_WAIT_TIMEOUT_SEC 等覆盖） | 120 |

更多变量见根目录 **ENVIRONMENT.md** 与 **docs/OPERATIONS.md**。

---

## 启动命令

```bash
./start.sh
```

从项目根目录执行；如需后台：`nohup ./start.sh > logs/start.log 2>&1 &`。

---

## 验收命令

```bash
./cli_tests/run_smoke.sh
```

可按需指定网关地址，例如：

```bash
BASE_URL=http://127.0.0.1:8000 ./cli_tests/run_smoke.sh
```

依次校验：healthz → readyz → v1/models → txt2img → img2img，任一步失败则退出非 0。

---

## 常见问题

- **外网受限**  
  若无法访问 GitHub / 外网拉包，需在能联网环境先拉取依赖与模型，再在目标环境部署；或配置 HTTP 代理（`http_proxy` / `https_proxy`），并注意 `start.sh` 已设 `NO_PROXY=localhost,127.0.0.1` 避免网关与后端走代理。

- **pip 源**  
  建议使用国内镜像加速安装，例如：  
  `pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple`  
  本地安装依赖：`pip install -r requirements.txt`。**镜像构建**使用 `requirements.lock.docker.txt` 以固定版本。

- **outputs 访问**  
  生成图落盘在 `OUTPUTS_DIR`，网关对外提供 `GET /outputs/{filename}` 静态访问。若通过反向代理或域名访问网关，需保证该路径被正确转发；直接访问时图片 URL 形如：`http://<host>:<PORT>/outputs/<task_id>.png`。

---

reports/、cli_tests/out/、logs/、outputs/ 属于运行时产物

本仓库默认忽略，不纳入 git
