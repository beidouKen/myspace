import os
import asyncio
import uuid
import time
import hashlib
import httpx
import base64
from contextlib import asynccontextmanager
from collections import defaultdict
from fastapi import FastAPI, HTTPException, Request, Response, Depends, status, UploadFile, Form, File, Header
from fastapi.responses import FileResponse, JSONResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from typing import Optional, Dict, Union, List, Tuple
from pydantic import BaseModel, Field
import re
import json
import io
import math
from PIL import Image, ImageOps
from .schemas_chat import ChatCompletionRequest, ChatCompletionResponse, ChatChoice, ChatMessage

# 引入 Schema
from .schemas_openai import OpenAIImageGenerationRequest, OpenAIImageGenerationResponse, OpenAIImageObject

# --- 配置 ---
BACKEND_URLS = [u.strip() for u in os.environ.get("BACKEND_URLS", "").split(",") if u.strip()]
QUEUE_SIZE = int(os.environ.get("QUEUE_SIZE", "100"))
TASK_TIMEOUT_SEC = int(os.environ.get("TASK_TIMEOUT_SEC", "300"))
SYNC_WAIT_TIMEOUT_SEC = int(os.environ.get("SYNC_WAIT_TIMEOUT_SEC", "120"))
# 工程兼容：默认同步优先，尽量 200；超时再 202
IMAGES_SYNC_WAIT_TIMEOUT_SEC = int(os.environ.get("IMAGES_SYNC_WAIT_TIMEOUT_SEC", "300"))
CHAT_SYNC_WAIT_TIMEOUT_SEC = int(os.environ.get("CHAT_SYNC_WAIT_TIMEOUT_SEC", "300"))
OUTPUTS_DIR = os.environ.get("OUTPUTS_DIR", "/app/outputs")
OUTPUT_TTL_SEC = int(os.environ.get("OUTPUT_TTL_SEC", "3600"))
API_KEY = os.environ.get("API_KEY", "")
PLATFORM_MODE = int(os.environ.get("PLATFORM_MODE", "1"))
MODEL_ID = os.environ.get("MODEL_ID", "glm-image")
MAX_N = int(os.environ.get("MAX_N", "4"))
MAX_EDIT_INPUT_IMAGES = int(os.environ.get("MAX_EDIT_INPUT_IMAGES", "4"))
BACKEND_COOLDOWN_SEC = int(os.environ.get("BACKEND_COOLDOWN_SEC", "30"))

REQUIRE_MULTIPLE = int(os.environ.get("REQUIRE_MULTIPLE", "64"))
MAX_SIDE = int(os.environ.get("MAX_SIDE", "1024"))
AUTO_RESIZE = os.environ.get("AUTO_RESIZE", "1") == "1"
STRICT_IMAGE_SIZE = os.environ.get("STRICT_IMAGE_SIZE", "0") == "1"
MIN_STEPS = int(os.environ.get("MIN_STEPS", "20"))
MAX_STEPS = int(os.environ.get("MAX_STEPS", "80"))

os.makedirs(OUTPUTS_DIR, exist_ok=True)

# 版本/特性自证：启动时生成，供 /healthz 返回，便于 Gate 95 等验收确认运行中网关版本
BUILD_ID = (os.environ.get("BUILD_ID") or "").strip() or str(int(time.time()))
GATEWAY_FEATURES = ["prefer_async", "images_sync_wait_timeout", "chat_sync_wait_timeout", "idempotency"]

# --- 鉴权 ---
security = HTTPBearer(auto_error=False)

async def verify_api_key(credentials: Optional[HTTPAuthorizationCredentials] = Depends(security)):
    if not API_KEY:
        return True # 未启用鉴权
    
    if not credentials or credentials.scheme.lower() != "bearer" or credentials.credentials != API_KEY:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API Key",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return True

# --- 统一错误处理 ---
def _parse_validation_errors(exc) -> tuple:
    """Parse RequestValidationError for missing 'image' -> (message, param)."""
    errors = exc.errors() if hasattr(exc, "errors") and callable(getattr(exc, "errors")) else []
    for e in errors:
        loc = e.get("loc") or ()
        if isinstance(loc, (list, tuple)) and len(loc) >= 1 and loc[-1] == "image":
            if e.get("type") == "missing" or "required" in (e.get("msg") or "").lower():
                return "Missing required field: image", "image"
    return str(exc), None


async def validation_exception_handler(request: Request, exc):
    message, param = _parse_validation_errors(exc)
    return JSONResponse(
        status_code=400,
        content={
            "error": {
                "message": message,
                "type": "invalid_request_error",
                "code": "bad_request",
                "param": param
            }
        }
    )

async def http_exception_handler(request: Request, exc: HTTPException):
    code_map = {
        429: "rate_limit_error",
        400: "invalid_request_error",
        401: "auth_error",
        403: "auth_error",
        404: "invalid_request_error",
        500: "server_error",
        502: "server_error",
        504: "server_error",
    }
    code_str_map = {
        429: "rate_limit_exceeded",
        400: "bad_request",
        401: "unauthorized",
        403: "unauthorized",
        404: "not_found",
        500: "internal_error",
        502: "backend_unreachable",
        504: "timeout",
    }
    # 429 queue_full
    if exc.status_code == 429 and ("Queue is full" in str(exc.detail) or "queue" in str(exc.detail).lower()):
        code_str = "queue_full"
    # Custom Error Code via Headers
    elif exc.headers and "X-Error-Code" in exc.headers:
        code_str = exc.headers["X-Error-Code"]
    # 502 backend_unreachable (detail may be set by sync loop)
    elif exc.status_code == 502:
        code_str = "backend_unreachable"
    # 504 sync_wait_timeout vs task_timeout（语义分层）
    elif exc.status_code == 504:
        d = str(exc.detail or "")
        d_lower = d.lower()
        if "exceeded sync_wait_timeout_sec" in d_lower or ("sync" in d_lower and "wait" in d_lower):
            code_str = "sync_wait_timeout"
        elif "exceeded task_timeout_sec" in d_lower or "deadline exceeded" in d_lower:
            code_str = "task_timeout"
        else:
            code_str = "task_timeout"
    else:
        code_str = code_str_map.get(exc.status_code, "unknown_error")

    err_type = code_map.get(exc.status_code, "server_error")
    param = None
    if exc.headers and "X-Error-Param" in exc.headers:
        param = exc.headers.get("X-Error-Param")

    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": {
                "message": exc.detail,
                "type": err_type,
                "code": code_str,
                "param": param
            }
        },
        headers=exc.headers
    )

async def general_exception_handler(request: Request, exc: Exception):
    return JSONResponse(
        status_code=500,
        content={
            "error": {
                "message": f"Internal Server Error: {str(exc)}",
                "type": "server_error",
                "code": "internal_error",
                "param": None
            }
        }
    )


# --- 数据模型 ---

class TaskInfo(BaseModel):
    id: str
    status: str = "pending" # pending, processing, completed, failed, cancelled, expired
    created_at: float
    enqueue_time: Optional[float] = None  # 入队时间（Phase2.1 统一队列语义）
    deadline: Optional[float] = None       # 截止时间 = enqueue_time + TASK_TIMEOUT_SEC
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    backend_id: Optional[str] = None
    error: Optional[str] = None
    request: dict
    result: Optional[str] = None # data uri for backward compatibility
    b64_json: Optional[str] = None
    file_path: Optional[str] = None
    # Phase 3: 多图融合 n 张输出
    result_urls: Optional[List[str]] = None  # 多张时 [url0, url1, ...]
    n_outputs: int = 1

class TaskResponse(BaseModel):
    task_id: str
    status: str

# --- 全局状态 ---

task_store: Dict[str, TaskInfo] = {}
idempotency_store: Dict[str, dict] = {}  # key -> {"task_id": str, "ts": float}
IDEMPOTENCY_TTL_SEC = int(os.environ.get("IDEMPOTENCY_TTL_SEC", "1800"))   # 30 min
IDEMPOTENCY_MAX_ITEMS = int(os.environ.get("IDEMPOTENCY_MAX_ITEMS", "1000"))
IDEMPOTENCY_KEY_TRUNCATE = 32  # 日志中 key 截断长度

