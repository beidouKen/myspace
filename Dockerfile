# 单卡基础版 OpenAI-compatible 图片服务（文生图/图生图）
FROM python:3.11-slim

WORKDIR /app

# 1) 系统依赖：git + 编译环境 + cairo 依赖（pycairo 源码构建需要）
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    pkg-config \
    libcairo2-dev \
    libffi-dev \
    python3-dev \
 && rm -rf /var/lib/apt/lists/*

# 2) 全局设置 pip 源（避免访问 pythonhosted.org）
RUN python -m pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple && \
    python -m pip config set global.timeout 100

# 3) Python 依赖（使用 lock）
COPY requirements.lock.docker.txt ./
RUN pip install --no-cache-dir -r requirements.lock.docker.txt

# 4) 应用代码
COPY . .

# 5) 运行时可通过 -e 覆盖
ENV MODEL_DIR=/root/models/zai-org/GLM-Image
ENV PORT=8000
ENV BACKEND_PORT_START=8001
ENV OUTPUTS_DIR=/app/outputs

EXPOSE 8000

CMD ["./start.sh"]
