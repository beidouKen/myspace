import os
import io
import time
import torch
import asyncio
import random
import json
import logging
import base64
import numpy as np
from concurrent.futures import ThreadPoolExecutor
from fastapi import FastAPI, Response, HTTPException
from fastapi.responses import StreamingResponse, JSONResponse
from pydantic import BaseModel, Field
from typing import Optional, List
from contextlib import asynccontextmanager
from PIL import Image
import types
import inspect

# Import pipeline
try:
    from diffusers.pipelines.glm_image import GlmImagePipeline
except ImportError:
    print("Warning: diffusers.pipelines.glm_image not found, trying generic DiffusionPipeline")
    from diffusers import DiffusionPipeline as GlmImagePipeline

# Set up Logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# --- Configuration (Env Defaults) ---
DEFAULT_STEPS = int(os.environ.get("DEFAULT_STEPS", "45"))
MIN_STEPS = int(os.environ.get("MIN_STEPS", "20"))
MAX_STEPS = int(os.environ.get("MAX_STEPS", "80"))
DEFAULT_SIZE = os.environ.get("DEFAULT_SIZE", "1024x1024")

RETRY_ON_BAD_OUTPUT = int(os.environ.get("RETRY_ON_BAD_OUTPUT", "1"))
RETRY_EXTRA_STEPS = int(os.environ.get("RETRY_EXTRA_STEPS", "10"))
DEFAULT_GUIDANCE = float(os.environ.get("DEFAULT_GUIDANCE", "4.0"))

# Img2Img Defaults
DEFAULT_STRENGTH = float(os.environ.get("DEFAULT_STRENGTH", "0.65"))
MIN_STRENGTH = float(os.environ.get("MIN_STRENGTH", "0.1"))
MAX_STRENGTH = float(os.environ.get("MAX_STRENGTH", "0.95"))

ALLOWED_SIZES = ["512x512", "768x768", "1024x1024"]
INFERENCE_TIMEOUT_SEC = float(os.environ.get("INFERENCE_TIMEOUT_SEC", "180"))
# P3.3: 测试用，1 时 n>1 强制走循环生成，默认 0
FORCE_FALLBACK_LOOP = int(os.environ.get("FORCE_FALLBACK_LOOP", "0")) == 1

app = FastAPI()

# Global state
pipe = None
MODEL_PATH = os.environ.get("MODEL_DIR", "/root/models/zai-org/GLM-Image")
OUTPUTS_DIR = os.environ.get("OUTPUTS_DIR", "/app/outputs")
GPU_ID = os.environ.get("GPU_ID", "0") 

# Thread pool for blocking inference
executor = ThreadPoolExecutor(max_workers=1)