# Phase 2.2: 多后端并行调度 — 每 backend 独立队列 + inflight/健康
backend_queues: Dict[str, asyncio.Queue] = {}   # url -> Queue[task_id]
backend_state: Dict[str, dict] = {}             # url -> {"inflight": int, "backend_up": bool, "down_until": float|None}
_backend_lock = asyncio.Lock()

# Metrics 统计
metrics_data = {
    "backends": {}, # {url: {"success": 0, "failure": 0}}
    "generation_times": [],
    "idempotency_hits": 0,
    "idempotency_misses": 0,
}

def update_metrics(backend_url: str, success: bool, duration: float = 0):
    if backend_url not in metrics_data["backends"]:
        metrics_data["backends"][backend_url] = {"success": 0, "failure": 0}
    key = "success" if success else "failure"
    metrics_data["backends"][backend_url][key] += 1
    if success:
        metrics_data["generation_times"].append(duration)
        if len(metrics_data["generation_times"]) > 100:
            metrics_data["generation_times"].pop(0)

# --- Gateway Metrics Middleware Collectors ---
REQUESTS_TOTAL = defaultdict(int)  # (route, status) -> count
LATENCY_SUM = defaultdict(float)   # route -> seconds sum
LATENCY_COUNT = defaultdict(int)   # route -> sample count
INFLIGHT = 0

def _resolve_metrics_route(path: str) -> Optional[str]:
    if not path:
        return None
    if path.startswith("/metrics"):
        return None
    if path.startswith("/v1/images/generations"):
        return "/v1/images/generations"
    if path.startswith("/v1/images/edits"):
        return "/v1/images/edits"
    if path.startswith("/v1/models"):
        return "/v1/models"
    if path.startswith("/healthz"):
        return "/healthz"
    if path.startswith("/readyz"):
        return "/readyz"
    return path.split("?")[0]

def _current_queue_depth() -> int:
    total = 0
    for q in backend_queues.values():
        try:
            total += q.qsize()
        except Exception:
            continue
    return total

# --- 幂等：fingerprint 与存储 ---
def _request_body_dict(obj) -> dict:
    """Pydantic v1/v2 兼容：请求体转 dict。"""
    if hasattr(obj, "model_dump"):
        return obj.model_dump()
    if hasattr(obj, "dict"):
        return obj.dict()
    return {}

def _canonical_txt2img(req_dict: dict) -> dict:
    """规范化 txt2img 请求字段（排序用），至少包含 prompt/size/steps/guidance/seed/n/model（如有）；数值归一化保证 hash 稳定。"""
    allowed = ("prompt", "size", "steps", "guidance", "guidance_scale", "seed", "n", "model")
    out = {}
    for k in allowed:
        if k in req_dict and req_dict[k] is not None:
            v = req_dict[k]
            if k in ("steps", "n", "seed") and isinstance(v, (int, float)):
                out[k] = int(v)
            elif k in ("guidance", "guidance_scale") and isinstance(v, (int, float)):
                out[k] = float(v)
            else:
                out[k] = v
    if "prompt" not in out:
        out["prompt"] = str(req_dict.get("prompt", ""))
    return out

