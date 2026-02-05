#!/bin/bash
# 82_img2img_strength_ab.sh
# Test strength effectiveness by comparing outputs of low vs high strength.
source "$(dirname "$0")/_common.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
mkdir -p "$OUT_DIR"
INPUT_IMG="$OUT_DIR/img2img_input.png"

# Ensure input exists (generate noise if needed)
if [ ! -f "$INPUT_IMG" ]; then
    echo "Generating input image..."
    # Simple noise generation
    python3 -c "from PIL import Image; import numpy as np; Image.fromarray(np.random.randint(0,255,(512,512,3),dtype=np.uint8)).save('$INPUT_IMG')"
fi

URL="$BASE_URL/v1/images/edits"
PROMPT="turn this into a watercolor style"
SEED=12345

echo "---------------------------------------------------"
echo "[TEST] Img2Img Strength A/B"
echo "PROMPT: $PROMPT"
echo "SEED: $SEED"

# Ensure service is up
curl -s "$BASE_URL/health" > /dev/null || (echo "Service not up" && exit 1)

# Run Strength 0.2
echo "Requesting Strength 0.2..."
curl -s -X POST "$URL" \
  -H "bs-task-timeout: 300" \
  -F "image=@$INPUT_IMG" \
  -F "prompt=$PROMPT" \
  -F "strength=0.2" \
  -F "seed=$SEED" \
  -F "response_format=url" \
  -F "sync=true" > "$OUT_DIR/resp_02.json"

# Check response
if grep -q "error" "$OUT_DIR/resp_02.json"; then
    cat "$OUT_DIR/resp_02.json"
    echo "Error in req 0.2"
    exit 1
fi

URL_02=$(jq -r '.data[0].url' "$OUT_DIR/resp_02.json")
if [ "$URL_02" == "null" ]; then
    cat "$OUT_DIR/resp_02.json"
    exit 1
fi
echo "URL 0.2: $URL_02"
curl -s "$URL_02" -o "$OUT_DIR/img2img_strength_02.png"

# Run Strength 0.8
echo "Requesting Strength 0.8..."
curl -s -X POST "$URL" \
  -H "bs-task-timeout: 300" \
  -F "image=@$INPUT_IMG" \
  -F "prompt=$PROMPT" \
  -F "strength=0.8" \
  -F "seed=$SEED" \
  -F "response_format=url" \
  -F "sync=true" > "$OUT_DIR/resp_08.json"

URL_08=$(jq -r '.data[0].url' "$OUT_DIR/resp_08.json")
echo "URL 0.8: $URL_08"
curl -s "$URL_08" -o "$OUT_DIR/img2img_strength_08.png"

# Compare
echo "Comparing images..."
OUT_DIR="$OUT_DIR" python3 -c '
import numpy as np
from PIL import Image
import sys
import os
out = os.environ.get("OUT_DIR", "cli_tests/out")
try:
    img1 = Image.open(os.path.join(out, "img2img_strength_02.png")).convert("RGB").resize((512,512))
    img2 = Image.open(os.path.join(out, "img2img_strength_08.png")).convert("RGB").resize((512,512))
    a1 = np.asarray(img1, dtype=np.float32)
    a2 = np.asarray(img2, dtype=np.float32)
    mse = np.mean((a1 - a2) ** 2)
    mad = np.mean(np.abs(a1 - a2))
    print("MSE: {:.4f}".format(mse))
    print("MAD: {:.4f}".format(mad))
    with open(os.path.join(out, "img2img_strength_ab.txt"), "w") as f:
        f.write("MSE: {:.4f}\n".format(mse))
        f.write("MAD: {:.4f}\n".format(mad))
    if mse < 1.0:
        print("FAIL: Images are too similar!")
        sys.exit(1)
    else:
        print("PASS: Significant difference detected.")
except Exception as e:
    print("Error: {}".format(e))
    sys.exit(1)
'