def _print_backend_config_summary():
    """Print effective config summary at startup (MODEL_DIR, OUTPUTS_DIR, QUEUE/TIMEOUT N/A, DEFAULT/MIN/MAX, GPU mapping)."""
    summary = {
        "MODEL_DIR": MODEL_PATH,
        "OUTPUTS_DIR": OUTPUTS_DIR,
        "GPU_ID": GPU_ID,
        "CUDA_VISIBLE_DEVICES": os.environ.get("CUDA_VISIBLE_DEVICES"),
        "INFERENCE_TIMEOUT_SEC": INFERENCE_TIMEOUT_SEC,
        "DEFAULT_STEPS": DEFAULT_STEPS,
        "MIN_STEPS": MIN_STEPS,
        "MAX_STEPS": MAX_STEPS,
        "DEFAULT_SIZE": DEFAULT_SIZE,
        "DEFAULT_STRENGTH": DEFAULT_STRENGTH,
        "MIN_STRENGTH": MIN_STRENGTH,
        "MAX_STRENGTH": MAX_STRENGTH,
        "FORCE_FALLBACK_LOOP": FORCE_FALLBACK_LOOP,
    }
    logger.info("Backend effective config summary: %s", json.dumps(summary))


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pipe
    _print_backend_config_summary()
    logger.info(f"[{GPU_ID}] Loading model from {MODEL_PATH}...")
    t0 = time.time()
    try:
        pipe = GlmImagePipeline.from_pretrained(
            MODEL_PATH,
            torch_dtype=torch.bfloat16,
            device_map="cuda", 
            low_cpu_mem_usage=True
        )
        
        # --- PATCH: Fix GLM-Image Pipeline Img2Img Bug ---
        # The library pipeline fails with "cat() received an invalid combination of arguments"
        # because get_image_features returns HF ModelOutput objects instead of Tensors.
        if hasattr(pipe, "vision_language_encoder") and hasattr(pipe.vision_language_encoder, "get_image_features"):
            logger.info(f"[{GPU_ID}] Patching vision_language_encoder.get_image_features for Img2Img fix...")
            orig_get_feats = pipe.vision_language_encoder.get_image_features
            
            # Note: patched method receives 'self' as first arg because it is bound using MethodType.
            # But orig_get_feats is ALREADY a bound method capturing 'self'.
            # So we must ignore the 'self' passed to this function and forward only the rest args.
            def patched_get_image_features(self_instance, *args, **kwargs):
                res = orig_get_feats(*args, **kwargs)
                
                final_tensor = None
                
                # 1. unwrapping list/tuple
                if isinstance(res, (list, tuple)):
                    if len(res) > 0 and isinstance(res[0], torch.Tensor):
                         # Already correct
                         return res
                    if len(res) > 0:
                         # Unwrap to check usage
                         res = res[0]

                # 2. Extract from ModelOutput
                # Check for pooler_output (preferred for CLIP-like embeddings)
                if hasattr(res, "pooler_output") and res.pooler_output is not None:
                     final_tensor = res.pooler_output
                     # logger.debug(f"[Patch] extracted pooler_output: {final_tensor.shape} {final_tensor.dtype}")
                # Fallback to last_hidden_state (maybe need pooling, but returning it as is better than crashing)
                elif hasattr(res, "last_hidden_state") and res.last_hidden_state is not None:
                     final_tensor = res.last_hidden_state
                     # logger.debug(f"[Patch] extracted last_hidden_state: {final_tensor.shape} {final_tensor.dtype}")
                elif isinstance(res, torch.Tensor):
                     final_tensor = res
                
                if final_tensor is not None:
                     # Ensure list for torch.cat
                     if not isinstance(final_tensor, (list, tuple)):
                         return [final_tensor]
                     return final_tensor

                return res
            
            pipe.vision_language_encoder.get_image_features = types.MethodType(patched_get_image_features, pipe.vision_language_encoder)
        # -------------------------------------------------

        logger.info(f"[{GPU_ID}] Model loaded in {time.time() - t0:.2f}s")
    except Exception as e:
        logger.error(f"[{GPU_ID}] Failed to load model: {e}")
        raise e
    yield
    if pipe:
        del pipe
        torch.cuda.empty_cache()

app = FastAPI(lifespan=lifespan)

class InferRequest(BaseModel):
    task_id: str
    prompt: str
    mode: str = "txt2img" # txt2img | img2img
    image_b64: Optional[str] = None # For img2img (single)
    images_b64: Optional[List[str]] = None # Phase 3: 多图融合条件
    
    # Optional fields
    n: Optional[int] = 1  # 输出张数，严格 data.length == n
    size: Optional[str] = None
    steps: Optional[int] = None
    guidance: Optional[float] = None
    seed: Optional[int] = None
    strength: Optional[float] = None # For img2img

@app.get("/health")
async def health():
    return {"status": "ok", "gpu_id": GPU_ID, "model_loaded": pipe is not None}

def detect_bad_output(img: Image.Image) -> bool:
    try:
        if img.mode != 'RGB':
            img = img.convert('RGB')
        stat = np.array(img).std()
        if stat < 10: 
            return True
        return False
    except Exception:
        return False