def _compute_fingerprint_txt2img(req_dict: dict) -> str:
    """基于规范化请求体计算 txt2img 幂等 fingerprint（稳定 hash）。"""
    canonical = _canonical_txt2img(req_dict)
    payload = json.dumps(canonical, sort_keys=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()

def _compute_fingerprint_edits(canonical_params: dict, image_bytes_list: List[bytes]) -> str:
    """img2img：规范化参数 + 输入图内容指纹（对每张图 bytes 做 hash，稳定顺序组合）。"""
    param_payload = json.dumps(canonical_params, sort_keys=True)
    hasher = hashlib.sha256(param_payload.encode("utf-8"))
    for b in image_bytes_list:
        hasher.update(hashlib.sha256(b).digest())
    return hasher.hexdigest()

def _truncate_key(key: str) -> str:
    if len(key) <= IDEMPOTENCY_KEY_TRUNCATE:
        return key
    return key[:IDEMPOTENCY_KEY_TRUNCATE] + "…"

def _idempotency_evict_if_needed():
    """超出最大条目时按 ts 最旧优先清理。"""
    if len(idempotency_store) <= IDEMPOTENCY_MAX_ITEMS:
        return
    by_ts = [(k, v["ts"]) for k, v in idempotency_store.items()]
    by_ts.sort(key=lambda x: x[1])
    to_remove = len(idempotency_store) - IDEMPOTENCY_MAX_ITEMS
    for i in range(to_remove):
        k = by_ts[i][0]
        idempotency_store.pop(k, None)

def _idempotency_resolve(idem_key: str):
    """
    查幂等表：若存在且任务为 pending/processing 返回 (task_id, "inflight", task)；
    若为 completed 返回 (task_id, "completed", task)；若为 failed/expired 则清理并返回 (None, None, None)。
    """
    if not idem_key:
        return None, None, None
    stored = idempotency_store.get(idem_key)
    if not stored:
        return None, None, None
    task_id = stored["task_id"]
    task = task_store.get(task_id)
    if not task:
        idempotency_store.pop(idem_key, None)
        return None, None, None
    if task.status in ("failed", "expired"):
        idempotency_store.pop(idem_key, None)
        return None, None, None
    if task.status in ("pending", "processing"):
        return task_id, "inflight", task
    if task.status == "completed":
        return task_id, "completed", task
    return None, None, None

def _total_pending() -> int:
    """总待处理数 = 各队列中任务数 + 各 backend 当前 inflight。"""
    total = 0
    for url in BACKEND_URLS:
        q = backend_queues.get(url)
        if q is not None:
            total += q.qsize()
        st = backend_state.get(url, {})
        total += st.get("inflight", 0)
    return total

def _select_backend_min_inflight_holding_lock() -> str:
    """在已持有 _backend_lock 下选择 backend_up=1 且 inflight 最小的后端；同分按 BACKEND_URLS 顺序。"""
    now = time.time()
    candidates = []
    for url in BACKEND_URLS:
        st = backend_state.get(url, {})
        up = st.get("backend_up", True)
        down_until = st.get("down_until")
        if down_until is not None and now > down_until:
            st["backend_up"] = True
            st["down_until"] = None
            up = True
        if up:
            candidates.append((st.get("inflight", 0), url))
    if not candidates:
        candidates = [(backend_state.get(url, {}).get("inflight", 0), url) for url in BACKEND_URLS]
    candidates.sort(key=lambda x: (x[0], BACKEND_URLS.index(x[1]) if x[1] in BACKEND_URLS else 0))
    return candidates[0][1]

async def dispatch_task(task_id: str) -> str:
    """将 task_id 派发到 inflight 最小的 backend；返回所选 backend url。满则抛 HTTPException 429。"""
    async with _backend_lock:
        if _total_pending() >= QUEUE_SIZE:
            raise HTTPException(
                status_code=429,
                detail="Queue is full. Please try again later.",
                headers={"Retry-After": "5"},
            )
        backend = _select_backend_min_inflight_holding_lock()
        backend_queues[backend].put_nowait(task_id)
    print(json.dumps({"event": "DISPATCH", "task_id": task_id, "backend": backend}))
    return backend

# --- Worker 逻辑（每 backend 只消费自己的队列，派发后 inflight+1，完成/失败后 inflight-1）---

async def backend_worker(backend_url: str):
    """每个 Backend 对应一个 Worker，只从本 backend 队列取任务，串行处理。"""
    print(f"Worker for {backend_url} started.")
    if backend_url not in metrics_data["backends"]:
        metrics_data["backends"][backend_url] = {"success": 0, "failure": 0}

    q = backend_queues.get(backend_url)
    if q is None:
        return

    async with httpx.AsyncClient(timeout=float(TASK_TIMEOUT_SEC)) as client:
        while True:
            try:
                task_id = await q.get()
                async with _backend_lock:
                    backend_state.setdefault(backend_url, {"inflight": 0, "backend_up": True, "down_until": None})
                    backend_state[backend_url]["inflight"] = backend_state[backend_url].get("inflight", 0) + 1

                task = task_store.get(task_id)
                if not task:
                    async with _backend_lock:
                        backend_state[backend_url]["inflight"] -= 1
                    q.task_done()
                    continue

                # P3.2: 仅 TASK_TIMEOUT_SEC/deadline 触发时置 expired；sync_wait_timeout 不在此处
                deadline = task.deadline if task.deadline is not None else task.created_at + TASK_TIMEOUT_SEC
                if time.time() > deadline:
                    task.status = "expired"
                    task.finished_at = time.time()
                    task.error = f"Task timeout (exceeded TASK_TIMEOUT_SEC={TASK_TIMEOUT_SEC}s)"
                    print(json.dumps({"event": "TASK_TIMEOUT", "task_id": task_id, "reason": "expired_in_queue", "threshold_sec": TASK_TIMEOUT_SEC}))
                    async with _backend_lock:
                        backend_state[backend_url]["inflight"] -= 1
                    q.task_done()
                    continue

                if task.status == "cancelled":
                    async with _backend_lock:
                        backend_state[backend_url]["inflight"] -= 1
                    q.task_done()
                    continue

                task.status = "processing"
                task.started_at = time.time()
                task.backend_id = backend_url
                print(f"[{backend_url}] Processing task {task_id}")

                try:
                    req_dict = task.request
                    payload = {
                        "task_id": task_id,
                        "prompt": req_dict.get("prompt"),
                        "mode": req_dict.get("mode", "txt2img"),
                        "size": req_dict.get("size"),
                        "steps": req_dict.get("steps"),
                    }
                    if payload["mode"] == "img2img":
                        # Phase 3: 多图融合 images_b64 或单图 image_b64
                        if req_dict.get("images_b64"):
                            payload["images_b64"] = req_dict["images_b64"]
                            payload["n"] = req_dict.get("n", 1)
                        else:
                            payload["image_b64"] = req_dict.get("image_b64")
                            payload["n"] = req_dict.get("n", 1)
                        payload["strength"] = req_dict.get("strength")

                    resp = await client.post(f"{backend_url}/infer", json=payload)

                    if task.status == "cancelled":
                        async with _backend_lock:
                            backend_state[backend_url]["inflight"] -= 1
                        q.task_done()
                        continue

                    if resp.status_code == 200:
                        content_type = (resp.headers.get("content-type") or "").split(";")[0].strip().lower()
                        if content_type == "application/json":
                            # Phase 3: 多张输出 JSON {"images_b64": [...], "count": n}
                            try:
                                data = resp.json()
                                images_b64 = data.get("images_b64") or data.get("images_b64_list") or []
                                n_out = len(images_b64)
                                result_filenames = []
                                for i, b64_str in enumerate(images_b64):
                                    img_bytes = base64.b64decode(b64_str)
                                    fn = f"{task_id}_{i}.png"
                                    file_path = os.path.join(OUTPUTS_DIR, fn)
                                    with open(file_path, "wb") as f:
                                        f.write(img_bytes)
                                    result_filenames.append(fn)
                                task.status = "completed"
                                task.finished_at = time.time()
                                task.result_urls = result_filenames
                                task.n_outputs = n_out
                                task.b64_json = images_b64[0] if n_out else None
                                task.file_path = os.path.join(OUTPUTS_DIR, result_filenames[0]) if result_filenames else None
                                update_metrics(backend_url, True, task.finished_at - task.started_at)
                            except Exception as e:
                                task.status = "failed"
                                task.finished_at = time.time()
                                task.error = f"Parse multi-image response: {e}"
                                update_metrics(backend_url, False)
                        else:
                            content = resp.content
                            file_path = os.path.join(OUTPUTS_DIR, f"{task_id}.png")
                            with open(file_path, "wb") as f:
                                f.write(content)
                            b64_img = base64.b64encode(content).decode('utf-8')
                            task.status = "completed"
                            task.finished_at = time.time()
                            task.result = f"data:image/png;base64,{b64_img}"
                            task.b64_json = b64_img
                            task.file_path = file_path
                            task.n_outputs = 1
                            update_metrics(backend_url, True, task.finished_at - task.started_at)
                    else:
                        task.status = "failed"
                        task.finished_at = time.time()
                        task.error = f"HTTP {resp.status_code}: {resp.text}"
                        if resp.status_code == 504:
                            task.error = f"Task timeout (exceeded TASK_TIMEOUT_SEC={TASK_TIMEOUT_SEC}s)"
                            print(json.dumps({"event": "TASK_TIMEOUT", "task_id": task_id, "reason": "backend_504", "threshold_sec": TASK_TIMEOUT_SEC}))
                        update_metrics(backend_url, False)

                except httpx.TimeoutException:
                    task.status = "failed"
                    task.error = f"Task timeout (exceeded TASK_TIMEOUT_SEC={TASK_TIMEOUT_SEC}s)"
                    task.finished_at = time.time()
                    print(json.dumps({"event": "TASK_TIMEOUT", "task_id": task_id, "reason": "backend_http_timeout", "threshold_sec": TASK_TIMEOUT_SEC}))
                    update_metrics(backend_url, False)
                    async with _backend_lock:
                        backend_state[backend_url]["backend_up"] = False
                        backend_state[backend_url]["down_until"] = time.time() + BACKEND_COOLDOWN_SEC
                except (httpx.ConnectError, httpx.ConnectTimeout):
                    task.status = "failed"
                    task.error = "Backend unreachable"
                    task.finished_at = time.time()
                    update_metrics(backend_url, False)
                    async with _backend_lock:
                        backend_state[backend_url]["backend_up"] = False
                        backend_state[backend_url]["down_until"] = time.time() + BACKEND_COOLDOWN_SEC
                except Exception as e:
                    task.status = "failed"
                    task.error = str(e)
                    task.finished_at = time.time()
                    update_metrics(backend_url, False)
                    print(f"[{backend_url}] Error processing {task_id}: {e}")
                finally:
                    async with _backend_lock:
                        backend_state[backend_url]["inflight"] -= 1
                    q.task_done()
            except Exception as e:
                print(f"CRITICAL Worker Error [{backend_url}]: {e}")
                await asyncio.sleep(1)

# --- 后台清理任务 ---
async def cleanup_loop():
    print(f"Cleanup task started. TTL={OUTPUT_TTL_SEC}s")
    while True:
        try:
            now = time.time()
            
            # Idempotency Cleanup: TTL + 容量上限（最旧优先）
            keys_to_del = []
            for k, v in idempotency_store.items():
                if now - v["ts"] > IDEMPOTENCY_TTL_SEC:
                    keys_to_del.append(k)
            for k in keys_to_del:
                del idempotency_store[k]
            by_ts = [(k, v["ts"]) for k, v in idempotency_store.items()]
            by_ts.sort(key=lambda x: x[1])
            while len(idempotency_store) > IDEMPOTENCY_MAX_ITEMS and by_ts:
                k = by_ts.pop(0)[0]
                idempotency_store.pop(k, None)

            # Output File Cleanup
            if os.path.exists(OUTPUTS_DIR):
                for filename in os.listdir(OUTPUTS_DIR):
                    if not filename.endswith(".png"): continue
                    path = os.path.join(OUTPUTS_DIR, filename)
                    try:
                        mtime = os.path.getmtime(path)
                        if now - mtime > OUTPUT_TTL_SEC:
                            os.remove(path)
                            print(f"Deleted expired file: {filename}")
                    except OSError:
                        pass
        except Exception as e:
            print(f"Cleanup error: {e}")
        await asyncio.sleep(600) # 每10分钟查一次

# --- FastAPI App ---

def _print_gateway_config_summary():
    """Print effective config summary at startup (QUEUE/TIMEOUT, BACKEND_URLS, BACKEND_COOLDOWN_SEC, ...)."""
    summary = {
        "PLATFORM_MODE": PLATFORM_MODE,
        "MODEL_ID": MODEL_ID,
        "OUTPUTS_DIR": OUTPUTS_DIR,
        "QUEUE_SIZE": QUEUE_SIZE,
        "TASK_TIMEOUT_SEC": TASK_TIMEOUT_SEC,
        "SYNC_WAIT_TIMEOUT_SEC": SYNC_WAIT_TIMEOUT_SEC,
        "IMAGES_SYNC_WAIT_TIMEOUT_SEC": IMAGES_SYNC_WAIT_TIMEOUT_SEC,
        "CHAT_SYNC_WAIT_TIMEOUT_SEC": CHAT_SYNC_WAIT_TIMEOUT_SEC,
        "BACKEND_URLS": BACKEND_URLS,
        "BACKEND_COOLDOWN_SEC": BACKEND_COOLDOWN_SEC,
        "MAX_N": MAX_N,
        "MAX_EDIT_INPUT_IMAGES": MAX_EDIT_INPUT_IMAGES,
        "IDEMPOTENCY_TTL_SEC": IDEMPOTENCY_TTL_SEC,
        "IDEMPOTENCY_MAX_ITEMS": IDEMPOTENCY_MAX_ITEMS,
    }
    print("Gateway effective config summary:", json.dumps(summary, indent=2))

@asynccontextmanager
async def lifespan(app: FastAPI):
    _print_gateway_config_summary()
    workers = []
    if not BACKEND_URLS:
        print("WARNING: No BACKEND_URLS configured!")
    else:
        for url in BACKEND_URLS:
            backend_queues[url] = asyncio.Queue()
            backend_state[url] = {"inflight": 0, "backend_up": True, "down_until": None}
        for url in BACKEND_URLS:
            w = asyncio.create_task(backend_worker(url))
            workers.append(w)

    cleaner = asyncio.create_task(cleanup_loop())
    
    yield
    
    cleaner.cancel()
    for w in workers:
        w.cancel()

app = FastAPI(lifespan=lifespan)
from fastapi.exceptions import RequestValidationError
app.add_exception_handler(RequestValidationError, validation_exception_handler)
app.add_exception_handler(HTTPException, http_exception_handler)
app.add_exception_handler(Exception, general_exception_handler)

@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    global INFLIGHT
    route = _resolve_metrics_route(request.url.path)
    start = time.perf_counter()
    INFLIGHT += 1
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    except Exception:
        raise
    finally:
        duration = time.perf_counter() - start
        INFLIGHT = max(INFLIGHT - 1, 0)
        if route:
            REQUESTS_TOTAL[(route, str(status_code))] += 1
            LATENCY_SUM[route] += duration
            LATENCY_COUNT[route] += 1

# --- Endpoints ---

@app.get("/v1/models")
async def list_models(auth: bool = Depends(verify_api_key)):
    return {
        "object": "list",
        "data": [
            {
                "id": MODEL_ID,
                "object": "model",
                "created": 1700000000,
                "owned_by": "local" 
            }
        ]
    }


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "queue_length": _total_pending(),
        "backends_count": len(BACKEND_URLS),
        "build_id": BUILD_ID,
        "features": GATEWAY_FEATURES,
        "effective_config": {
            "IMAGES_SYNC_WAIT_TIMEOUT_SEC": IMAGES_SYNC_WAIT_TIMEOUT_SEC,
            "CHAT_SYNC_WAIT_TIMEOUT_SEC": CHAT_SYNC_WAIT_TIMEOUT_SEC,
            "SYNC_WAIT_TIMEOUT_SEC": SYNC_WAIT_TIMEOUT_SEC,
        },
    }

