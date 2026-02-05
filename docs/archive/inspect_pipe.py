
import torch
import inspect
from app.backend.main import MODEL_PATH
from diffusers import DiffusionPipeline

# It seems we are using a custom pipeline 'GlmImagePipeline' but loading it via 'app.backend.main' creates context.
# I will try to load it minimally or just check the installed library if possible.
# Actually, the quickest way is to inspect it inside the running app via a simple script executed in the backend context 
# or just start a python shell.

# Let's try to load the pipeline class and inspect it.
try:
    # Assuming the code in main.py imports it. Let's look at main.py imports first.
    from app.backend.main import GlmImagePipeline
    print("Pipeline class found")
    
    sig = inspect.signature(GlmImagePipeline.__call__)
    print("Pipeline.__call__ parameters:", sig.parameters.keys())
except ImportError:
    print("Could not import GlmImagePipeline directly.")
    # Fallback: try to finding where it comes from in main.py