def run_inference(task_id: str, mode: str, prompt: str, steps: int, size_str: str, 
                 guidance: float, seed: Optional[int], strength: float, image_b64: Optional[str],
                 images_b64_list: Optional[List[str]] = None,
                 num_images_per_prompt: int = 1,
                 retry_policy=True):
    """Phase 3: 调用层支持 image 列表与 n；核心算法/模型代码不变。返回 (list_of_png_bytes, duration)。"""
    t0 = time.time()
    retried = 0
    
    current_steps = steps
    current_seed = seed if seed is not None else random.randint(0, 2**32 - 1)
    
    # Input Image(s) for img2img — 多图融合 image=[img1, img2, ...]
    input_images = []
    if mode == "img2img":
        if images_b64_list:
            for b64 in images_b64_list:
                try:
                    image_bytes = base64.b64decode(b64)
                    img = Image.open(io.BytesIO(image_bytes))
                    if img.mode != "RGB":
                        img = img.convert("RGB")
                    input_images.append(img)
                except Exception as e:
                    raise ValueError(f"Invalid image in list: {e}")
        elif image_b64:
            try:
                image_bytes = base64.b64decode(image_b64)
                img = Image.open(io.BytesIO(image_bytes))
                if img.mode != "RGB":
                    img = img.convert("RGB")
                input_images.append(img)
            except Exception as e:
                raise ValueError(f"Invalid image input: {e}")
        if not input_images:
            raise ValueError("image_b64 or images_b64 is required for img2img")
    
    # Resolve Size
    w, h = 1024, 1024
    if size_str:
        try:
            w, h = map(int, size_str.split('x'))
        except:
            w, h = 1024, 1024 # Fallback
    
    # If img2img: resize all input images
    if mode == "img2img" and input_images:
        input_images = [im.resize((w, h), Image.LANCZOS) for im in input_images]
    input_image = input_images[0] if input_images else None  # 兼容下方单图变量名
    
    # 1. First Attempt
    try:
        strength_effective = False
        strength_param_name = None
        
        generator = torch.Generator(device="cuda").manual_seed(current_seed)
        
        call_kwargs = {
            "prompt": prompt,
            "num_inference_steps": current_steps,
            "generator": generator,
            "height": h,
            "width": w
        }
        # Phase 3: 输出张数严格 data.length == n；pipeline 可能不支持 num_images_per_prompt>1，用多次调用凑齐
        # Guidance Check
        call_kwargs["guidance_scale"] = guidance

        if mode == "img2img":
            # --- Strength Logic Start ---
            # 1. Detect native support
            pipe_sig = inspect.signature(pipe.__call__)
            pipe_params = pipe_sig.parameters.keys()
            
            p_name = None
            if "strength" in pipe_params: p_name = "strength"
            elif "denoising_strength" in pipe_params: p_name = "denoising_strength"
            elif "image_strength" in pipe_params: p_name = "image_strength"
            
            if p_name:
                call_kwargs["image"] = input_images  # Phase 3: 多图融合
                call_kwargs[p_name] = strength
                strength_effective = True
                strength_param_name = p_name
            else:
                # 2. Manual strength via latents
                try:
                    # Check requirements
                    if hasattr(pipe, "vae") and hasattr(pipe, "scheduler") and hasattr(pipe, "image_processor"):
                        # Encode (use first image for latent path)
                        device = pipe.device
                        dtype = pipe.dtype
                        
                        img_t = pipe.image_processor.preprocess(input_image)
                        img_t = img_t.to(device=device, dtype=dtype)
                        
                        # Scaling
                        scaling_factor = 0.18215
                        if hasattr(pipe.vae, "config") and hasattr(pipe.vae.config, "scaling_factor"):
                            scaling_factor = pipe.vae.config.scaling_factor
                        
                        # VAE Encode
                        with torch.no_grad():
                            # Handle different VAE output types
                            enc = pipe.vae.encode(img_t)
                            if hasattr(enc, 'latent_dist'):
                                latents = enc.latent_dist.sample(generator=generator)
                            else:
                                latents = enc.latents # Hypothetical
                            latents = latents * scaling_factor
                        
                        # Timesteps
                        pipe.scheduler.set_timesteps(current_steps, device=device)
                        timesteps = pipe.scheduler.timesteps
                        
                        # Slice
                        eff_strength = max(0.01, min(strength, 1.0))
                        # e.g. 50 steps. strength 0.8 => start at index 10 (run 40 steps)?
                        # No, strength 0.8 means HIGH NOISE (almost new image). Run MORE steps.
                        # strength 0.2 means LOW NOISE (keep original). Run FEWER steps.
                        # steps_to_run = total * strength.
                        steps_to_run = int(len(timesteps) * eff_strength)
                        start_idx = len(timesteps) - steps_to_run
                        
                        sliced_timesteps = timesteps[start_idx:]
                        
                        if len(sliced_timesteps) > 0:
                            start_t = sliced_timesteps[0]
                            noise = torch.randn(latents.shape, generator=generator, device=device, dtype=dtype)
                            noisy_latents = pipe.scheduler.add_noise(latents, noise, start_t.unsqueeze(0))
                            
                            call_kwargs["latents"] = noisy_latents
                            call_kwargs["timesteps"] = sliced_timesteps
                            call_kwargs["image"] = input_images # Pass condition
                            
                            strength_effective = True
                            strength_param_name = "manual_latents"
                            logger.info(f"[{GPU_ID}] Manual Img2Img: strength={strength:.2f} -> {len(sliced_timesteps)} steps")
                        else:
                             call_kwargs["image"] = input_images
                    else:
                        call_kwargs["image"] = input_images
                except Exception as e:
                    logger.warning(f"Manual Img2Img failed: {e}")
                    call_kwargs["image"] = input_images
            # --- Strength Logic End ---

        # Safe Call Wrapper
        def safe_pipe_call(kwargs):
            try:
                out = pipe(**kwargs)
                return out
            except TypeError as te:
                # Fallback: remove args that might not be supported
                # Specifically guidance or strength if pipeline is weird
                s_te = str(te)
                if "guidance_scale" in s_te and "guidance_scale" in kwargs:
                    logger.warning(f"[{GPU_ID}] Dropping guidance_scale")
                    del kwargs["guidance_scale"]
                    return safe_pipe_call(kwargs)
                if "strength" in s_te and "strength" in kwargs:
                    logger.warning(f"[{GPU_ID}] Dropping strength")
                    del kwargs["strength"]
                    return safe_pipe_call(kwargs)
                raise te

        want_n = max(1, num_images_per_prompt)
        dev = getattr(pipe, "device", "cuda")
        images_out = []
        n_mode = "single_call"  # 用于 INFERENCE_LOG；n>1 时可能改为 fallback_loop

        if want_n == 1:
            with torch.inference_mode():
                out = safe_pipe_call(call_kwargs)
            images_out = [out.images[0]] if (hasattr(out, "images") and out.images) else []
            if not images_out:
                raise ValueError("Pipeline returned no images")
            img = images_out[0]
            # 2. Check & Retry（仅 n==1 时做 bad output 重试）
            is_bad = detect_bad_output(img)
            if is_bad and retry_policy and RETRY_ON_BAD_OUTPUT == 1:
                logger.warning(f"[{GPU_ID}] Detected bad output for {task_id}, retrying...")
                retried = 1
                current_steps = min(current_steps + RETRY_EXTRA_STEPS, MAX_STEPS)
                current_seed = random.randint(0, 2**32 - 1)
                call_kwargs["num_inference_steps"] = current_steps
                call_kwargs["generator"] = torch.Generator(device=dev).manual_seed(current_seed)
                with torch.inference_mode():
                    out = safe_pipe_call(call_kwargs)
                images_out = [out.images[0]]
                img = images_out[0]
        else:
            # P3.3: n>1 优先单次推理 num_images_per_prompt=want_n，失败则回退循环
            if FORCE_FALLBACK_LOOP:
                n_mode = "fallback_loop"
                for _ in range(want_n):
                    current_seed = random.randint(0, 2**32 - 1)
                    call_kwargs["generator"] = torch.Generator(device=dev).manual_seed(current_seed)
                    with torch.inference_mode():
                        out = safe_pipe_call(call_kwargs)
                    if out.images:
                        images_out.append(out.images[0])
            else:
                try:
                    single_kwargs = {**call_kwargs, "num_images_per_prompt": want_n}
                    with torch.inference_mode():
                        out = safe_pipe_call(single_kwargs)
                    images_out = list(out.images) if (hasattr(out, "images") and out.images) else []
                    if len(images_out) < want_n:
                        raise ValueError(f"single_call returned {len(images_out)} images, need {want_n}")
                    n_mode = "single_call"
                except Exception as e:
                    logger.info(json.dumps({"event": "N_MULTI_FALLBACK", "reason": str(e), "want_n": want_n}))
                    n_mode = "fallback_loop"
                    images_out = []
                    for _ in range(want_n):
                        current_seed = random.randint(0, 2**32 - 1)
                        call_kwargs["generator"] = torch.Generator(device=dev).manual_seed(current_seed)
                        with torch.inference_mode():
                            out = safe_pipe_call(call_kwargs)
                        if out.images:
                            images_out.append(out.images[0])
            img = images_out[0] if images_out else None

        n_out = len(images_out)
        if n_out == 0:
            raise ValueError("Pipeline returned no images")

        # Save & Encode — 返回 list of BytesIO（n=1 或 n>1）
        os.makedirs(OUTPUTS_DIR, exist_ok=True)
        result_list = []
        for i, im in enumerate(images_out):
            arr = io.BytesIO()
            im.save(arr, format='PNG')
            arr.seek(0)
            result_list.append(arr)
        
        duration = time.time() - t0
        
        # Log（P3.3: n_mode 用于验收与可观测）
        log_entry = json.dumps({
            "task_id": task_id,
            "mode": mode,
            "gpu_id": GPU_ID,
            "steps": current_steps,
            "size": f"{w}x{h}",
            "guidance": guidance if "guidance_scale" in call_kwargs else None,
            "strength": strength if mode == "img2img" else None,
            # Strength debug
            "strength_effective": strength_effective,
            "strength_param_name": strength_param_name,
            "seed": current_seed,
            "latency_sec": round(duration, 3),
            "retried": retried,
            "n_outputs": len(result_list),
            "n_mode": n_mode
        })
        logger.info(f"INFERENCE_LOG: {log_entry}")
        
        return result_list, duration

    except Exception as e:
        logger.error(f"[{GPU_ID}] Inference error: {e}")
        raise e