@app.get("/healthz")
async def healthz():
    """Process liveness probe alias: reuse /health. 含 build_id/features/effective_config 供版本/特性自证。"""
    return await health()

@app.get("/ready")
async def ready():
    if not BACKEND_URLS:
        raise HTTPException(status_code=503, detail="No backends configured")
    
    results = []
    all_ready = True
    
    async with httpx.AsyncClient(timeout=2.0) as client:
        for url in BACKEND_URLS:
            info = {"url": url, "ok": False, "gpu_id": None, "model_loaded": False}
            try:
                resp = await client.get(f"{url}/health")
                if resp.status_code == 200:
                    data = resp.json()
                    info["ok"] = True
                    info["gpu_id"] = data.get("gpu_id")
                    info["model_loaded"] = data.get("model_loaded", False)
                    if not info["model_loaded"]:
                        all_ready = False
                else:
                    all_ready = False
            except Exception:
                all_ready = False
            results.append(info)
            
    if all_ready:
        return {"status": "ready", "backends": results}
    else:
        # Return 503 but with JSON detail
        return JSONResponse(
            status_code=503,
            content={"status": "not_ready", "backends": results}
        )

@app.get("/readyz")
async def readyz():
    """Readiness probe alias: reuse /ready."""
    return await ready()

@app.get("/metrics")
async def metrics():
    lines = []

    inflight = max(INFLIGHT, 0)
    queue_depth = _current_queue_depth()

    lines.append("# HELP glm_inflight Gateway in-flight requests.")
    lines.append("# TYPE glm_inflight gauge")
    lines.append(f"glm_inflight {inflight}")

    lines.append("# HELP glm_queue_depth Tasks waiting across backend queues.")
    lines.append("# TYPE glm_queue_depth gauge")
    lines.append(f"glm_queue_depth {queue_depth}")

    lines.append("# HELP glm_backend_up Backend health (1=up,0=down).")
    lines.append("# TYPE glm_backend_up gauge")
    if BACKEND_URLS:
        for url in BACKEND_URLS:
            st = backend_state.get(url, {})
            up = 1 if st.get("backend_up", True) else 0
            lines.append(f'glm_backend_up{{url="{url}"}} {up}')
    else:
        lines.append('glm_backend_up{url="none"} 0')

    lines.append("# HELP glm_requests_total Total HTTP requests served by gateway.")
    lines.append("# TYPE glm_requests_total counter")
    for (route, status), count in sorted(REQUESTS_TOTAL.items()):
        lines.append(f'glm_requests_total{{route="{route}",status="{status}"}} {count}')

    lines.append("# HELP glm_request_latency_seconds_sum Accumulated latency per route.")
    lines.append("# TYPE glm_request_latency_seconds_sum counter")
    for route, total in sorted(LATENCY_SUM.items()):
        lines.append(f'glm_request_latency_seconds_sum{{route="{route}"}} {total}')

    lines.append("# HELP glm_request_latency_seconds_count Request latency samples per route.")
    lines.append("# TYPE glm_request_latency_seconds_count counter")
    for route, count in sorted(LATENCY_COUNT.items()):
        lines.append(f'glm_request_latency_seconds_count{{route="{route}"}} {count}')

    body = "\n".join(lines) + "\n"
    return Response(content=body, media_type="text/plain; version=0.0.4")

@app.api_route("/outputs/{filename}", methods=["GET", "HEAD"])
async def get_output_file(filename: str, request: Request):
    file_path = os.path.join(OUTPUTS_DIR, filename)
    if not os.path.exists(file_path):
        raise HTTPException(status_code=404, detail="File not found")
    if request.method == "HEAD":
        stat = os.stat(file_path)
        return Response(status_code=200, headers={"Content-Type": "image/png", "Content-Length": str(stat.st_size)})
    return FileResponse(file_path)

def _build_image_response_from_task(request: Request, task: TaskInfo, task_id: str) -> OpenAIImageGenerationResponse:
    """从 TaskInfo 构建 OpenAIImageGenerationResponse（单图或多图）。"""
    base_url = str(request.base_url).rstrip("/")
    if getattr(task, "result_urls", None) and getattr(task, "n_outputs", 1) > 1:
        data_list = [OpenAIImageObject(url=f"{base_url}/outputs/{fn}") for fn in task.result_urls]
    else:
        img_url = f"{base_url}/outputs/{task_id}.png"
        img_obj = OpenAIImageObject(url=img_url)
        if task.b64_json:
            img_obj.b64_json = task.b64_json
        data_list = [img_obj]
    return OpenAIImageGenerationResponse(
        created=int(task.finished_at or time.time()),
        data=data_list,
    )

