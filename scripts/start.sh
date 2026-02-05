#!/bin/bash
# Remove set -e to debug/ensure logs appear
# set -e 

# Default Envs
export PORT=${PORT:-8000}
export BACKEND_PORT_START=${BACKEND_PORT_START:-8001}
export QUEUE_SIZE=${QUEUE_SIZE:-100}
export TASK_TIMEOUT_SEC=${TASK_TIMEOUT_SEC:-300}
export SYNC_WAIT_TIMEOUT_SEC=${SYNC_WAIT_TIMEOUT_SEC:-120}
export MODEL_DIR=${MODEL_DIR:-/root/models/zai-org/GLM-Image}
export OUTPUTS_DIR=${OUTPUTS_DIR:-/app/outputs}
export LOG_DIR=${LOG_DIR:-./logs}
export OUTPUT_TTL_SEC=${OUTPUT_TTL_SEC:-3600}
export NO_PROXY=localhost,127.0.0.1

# Self-check: MODEL_DIR must exist, OUTPUTS_DIR must be writable; exit 1 with clear error on failure
if [ ! -d "$MODEL_DIR" ]; then
    echo "ERROR: MODEL_DIR does not exist or is not a directory: $MODEL_DIR" >&2
    echo "Set MODEL_DIR to a valid path with model weights and retry." >&2
    exit 1
fi
mkdir -p "$OUTPUTS_DIR" "$LOG_DIR"
if ! [ -d "$OUTPUTS_DIR" ] || ! [ -w "$OUTPUTS_DIR" ]; then
    if [ ! -d "$OUTPUTS_DIR" ]; then
        echo "ERROR: OUTPUTS_DIR cannot be created or is not writable: $OUTPUTS_DIR" >&2
    else
        echo "ERROR: OUTPUTS_DIR is not writable: $OUTPUTS_DIR" >&2
    fi
    echo "Set OUTPUTS_DIR to a writable path and retry." >&2
    exit 1
fi

# Print effective config summary at start
echo "=== Start config summary ==="
echo "MODEL_DIR=$MODEL_DIR"
echo "OUTPUTS_DIR=$OUTPUTS_DIR"
echo "PORT=$PORT BACKEND_PORT_START=$BACKEND_PORT_START"
echo "QUEUE_SIZE=$QUEUE_SIZE TASK_TIMEOUT_SEC=$TASK_TIMEOUT_SEC SYNC_WAIT_TIMEOUT_SEC=$SYNC_WAIT_TIMEOUT_SEC"
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<auto>}"
echo "============================"

# Cleanup trap
pids=()
cleanup() {
    echo "Stopping all processes..."
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    wait
    echo "All stopped."
}
trap cleanup INT TERM EXIT

# GPU detection: respect external CUDA_VISIBLE_DEVICES (do not override; use only to determine backend count)
if [ -n "$CUDA_VISIBLE_DEVICES" ]; then
    echo "Using external CUDA_VISIBLE_DEVICES (not overwritten): $CUDA_VISIBLE_DEVICES"
    IFS=',' read -r -a GPU_LIST <<< "$CUDA_VISIBLE_DEVICES"
else
    # Auto detect
    if command -v nvidia-smi &> /dev/null; then
        count=$(nvidia-smi -L | wc -l)
        if [ "$count" -eq 0 ]; then
            echo "No GPU found via nvidia-smi. Using device 0 (CPU/Fallback)."
            GPU_LIST=(0)
        else
            echo "Detected $count GPUs via nvidia-smi"
            # generate sequence 0..count-1
            GPU_LIST=($(seq 0 $(($count - 1))))
        fi
    else
        echo "nvidia-smi not found. Defaulting to device 0."
        GPU_LIST=(0)
    fi
fi

# Start Backends
BACKEND_URLS=""
i=0
echo "Starting ${#GPU_LIST[@]} backend(s)..."

for gpu_id in "${GPU_LIST[@]}"; do
    current_port=$(($BACKEND_PORT_START + $i))
    
    # Set Env for this process
    (
        export CUDA_VISIBLE_DEVICES=$gpu_id
        export GPU_ID=$gpu_id
        export PORT=$current_port
        
        echo "[Backend-$i] Launching on GPU $gpu_id, Port $current_port..."
        exec uvicorn app.backend.main:app --host 127.0.0.1 --port $current_port > "$LOG_DIR/backend_$i.log" 2>&1
    ) &
    pid=$!
    pids+=($pid)
    
    # Construct URL list
    if [ -z "$BACKEND_URLS" ]; then
        BACKEND_URLS="http://127.0.0.1:$current_port"
    else
        BACKEND_URLS="$BACKEND_URLS,http://127.0.0.1:$current_port"
    fi
    
    ((i++))
done

# Wait a bit for backends to init (not strictly necessary but nicer logs)
sleep 2

# Start Gateway
echo "Starting Gateway on port $PORT..."
echo "Backends: $BACKEND_URLS"

export BACKEND_URLS
# Run directly in background, no subshell/exec mess if possible, 
# although subshell is cleaner for ENVs. 
# We'll stick to simple standard command.
# Also explicitly redirect output to verify it works.
uvicorn app.gateway.main:app --host 0.0.0.0 --port $PORT > "$LOG_DIR/gateway.log" 2>&1 &
gateway_pid=$!
pids+=($gateway_pid)

echo "Gateway PID: $gateway_pid"
echo "System running."
echo "Gateway: http://0.0.0.0:$PORT"
echo "Outputs: $OUTPUTS_DIR"
echo "Logs are being written to $LOG_DIR/"

# Wait for gateway; on exit (signal or crash) cleanup all backends
wait $gateway_pid 2>/dev/null || wait
cleanup
exit 0
