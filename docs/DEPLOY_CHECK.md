# 镜像部署相关检查报告

检查时间：按当前仓库状态。  
目的：确认镜像部署相关文件与真实环境/条件一致。

---

## 1. 已核对且一致项

| 项目 | 状态 |
|------|------|
| **WORKDIR** | Dockerfile `WORKDIR /app`，与 start.sh 运行目录一致 |
| **OUTPUTS_DIR 默认值** | 三处统一为 `/app/outputs`：`scripts/start.sh`、`app/gateway/main.py`、`app/backend/main.py` |
| **LOG_DIR** | start.sh 中 `LOG_DIR=${LOG_DIR:-./logs}`，容器内即 `/app/logs`，且已 `mkdir -p "$OUTPUTS_DIR" "$LOG_DIR"` |
| **MODEL_DIR 默认值** | 脚本与 Python 均为 `/root/models/zai-org/GLM-Image`，与 Dockerfile ENV 一致 |
| **PORT / BACKEND_PORT_START** | Dockerfile EXPOSE 8000，ENV PORT=8000、BACKEND_PORT_START=8001，与 start.sh 一致 |
| **CMD** | Dockerfile `CMD ["./start.sh"]`，根目录 start.sh 转发到 `scripts/start.sh`，逻辑正确 |

---

## 2. 已修复项

| 问题 | 处理 |
|------|------|
| **requirements.lock.docker.txt 占位符** | 原 `diffusers @ git+...@<commit>`、`transformers @ git+...@<COMMIT>` 会导致镜像构建时 `pip install` 失败。已改为 PyPI 版本：`diffusers==0.32.0`、`transformers==4.46.3`。若你需固定为某次 git 提交，请把这两行改回具体 commit hash。 |
| **.dockerignore 缺失** | 已新增 `.dockerignore`，排除 `.git`、`logs/`、`outputs/`、`cli_tests/out/`、`reports/`、缓存与 IDE 等，减小构建上下文、避免把运行时产物打进镜像。 |
| **README_DEPLOY 与现状不符** | ① OUTPUTS_DIR 说明已改为「镜像内默认 `/app/outputs`，可被环境变量覆盖」；② 已补充「模型挂载说明（Docker）」及 Docker 构建/运行示例；③ 已说明镜像构建使用 `requirements.lock.docker.txt`。 |

---

## 3. 使用与条件提醒

- **模型目录**：容器内默认查找 `/root/models/zai-org/GLM-Image`，需在 `docker run` 时用 `-v` 挂载宿主机模型目录，或 `-e MODEL_DIR=...` 并挂载到对应路径。
- **输出目录**：默认写入容器内 `/app/outputs`；若需持久化，请挂载：`-v /宿主机/outputs:/app/outputs`。
- **依赖版本**：当前 lock 中 `diffusers`/`transformers` 已改为 PyPI 版本；若你之前依赖某次 git 提交行为，需在 `requirements.lock.docker.txt` 中改回 `@ git+...@<真实 commit>` 并重新构建验证。

---

## 4. 快速自检命令（可选）

```bash
# 构建（在项目根 /root/myspace）
docker build -t glm-image-service .

# 运行（替换 /宿主机/模型 与 /宿主机/outputs）
docker run --rm -p 8000:8000 \
  -e MODEL_DIR=/models/zai-org/GLM-Image \
  -v /宿主机/模型:/models \
  -v /宿主机/outputs:/app/outputs \
  glm-image-service
```

结论：**当前镜像部署相关文件与默认环境、路径约定已对齐；lock 占位符已修复、文档与 .dockerignore 已补全，可按上述方式构建与运行。**