def _parse_prefer_async_header(value: Optional[str]) -> bool:
    if not value:
        return False
    v = value.strip().lower()
    return v in ("true", "1", "yes")

@app.post("/v1/images/generations", response_model=Union[TaskResponse, OpenAIImageGenerationResponse])
async def create_gen(
    req: OpenAIImageGenerationRequest,
    request: Request,
    response: Response,
    auth: bool = Depends(verify_api_key),
    idempotency_key: Optional[str] = Header(None, alias="Idempotency-Key"),
    x_prefer_async: Optional[str] = Header(None, alias="X-Prefer-Async"),
):
    # Validation
    if req.size and req.size not in ["512x512", "768x768", "1024x1024"]:
        raise HTTPException(status_code=400, detail="Invalid size. Allowed: 512x512, 768x768, 1024x1024")
    if req.steps is not None and (req.steps < MIN_STEPS or req.steps > MAX_STEPS):
        raise HTTPException(
            status_code=400,
            detail=f"steps must be between {MIN_STEPS} and {MAX_STEPS} (got {req.steps})",
            headers={"X-Error-Param": "steps"},
        )

    n_val = req.n if req.n is not None else 1
    if n_val < 1 or n_val > MAX_N:
        raise HTTPException(
            status_code=400,
            detail=f"n must be between 1 and {MAX_N} (got {n_val})",
        )

    # 幂等键：请求头 Idempotency-Key（大小写不敏感）或基于请求体 fingerprint
    idem_key = (idempotency_key or "").strip() or None
    if not idem_key:
        idem_key = _compute_fingerprint_txt2img(_request_body_dict(req))

    task_id, hit_type, existing_task = _idempotency_resolve(idem_key)

    if hit_type == "completed":
        metrics_data["idempotency_hits"] = metrics_data.get("idempotency_hits", 0) + 1
        print(json.dumps({
            "event": "IDEMPOTENCY_HIT",
            "key": _truncate_key(idem_key),
            "task_id": task_id,
            "status": existing_task.status,
            "hit_type": "completed",
        }))
        # compat: 默认同步等待，尽量 200
        should_sync = req.sync if req.sync is not None else True
        if should_sync:
            return _build_image_response_from_task(request, existing_task, task_id)
        return TaskResponse(task_id=task_id, status="completed")

    if hit_type == "inflight":
        metrics_data["idempotency_hits"] = metrics_data.get("idempotency_hits", 0) + 1
        print(json.dumps({
            "event": "IDEMPOTENCY_HIT",
            "key": _truncate_key(idem_key),
            "task_id": task_id,
            "status": existing_task.status,
            "hit_type": "inflight",
        }))
        should_sync = req.sync if req.sync is not None else True
        if not should_sync:
            return TaskResponse(task_id=task_id, status=existing_task.status)
        # sync: 继续下方等待循环
    else:
        # 未命中或 failed 已清理：创建新任务
        metrics_data["idempotency_misses"] = metrics_data.get("idempotency_misses", 0) + 1
        print(json.dumps({
            "event": "IDEMPOTENCY_MISS",
            "key": _truncate_key(idem_key),
            "task_id": None,
        }))
        task_id = str(uuid.uuid4())
        now = time.time()
        task_info = TaskInfo(
            id=task_id,
            created_at=now,
            enqueue_time=now,
            deadline=now + TASK_TIMEOUT_SEC,
            request=_request_body_dict(req),
        )
        task_store[task_id] = task_info
        idempotency_store[idem_key] = {"task_id": task_id, "ts": time.time()}
        _idempotency_evict_if_needed()
        try:
            await dispatch_task(task_id)
        except HTTPException:
            del task_store[task_id]
            idempotency_store.pop(idem_key, None)
            raise

    # Sync/Async Logic（compat：默认同步等待）
    should_sync = req.sync if req.sync is not None else True
    if not should_sync:
        return TaskResponse(task_id=task_id, status="pending")

    prefer_async = getattr(req, "prefer_async", None) or _parse_prefer_async_header(x_prefer_async)
    if prefer_async:
        base_url = str(request.base_url).rstrip("/")
        current_task = task_store.get(task_id)
        status_val = current_task.status if current_task else "pending"
        return JSONResponse(
            status_code=202,
            content={"task_id": task_id, "status": status_val, "poll_url": f"{base_url}/v1/tasks/{task_id}"},
            headers={"Content-Type": "application/json"},
        )

    # 同步模式：等待完成（默认 compat，尽量 200；超时返回 202）
    wait_start = time.time()
    base_url = str(request.base_url).rstrip("/")
    while True:
        if time.time() - wait_start > IMAGES_SYNC_WAIT_TIMEOUT_SEC:
            print(json.dumps({"event": "SYNC_WAIT_TIMEOUT", "task_id": task_id, "threshold_sec": IMAGES_SYNC_WAIT_TIMEOUT_SEC}))
            current_task = task_store.get(task_id)
            status_val = current_task.status if current_task else "pending"
            return JSONResponse(
                status_code=202,
                content={"task_id": task_id, "status": status_val, "poll_url": f"{base_url}/v1/tasks/{task_id}"},
                headers={"Content-Type": "application/json"},
            )
        current_task = task_store.get(task_id)
        if not current_task:
            raise HTTPException(status_code=404, detail="Task lost")
        if current_task.status == "completed":
            return _build_image_response_from_task(request, current_task, task_id)
        if current_task.status in ["failed", "expired", "cancelled"]:
            err_msg = current_task.error or f"Task is {current_task.status}"
            if err_msg == "Backend unreachable":
                raise HTTPException(status_code=502, detail="Backend unreachable")
            if "exceeded TASK_TIMEOUT_SEC" in (err_msg or "") or "deadline exceeded" in (err_msg or "").lower() or "Backend timeout" in (err_msg or ""):
                detail_504 = err_msg if ("exceeded TASK_TIMEOUT_SEC" in (err_msg or "") or "deadline exceeded" in (err_msg or "").lower()) else f"Task timeout (exceeded TASK_TIMEOUT_SEC={TASK_TIMEOUT_SEC}s)"
                print(json.dumps({"event": "TASK_TIMEOUT", "task_id": task_id, "threshold_sec": TASK_TIMEOUT_SEC, "from_sync": True}))
                raise HTTPException(status_code=504, detail=detail_504, headers={"X-Task-Id": task_id})
            raise HTTPException(status_code=500, detail=err_msg)
        await asyncio.sleep(0.5)

def _verify_image_bytes(image_bytes: bytes) -> None:
    """Verify image with PIL; on failure raise HTTPException 400 with param=image."""
    try:
        img = Image.open(io.BytesIO(image_bytes))
        img.verify()
        # Force decode to catch truncated/corrupt
        img = Image.open(io.BytesIO(image_bytes))
        img.load()
    except Exception:
        raise HTTPException(
            status_code=400,
            detail="Invalid image.",
            headers={"X-Error-Param": "image"},
        )