@app.post("/infer")
async def infer(request: InferRequest):
    if pipe is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    logger.info(f"[{GPU_ID}] processing task {request.task_id} mode={request.mode}")
    
    # Defaults / Validation
    # Size
    req_size = request.size or DEFAULT_SIZE
    if req_size not in ALLOWED_SIZES:
         # Fallback logic: if user explicitly requested bad size, error out
         if request.size:
             raise HTTPException(status_code=400, detail=f"Invalid size. Allowed: {ALLOWED_SIZES}")
         else:
             req_size = "1024x1024" # Safe default

    # Steps
    req_steps = request.steps if request.steps is not None else DEFAULT_STEPS
    req_steps = max(MIN_STEPS, min(req_steps, MAX_STEPS))
    
    # Guidance
    req_guidance = request.guidance if request.guidance is not None else DEFAULT_GUIDANCE
    
    # Strength
    req_strength = request.strength if request.strength is not None else DEFAULT_STRENGTH
    req_strength = max(MIN_STRENGTH, min(req_strength, MAX_STRENGTH))
    
    # Phase 3: 多图融合 images_b64 或单图 image_b64；n 输出张数
    images_b64_list = request.images_b64 if request.images_b64 else ([request.image_b64] if request.image_b64 else None)
    n_out = request.n if request.n is not None else 1
    
    loop = asyncio.get_running_loop()
    
    try:
        future = loop.run_in_executor(
            executor, 
            run_inference, 
            request.task_id,
            request.mode,
            request.prompt, 
            req_steps,
            req_size,
            req_guidance,
            request.seed,
            req_strength,
            request.image_b64,
            images_b64_list,
            n_out,
            True # retry_policy
        )
        
        result_list, duration = await asyncio.wait_for(future, timeout=INFERENCE_TIMEOUT_SEC)
        
        if len(result_list) == 1:
            return StreamingResponse(result_list[0], media_type="image/png")
        # Phase 3: 多张输出返回 JSON
        b64_list = [base64.b64encode(b.getvalue()).decode("utf-8") for b in result_list]
        return JSONResponse(content={"images_b64": b64_list, "count": len(b64_list)})
        
    except asyncio.TimeoutError:
        logger.error(f"[{GPU_ID}] Task {request.task_id} timed out")
        raise HTTPException(status_code=504, detail="Inference timed out")
    except torch.cuda.OutOfMemoryError:
        logger.error(f"[{GPU_ID}] OOM for task {request.task_id}")
        torch.cuda.empty_cache()
        raise HTTPException(status_code=500, detail="CUDA Out of Memory")
    except HTTPException as he:
        raise he
    except Exception as e:
        logger.error(f"[{GPU_ID}] Error for task {request.task_id}: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))