def _preprocess_image_bytes(image_bytes: bytes, task_id: str = "unknown") -> bytes:
    if not Image:
        return image_bytes
    
    try:
        # Load
        img = Image.open(io.BytesIO(image_bytes))
        orig_w, orig_h = img.size
        orig_mode = img.mode
        
        # 1. Convert to RGB
        if img.mode != "RGB":
            img = img.convert("RGB")
            
        # 2. Check Constraints
        is_compliant = (orig_w % REQUIRE_MULTIPLE == 0) and \
                       (orig_h % REQUIRE_MULTIPLE == 0) and \
                       (max(orig_w, orig_h) <= MAX_SIDE)
                       
        if is_compliant:
            # If compliant but mode changed, we must save.
            if orig_mode != "RGB":
                out_io = io.BytesIO()
                img.save(out_io, format="PNG")
                processed_bytes = out_io.getvalue()
                print(json.dumps({
                    "event": "PREPROCESS_IMAGE",
                    "task_id": task_id,
                    "original_size": f"{orig_w}x{orig_h}",
                    "final_size": f"{orig_w}x{orig_h}",
                    "action": "format_conversion",
                    "details": f"Converted from {orig_mode} to RGB"
                }))
                return processed_bytes
            return image_bytes # No change needed

        # Not compliant
        if STRICT_IMAGE_SIZE:
             msg = f"Image size {orig_w}x{orig_h} is invalid. " \
                   f"Must be multiple of {REQUIRE_MULTIPLE} and max side {MAX_SIDE}."
             raise HTTPException(
                status_code=400,
                detail=msg,
                headers={"X-Error-Code": "invalid_image_size"}
             )

        if not AUTO_RESIZE:
             print(json.dumps({
                 "event": "PREPROCESS_IMAGE",
                 "task_id": task_id,
                 "original_size": f"{orig_w}x{orig_h}",
                 "action": "skipped",
                 "reason": "AUTO_RESIZE=0",
                 "mode": "passthrough"
             }))
             return image_bytes

        # 3. Auto Resize / Pad
        # Strategy: Scale down longest side to MAX_SIDE (preserving aspect), then pad up to multiple.
        # Note: If MAX_SIDE is not a multiple of REQUIRE_MULTIPLE, this could theoretically result in 
        # a final padded size slightly larger than MAX_SIDE (e.g. 1000 -> pad to 1024).
        # However, typically MAX_SIDE is 1024. 
        # To be strictly compliant with "Final max side <= MAX_SIDE", we should limit the scaling
        # target to floor(MAX_SIDE / REQUIRE_MULTIPLE) * REQUIRE_MULTIPLE.
        
        limit_side_aligned = (MAX_SIDE // REQUIRE_MULTIPLE) * REQUIRE_MULTIPLE
        
        # Calculate scale factor
        # If max(w, h) > limit_side_aligned, scale down so max(w, h) = limit_side_aligned
        # Else keep original (scale = 1.0) - BUT only if original fits in MAX_SIDE?
        # The prompt says: "If max(W,H) > MAX_SIDE, scale... else keep original".
        # But if original is kept, we still pad. If padding exceeds MAX_SIDE, we violate constraint.
        # So we must effectively ensure max(w, h) fits in limit_side_aligned BEFORE padding.
        
        current_max = max(orig_w, orig_h)
        if current_max > limit_side_aligned:
             scale = limit_side_aligned / current_max
        else:
             # Check if padding would push it over
             # E.g. MAX=1000, MULT=64. limit=960. 
             # Input=980. 980 < 1000 (OK). Pad(980)=1024 > 1000 (Fail).
             # So actually we must ALWAYS check against limit_side_aligned.
             if current_max > limit_side_aligned:
                 scale = limit_side_aligned / current_max
             else:
                 scale = 1.0
                 
        if scale < 1.0:
            w1 = int(orig_w * scale)
            h1 = int(orig_h * scale)
            img = img.resize((w1, h1), Image.LANCZOS)
        else:
            w1, h1 = orig_w, orig_h
            
        # Pad to multiple
        target_w = math.ceil(w1 / REQUIRE_MULTIPLE) * REQUIRE_MULTIPLE
        target_h = math.ceil(h1 / REQUIRE_MULTIPLE) * REQUIRE_MULTIPLE
        
        # Double check against MAX_SIDE (should be guaranteed by limit_side_aligned logic)
        # Exception: if limit_side_aligned < MAX_SIDE (e.g. 960 vs 1000), target could be 1024?
        # No, because w1 <= 960, ceil(w1/64)*64 <= ceil(960/64)*64 = 15*64 = 960.
        # So it is safe.
        
        new_img = Image.new("RGB", (target_w, target_h), (0, 0, 0))
        paste_x = (target_w - w1) // 2
        paste_y = (target_h - h1) // 2
        new_img.paste(img, (paste_x, paste_y))
        
        out_io = io.BytesIO()
        new_img.save(out_io, format="PNG")
        
        print(json.dumps({
            "event": "PREPROCESS_IMAGE",
            "task_id": task_id,
            "original_size": f"{orig_w}x{orig_h}",
            "final_size": f"{target_w}x{target_h}",
            "action": "resized_padded" if (target_w != orig_w or target_h != orig_h) else "passthrough",
            "mode": "pad",
            "scale": round(scale, 4)
        }))
        
        return out_io.getvalue()
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"Image preprocessing error for task {task_id}: {e}")
        return image_bytes

@app.post("/v1/images/edits", response_model=Union[TaskResponse, OpenAIImageGenerationResponse])
async def create_edit(
    request: Request,
    response: Response,
    prompt: str = Form(...),
    image: List[UploadFile] = File(...),
    mask: Optional[UploadFile] = File(None),
    n: Optional[int] = Form(1),
    size: Optional[str] = Form(None),
    steps: Optional[int] = Form(None),
    strength: Optional[float] = Form(None),
    seed: Optional[int] = Form(None),
    response_format: str = Form("b64_json"),
    sync: Optional[Union[bool, str]] = Form(None),
    prefer_async: Optional[Union[bool, str]] = Form(None),
    stream: Optional[Union[bool, str]] = Form(None),  # Phase 3: 不报错，按非流式处理
    auth: bool = Depends(verify_api_key),
    idempotency_key: Optional[str] = Header(None, alias="Idempotency-Key"),
    x_prefer_async: Optional[str] = Header(None, alias="X-Prefer-Async"),
):
    # stream=true 不报错（按非流式处理）
    is_sync = None
    if sync is not None:
        if isinstance(sync, bool):
            is_sync = sync
        elif isinstance(sync, str):
            if sync.lower() == 'true': is_sync = True
            elif sync.lower() == 'false': is_sync = False
    # compat: 默认同步等待
    if is_sync is None:
        is_sync = True
    is_prefer_async = _parse_prefer_async_header(x_prefer_async)
    if not is_prefer_async and prefer_async is not None:
        if isinstance(prefer_async, bool):
            is_prefer_async = prefer_async
        elif isinstance(prefer_async, str) and prefer_async.strip().lower() in ("true", "1", "yes"):
            is_prefer_async = True

    images_list = list(image) if image else []
    if len(images_list) > MAX_EDIT_INPUT_IMAGES:
        raise HTTPException(
            status_code=400,
            detail=f"Too many images: at most {MAX_EDIT_INPUT_IMAGES} allowed (got {len(images_list)})",
        )
    n_val = n if n is not None else 1
    if n_val < 1 or n_val > MAX_N:
        raise HTTPException(
            status_code=400,
            detail=f"n must be between 1 and {MAX_N} (got {n_val})",
        )
    if steps is not None and (steps < MIN_STEPS or steps > MAX_STEPS):
        raise HTTPException(
            status_code=400,
            detail=f"steps must be between {MIN_STEPS} and {MAX_STEPS} (got {steps})",
            headers={"X-Error-Param": "steps"},
        )

    task_id_placeholder = "edits-" + str(uuid.uuid4())[:8]
    try:
        images_b64 = []
        image_bytes_list = []
        for f in images_list:
            img_bytes = await f.read()
            _verify_image_bytes(img_bytes)
            img_bytes = _preprocess_image_bytes(img_bytes, task_id_placeholder)
            image_bytes_list.append(img_bytes)
            images_b64.append(base64.b64encode(img_bytes).decode("utf-8"))
        if not images_b64:
            raise HTTPException(status_code=400, detail="At least one image required")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid image file: {e}",
            headers={"X-Error-Param": "image"},
        )

    canonical_params = {"prompt": prompt, "size": size, "steps": steps, "n": n_val, "strength": strength, "seed": seed}
    canonical_params = {k: v for k, v in canonical_params.items() if v is not None}

    idem_key = (idempotency_key or "").strip() or None
    if not idem_key:
        idem_key = _compute_fingerprint_edits(canonical_params, image_bytes_list)

    task_id, hit_type, existing_task = _idempotency_resolve(idem_key)

    if hit_type == "completed":
        metrics_data["idempotency_hits"] = metrics_data.get("idempotency_hits", 0) + 1
        print(json.dumps({
            "event": "IDEMPOTENCY_HIT",
            "key": _truncate_key(idem_key),
            "task_id": task_id,
            "status": existing_task.status,
            "hit_type": "completed",
        }))
        if is_sync:
            base_url = str(request.base_url).rstrip("/")
            if getattr(existing_task, "result_urls", None) and getattr(existing_task, "n_outputs", 1) > 1:
                data_list = [OpenAIImageObject(url=f"{base_url}/outputs/{fn}") for fn in existing_task.result_urls]
            else:
                img_url = f"{base_url}/outputs/{task_id}.png"
                img_obj = OpenAIImageObject(url=img_url)
                if existing_task.b64_json:
                    img_obj.b64_json = existing_task.b64_json
                data_list = [img_obj]
            return OpenAIImageGenerationResponse(created=int(existing_task.finished_at), data=data_list)
        return TaskResponse(task_id=task_id, status="completed")

    if hit_type == "inflight":
        metrics_data["idempotency_hits"] = metrics_data.get("idempotency_hits", 0) + 1
        print(json.dumps({
            "event": "IDEMPOTENCY_HIT",
            "key": _truncate_key(idem_key),
            "task_id": task_id,
            "status": existing_task.status,
            "hit_type": "inflight",
        }))
        if not is_sync:
            return TaskResponse(task_id=task_id, status=existing_task.status)
        # sync: 继续下方等待循环
    else:
        metrics_data["idempotency_misses"] = metrics_data.get("idempotency_misses", 0) + 1
        print(json.dumps({
            "event": "IDEMPOTENCY_MISS",
            "key": _truncate_key(idem_key),
            "task_id": None,
        }))
        task_id = str(uuid.uuid4())
        now = time.time()
        req_dict = {
            "mode": "img2img",
            "prompt": prompt,
            "images_b64": images_b64,
            "image_b64": images_b64[0] if len(images_b64) == 1 else None,
            "n": n_val,
            "size": size,
            "steps": steps,
            "strength": strength,
            "seed": seed,
            "response_format": response_format,
            "sync": is_sync or False,
        }
        task_info = TaskInfo(
            id=task_id,
            created_at=now,
            enqueue_time=now,
            deadline=now + TASK_TIMEOUT_SEC,
            request=req_dict,
        )
        task_store[task_id] = task_info
        idempotency_store[idem_key] = {"task_id": task_id, "ts": time.time()}
        _idempotency_evict_if_needed()
        try:
            await dispatch_task(task_id)
        except HTTPException:
            del task_store[task_id]
            idempotency_store.pop(idem_key, None)
            raise

    if not is_sync:
        return TaskResponse(task_id=task_id, status="pending")

    base_url = str(request.base_url).rstrip("/")
    if is_prefer_async:
        current_task = task_store.get(task_id)
        status_val = current_task.status if current_task else "pending"
        return JSONResponse(
            status_code=202,
            content={"task_id": task_id, "status": status_val, "poll_url": f"{base_url}/v1/tasks/{task_id}"},
            headers={"Content-Type": "application/json"},
        )

    wait_start = time.time()
    while True:
        if time.time() - wait_start > IMAGES_SYNC_WAIT_TIMEOUT_SEC:
            print(json.dumps({"event": "SYNC_WAIT_TIMEOUT", "task_id": task_id, "threshold_sec": IMAGES_SYNC_WAIT_TIMEOUT_SEC}))
            current_task = task_store.get(task_id)
            status_val = current_task.status if current_task else "pending"
            return JSONResponse(
                status_code=202,
                content={"task_id": task_id, "status": status_val, "poll_url": f"{base_url}/v1/tasks/{task_id}"},
                headers={"Content-Type": "application/json"},
            )
        current_task = task_store.get(task_id)
        if not current_task:
            raise HTTPException(status_code=404, detail="Task lost")
        if current_task.status == "completed":
            if getattr(current_task, "result_urls", None) and getattr(current_task, "n_outputs", 1) > 1:
                data_list = [
                    OpenAIImageObject(url=f"{base_url}/outputs/{fn}")
                    for fn in current_task.result_urls
                ]
            else:
                img_url = f"{base_url}/outputs/{task_id}.png"
                img_obj = OpenAIImageObject(url=img_url)
                if current_task.b64_json:
                    img_obj.b64_json = current_task.b64_json
                data_list = [img_obj]
            return OpenAIImageGenerationResponse(
                created=int(current_task.finished_at),
                data=data_list
            )
        if current_task.status in ["failed", "expired", "cancelled"]:
            err_msg = current_task.error or current_task.status
            if err_msg == "Backend unreachable":
                raise HTTPException(status_code=502, detail="Backend unreachable")
            if "exceeded TASK_TIMEOUT_SEC" in (err_msg or "") or "deadline exceeded" in (err_msg or "").lower() or "Backend timeout" in (err_msg or ""):
                detail_504 = err_msg if ("exceeded TASK_TIMEOUT_SEC" in (err_msg or "") or "deadline exceeded" in (err_msg or "").lower()) else f"Task timeout (exceeded TASK_TIMEOUT_SEC={TASK_TIMEOUT_SEC}s)"
                print(json.dumps({"event": "TASK_TIMEOUT", "task_id": task_id, "threshold_sec": TASK_TIMEOUT_SEC, "from_sync": True}))
                raise HTTPException(status_code=504, detail=detail_504, headers={"X-Task-Id": task_id})
            raise HTTPException(status_code=500, detail=err_msg)
        await asyncio.sleep(0.5)

@app.get("/v1/tasks/{task_id}")
async def get_task(task_id: str, request: Request):
    if task_id not in task_store:
        raise HTTPException(status_code=404, detail="Not found")
    t = task_store[task_id]
    resp = {
        "id": t.id,
        "status": t.status,
        "created_at": t.created_at,
        "start_time": t.started_at,
        "completion_time": t.finished_at,
        "error": t.error,
        "result": t.result,
        "backend_id": t.backend_id,  # Phase 2.2: 并行验收可证明派发到不同 backend
    }
    # Phase 3 / P3.2: completed 时多张输出返回 output_urls，便于轮询验收
    if t.status == "completed" and getattr(t, "result_urls", None):
        base_url = str(request.base_url).rstrip("/")
        resp["output_urls"] = [f"{base_url}/outputs/{fn}" for fn in t.result_urls]
        resp["n_outputs"] = getattr(t, "n_outputs", len(t.result_urls))
    return resp

@app.post("/v1/tasks/{task_id}/cancel")
async def cancel_task(task_id: str):
    if task_id not in task_store:
        raise HTTPException(status_code=404, detail="Not found")
    
    task = task_store[task_id]
    
    # 只能取消未完成的任务
    if task.status in ["completed", "failed", "expired", "cancelled"]:
        return {"status": task.status, "message": "Task already ended"}
    
    # 标记取消
    prev_status = task.status
    task.status = "cancelled"
    task.finished_at = time.time()
    
    # 注意：如果已在 processing，worker 会在完成后检查 status 并丢弃结果
    # 如果是 pending，worker 取出时会直接跳过
    
    return {"status": "cancelled", "previous_status": prev_status}

# --- OpenAI Chat Adapter ---
@app.post("/v1/chat/completions", response_model=ChatCompletionResponse)
async def chat_completions(
    req: ChatCompletionRequest,
    request: Request,
    auth: bool = Depends(verify_api_key),
    x_prefer_async: Optional[str] = Header(None, alias="X-Prefer-Async"),
):
    # 1. 基础校验 & Stream 兼容（stream=true 接受且不报错；不做真 SSE，stream_effective=false）
    stream_requested = bool(req.stream) if req.stream is not None else False
    stream_effective = False  # 本服务不启用真 token/SSE 流式

    # 2. 提取 Prompt
    if not req.messages:
        raise HTTPException(status_code=400, detail="Messages cannot be empty")
        
    prompt_text = ""
    for msg in reversed(req.messages):
        if msg.role == "user":
            prompt_text = msg.content
            break
            
    if not prompt_text:
        raise HTTPException(status_code=400, detail="No user message found")

    # 3. 解析模式与参数
    mode = "txt2img"
    # 关键字检测
    if re.search(r"img2img|edit|图生图|以图生图", prompt_text, re.IGNORECASE):
        mode = "img2img"
        
    # 参数解析
    parsed_params = {}
    
    # Size
    size_match = re.search(r"size=(\d+x\d+)", prompt_text)
    if size_match: parsed_params["size"] = size_match.group(1)
    
    # Steps
    steps_match = re.search(r"steps=(\d+)", prompt_text)
    if steps_match: parsed_params["steps"] = int(steps_match.group(1))
    
    # Strength
    str_match = re.search(r"strength=([\d.]+)", prompt_text)
    if str_match: parsed_params["strength"] = float(str_match.group(1))
    
    # Seed
    seed_match = re.search(r"seed=(\d+)", prompt_text)
    if seed_match: parsed_params["seed"] = int(seed_match.group(1))

    # 图片提取 (for img2img)
    image_b64 = None
    if mode == "img2img":
        # extract url
        # http/https, simple regex
        url_match = re.search(r"(https?://\S+)", prompt_text)
        if not url_match:
            raise HTTPException(status_code=400, detail="img2img mode requires an image URL in the prompt.")
            
        img_url = url_match.group(1)
        
        # Download image
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                resp = await client.get(img_url, follow_redirects=True)
                if resp.status_code != 200:
                    raise HTTPException(status_code=400, detail=f"Failed to download image from URL: {resp.status_code}")
                image_bytes = resp.content
                image_b64 = base64.b64encode(image_bytes).decode("utf-8")
        except Exception as e:
             raise HTTPException(status_code=400, detail=f"Failed to download image: {str(e)}")

    # 4. 构造任务请求 + 幂等键（同一请求重试命中同一 task_id）
    req_dict = {
        "mode": mode,
        "prompt": prompt_text,
        "response_format": "url",
        "sync": True,
    }
    if image_b64:
        req_dict["image_b64"] = image_b64
    req_dict.update(parsed_params)

    # 幂等键不包含 stream，故同一请求无论 stream=true/false 均命中同一 task_id
    canonical_for_fp = {"prompt": prompt_text, "size": parsed_params.get("size"), "steps": parsed_params.get("steps"), "n": 1, "strength": parsed_params.get("strength"), "seed": parsed_params.get("seed")}
    canonical_for_fp = {k: v for k, v in canonical_for_fp.items() if v is not None}
    if mode == "img2img" and image_b64:
        image_bytes_list = [base64.b64decode(image_b64)]
        idem_key = _compute_fingerprint_edits(canonical_for_fp, image_bytes_list)
    else:
        idem_key = _compute_fingerprint_txt2img(canonical_for_fp)

    prefer_async = (req.prefer_async is True) or _parse_prefer_async_header(x_prefer_async)
    base_url = str(request.base_url).rstrip("/")

    task_id, hit_type, existing_task = _idempotency_resolve(idem_key)

    if hit_type == "completed":
        t = existing_task
        if getattr(t, "result_urls", None) and getattr(t, "n_outputs", 1) > 1:
            img_url = f"{base_url}/outputs/{t.result_urls[0]}"
        else:
            img_url = f"{base_url}/outputs/{task_id}.png"
        content_text = f"✅ Generated image:\\n\\n![]({img_url})\\n\\nURL: {img_url}"
        return ChatCompletionResponse(
            id=f"chatcmpl-{task_id}",
            model=req.model or "glm-image",
            created=int(t.finished_at or time.time()),
            choices=[ChatChoice(index=0, message=ChatMessage(role="assistant", content=content_text), finish_reason="stop")],
        )

    if hit_type == "inflight":
        # 使用已有 task_id；若 prefer_async 则直接 202
        if prefer_async:
            current_task = task_store.get(task_id)
            status_val = current_task.status if current_task else "pending"
            return JSONResponse(
                status_code=202,
                content={"task_id": task_id, "status": status_val, "poll_url": f"{base_url}/v1/tasks/{task_id}"},
                headers={"Content-Type": "application/json"},
            )
    else:
        task_id = str(uuid.uuid4())
        now = time.time()
        task_info = TaskInfo(
            id=task_id,
            created_at=now,
            enqueue_time=now,
            deadline=now + TASK_TIMEOUT_SEC,
            request=req_dict,
        )
        task_store[task_id] = task_info
        idempotency_store[idem_key] = {"task_id": task_id, "ts": time.time()}
        _idempotency_evict_if_needed()
        try:
            await dispatch_task(task_id)
        except HTTPException:
            del task_store[task_id]
            idempotency_store.pop(idem_key, None)
            raise

        if prefer_async:
            current_task = task_store.get(task_id)
            status_val = current_task.status if current_task else "pending"
            return JSONResponse(
                status_code=202,
                content={"task_id": task_id, "status": status_val, "poll_url": f"{base_url}/v1/tasks/{task_id}"},
                headers={"Content-Type": "application/json"},
            )

    start_ts = time.time()
    wait_start = time.time()
    final_status = "unknown"
    final_error = None

    try:
        while True:
            if time.time() - wait_start > CHAT_SYNC_WAIT_TIMEOUT_SEC:
                final_status = "timeout"
                print(json.dumps({"event": "SYNC_WAIT_TIMEOUT", "task_id": task_id, "threshold_sec": CHAT_SYNC_WAIT_TIMEOUT_SEC, "stream_requested": stream_requested}))
                current_task = task_store.get(task_id)
                status_val = current_task.status if current_task else "pending"
                poll_url = f"{base_url}/v1/tasks/{task_id}"
                return JSONResponse(
                    status_code=202,
                    content={"task_id": task_id, "status": status_val, "poll_url": poll_url},
                    headers={"Content-Type": "application/json"},
                )

            current_task = task_store.get(task_id)
            if not current_task:
                final_status = "lost"
                raise HTTPException(status_code=404, detail="Task lost")

            if current_task.status == "completed":
                final_status = "completed"
                if getattr(current_task, "result_urls", None) and getattr(current_task, "n_outputs", 1) > 1:
                    img_url = f"{base_url}/outputs/{current_task.result_urls[0]}"
                else:
                    img_url = f"{base_url}/outputs/{task_id}.png"
                content_text = f"✅ Generated image:\\n\\n![]({img_url})\\n\\nURL: {img_url}"
                return ChatCompletionResponse(
                    id=f"chatcmpl-{task_id}",
                    model=req.model or "glm-image",
                    created=int(current_task.finished_at or time.time()),
                    choices=[
                        ChatChoice(
                            index=0,
                            message=ChatMessage(role="assistant", content=content_text),
                            finish_reason="stop",
                        )
                    ],
                )

            if current_task.status in ["failed", "expired", "cancelled"]:
                final_status = current_task.status
                final_error = current_task.error
                err_msg = current_task.error or f"Task is {current_task.status}"
                if err_msg == "Backend unreachable":
                    raise HTTPException(status_code=502, detail="Backend unreachable")
                if "exceeded TASK_TIMEOUT_SEC" in (err_msg or "") or "deadline exceeded" in (err_msg or "").lower() or "Backend timeout" in (err_msg or ""):
                    detail_504 = err_msg if ("exceeded TASK_TIMEOUT_SEC" in (err_msg or "") or "deadline exceeded" in (err_msg or "").lower()) else f"Task timeout (exceeded TASK_TIMEOUT_SEC={TASK_TIMEOUT_SEC}s)"
                    print(json.dumps({"event": "TASK_TIMEOUT", "task_id": task_id, "threshold_sec": TASK_TIMEOUT_SEC, "from_sync": True}))
                    raise HTTPException(status_code=504, detail=detail_504, headers={"X-Task-Id": task_id})
                raise HTTPException(status_code=500, detail=err_msg)

            await asyncio.sleep(0.5)
    finally:
        latency = time.time() - start_ts
        log_entry = {
            "event": "CHAT_ADAPTER_LOG",
            "task_id": task_id,
            "mode": mode,
            "stream_requested": stream_requested,
            "stream_effective": stream_effective,
            "sync": True,
            "response_format": "url",
            "model": req.model,
            "latency": latency,
            "status": final_status,
            "error": final_error,
            "params": parsed_params,
        }
        print(json.dumps(log_entry))
