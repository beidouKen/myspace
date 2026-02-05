#!/bin/bash
source "$(dirname "$0")/common.sh"
OUT_DIR="$(dirname "$0")/../out"
mkdir -p "$OUT_DIR"

# 1. Pre-check: Service Health
log "Checking service health..."
if ! curl -s "$BASE_URL/health" | grep -q "ok"; then
    echo "Service not healthy at $BASE_URL."
    echo "Please run 'bash start.sh' first."
    exit 1
fi
pass "Service looks healthy."

# 2. Baseline Metrics
log "Fetching baseline metrics..."
curl -s "$BASE_URL/metrics" > "$OUT_DIR/mix_metrics_before.json"

# 3. Prepare Input Image
IMG_PATH="$OUT_DIR/img2img_input.png"
if [ ! -f "$IMG_PATH" ]; then
    log "Generating input image for img2img..."
    python3 -c "
from PIL import Image, ImageDraw
img = Image.new('RGB', (512, 512), color='white')
d = ImageDraw.Draw(img)
d.rectangle([100, 100, 412, 412], outline='black', width=5)
d.text((200, 250), 'INPUT', fill='black')
img.save('$IMG_PATH')
"
fi

# 4. Submit 3 Tasks (Concurrency Test)
log "Submitting 3 tasks (T1: txt2img, T2: img2img, T3: txt2img)..."

# Use the CURL_AUTH variable if defined, or just construct manually for simplicity and support of common.sh var
# But for multipart, we need specific flags.
AUTHORIZATION_HEADER=""
if [ -n "${API_KEY:-}" ]; then
  AUTHORIZATION_HEADER="-H \"Authorization: Bearer $API_KEY\""
fi

# T1: txt2img
curl -s -X POST "$BASE_URL/v1/images/generations" \
     -H "Content-Type: application/json" \
     ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
     -d '{"prompt": "a cute cat", "response_format": "url", "sync": false, "steps": 10}' \
     > "$OUT_DIR/mix_submit_t1.json" &
PID1=$!

# T2: img2img
curl -s -X POST "$BASE_URL/v1/images/edits" \
     ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
     -F "image=@$IMG_PATH" \
     -F "prompt=make it watercolor style" \
     -F "strength=0.65" \
     -F "response_format=url" \
     -F "sync=false" \
     -F "steps=10" \
     > "$OUT_DIR/mix_submit_t2.json" &
PID2=$!

# T3: txt2img
curl -s -X POST "$BASE_URL/v1/images/generations" \
     -H "Content-Type: application/json" \
     ${API_KEY:+-H "Authorization: Bearer $API_KEY"} \
     -d '{"prompt": "a cute bird", "response_format": "url", "sync": false, "steps": 10}' \
     > "$OUT_DIR/mix_submit_t3.json" &
PID3=$!

wait $PID1 $PID2 $PID3
log "Tasks submitted."

# Extract IDs
ID1=$(get_json_value "$(cat $OUT_DIR/mix_submit_t1.json)" "['task_id']")
ID2=$(get_json_value "$(cat $OUT_DIR/mix_submit_t2.json)" "['task_id']")
ID3=$(get_json_value "$(cat $OUT_DIR/mix_submit_t3.json)" "['task_id']")

if [ -z "$ID1" ] || [ -z "$ID2" ] || [ -z "$ID3" ]; then
    fail "Failed to get Task IDs. Check submit logs."
fi

log "IDs: T1=$ID1, T2=$ID2, T3=$ID3"

# 5. Polling & Timeline Recording
log "Polling task status..."

# Create a temporary file to store poll results
POLL_LOG="$OUT_DIR/mix_poll.log"
> "$POLL_LOG"

# Helper to get status
get_status() {
    curl -s "$BASE_URL/v1/tasks/$1" ${API_KEY:+-H "Authorization: Bearer $API_KEY"}
}

# Polling loop
log "Polling loop started..."
set +e
completed_count=0
MAX_LOOPS=600
loop_idx=0

while [ $completed_count -lt 3 ]; do
    if [ $loop_idx -gt $MAX_LOOPS ]; then
        log "Timeout waiting for tasks."
        break
    fi
    ((loop_idx++))

    TS=$(date +%s.%N)
    
    # Check T1
    RES1=$(get_status "$ID1")
    STATUS1=$(get_json_value "$RES1" "['status']")
    echo "$TS,T1,$ID1,$STATUS1" >> "$POLL_LOG"

    # Check T2
    RES2=$(get_status "$ID2")
    STATUS2=$(get_json_value "$RES2" "['status']")
    echo "$TS,T2,$ID2,$STATUS2" >> "$POLL_LOG"

    # Check T3
    RES3=$(get_status "$ID3")
    STATUS3=$(get_json_value "$RES3" "['status']")
    echo "$TS,T3,$ID3,$STATUS3" >> "$POLL_LOG"

    completed_count=0
    for s in "$STATUS1" "$STATUS2" "$STATUS3"; do
        if [[ "$s" == "completed" || "$s" == "failed" || "$s" == "cancelled" ]]; then
            ((completed_count++))
        fi
    done

    if [ $completed_count -lt 3 ]; then
        sleep 0.5
    fi
done
set -e

log "All tasks finished."

# 6. Analyze Timeline and Verify Concurrency
# We need to find the FIRST time each task went into "processing" state.
# And the final completion time.
# We also want to record the actual result URL for download.

# We'll use Python to parse the poll log and generate the CSV & Conclusion
python3 -c "
import sys
import collections

log_file = '$POLL_LOG'
out_csv = '$OUT_DIR/mix_timeline.csv'
report_file = '$OUT_DIR/mix_queue_proof.txt'
id_map = {'T1': '$ID1', 'T2': '$ID2', 'T3': '$ID3'}
names = {'T1': 'txt2img_cat', 'T2': 'img2img_watercolor', 'T3': 'txt2img_bird'}

# Load poll data
data = []
with open(log_file, 'r') as f:
    for line in f:
        parts = line.strip().split(',')
        if len(parts) >= 4:
            ts = float(parts[0])
            t_alias = parts[1]
            t_id = parts[2]
            status = parts[3]
            data.append({'ts': ts, 'alias': t_alias, 'id': t_id, 'status': status})

# Analyze
tasks = {alias: {'first_processing': None, 'completed_ts': None} for alias in names}

for row in data:
    alias = row['alias']
    status = row['status']
    ts = row['ts']
    
    if status == 'processing' and tasks[alias]['first_processing'] is None:
        tasks[alias]['first_processing'] = ts
    
    # Keep updating completed_ts until the end (it stays completed)
    # Ideally take the first time it becomes completed
    if status == 'completed' and tasks[alias]['completed_ts'] is None:
        tasks[alias]['completed_ts'] = ts

# Write CSV
with open(out_csv, 'w') as f:
    f.write('task_name,task_id,mode,first_seen_processing_ts,completed_ts,latency_sec\n')
    for alias in ['T1', 'T2', 'T3']:
        info = tasks[alias]
        lat = ''
        if info['first_processing'] and info['completed_ts']:
            lat = f\"{info['completed_ts'] - info['first_processing']:.2f}\"
        
        mode = 'txt2img' if alias != 'T2' else 'img2img'
        
        proc_str = f\"{info['first_processing']:.3f}\" if info['first_processing'] else 'NULL'
        comp_str = f\"{info['completed_ts']:.3f}\" if info['completed_ts'] else 'NULL'
        
        f.write(f\"{names[alias]},{id_map[alias]},{mode},{proc_str},{comp_str},{lat}\n\")

# Logic Verification
t1_start = tasks['T1']['first_processing']
t2_start = tasks['T2']['first_processing']
t3_start = tasks['T3']['first_processing']

verdict = 'FAIL'
reason = 'Unknown'

if t1_start is None:
    reason = 'T1 never started'
elif t2_start is None:
    reason = 'T2 never started'
elif t3_start is None:
    reason = 'T3 never started'
else:
    # Check 1: T1 & T2 close (Concurrent start)
    diff_1_2 = abs(t1_start - t2_start)
    # Check 2: T3 delayed
    # T3 should be later than min(t1, t2) + some delay. Or max?
    # Usually T3 only starts when one of T1/T2 finishes.
    # So T3 start should be > min(t1_complete, t2_complete) roughly.
    # The requirement says: T3 processing time significantly later than T1/T2 (at least 1.5s)
    
    # Let's say: T3_start > min(T1_start, T2_start) + 1.5
    start_delay = t3_start - min(t1_start, t2_start)
    
    # Check 1: Any 2 tasks started concurrently?
    # Check 2: The 3rd task was delayed?
    
    starts = []
    if t1_start is not None: starts.append(('T1', t1_start))
    if t2_start is not None: starts.append(('T2', t2_start))
    if t3_start is not None: starts.append(('T3', t3_start))
    
    starts.sort(key=lambda x: x[1])
    
    if len(starts) < 3:
         reason = f'Only {len(starts)} tasks started. Need 3.'
    else:
        # starts[0] and starts[1] should be close
        diff_concurrent = starts[1][1] - starts[0][1]
        
        # starts[2] should be delayed relative to starts[0] (or starts[1])
        # It should start after one of them finishes.
        delay_3rd = starts[2][1] - starts[1][1]
        
        if diff_concurrent < 1.0:
            if delay_3rd >= 1.5:
                verdict = 'PASS'
                reason = f'Verified: {starts[0][0]} & {starts[1][0]} concurrent (diff={diff_concurrent:.2f}s), {starts[2][0]} queued (delay={delay_3rd:.2f}s)'
            else:
                 reason = f'No queueing observed? 3rd task delay only {delay_3rd:.2f}s'
        else:
             reason = f'No concurrency observed. Start times: {[s[1] for s in starts]}'

# Output Report
with open(report_file, 'w') as f:
    f.write('Mixed Task Concurrent/Queue Proof\\n')
    f.write('=================================\\n')
    for alias in names:
        f.write(f'{alias} ID: {id_map[alias]}\\n')
    
    f.write('\\nTimeline:\\n')
    for alias in names:
         f.write(f\"{alias} Start: {tasks[alias].get('first_processing')}\\n\")

    f.write(f'\\nVerdict: {verdict}: {reason}\\n')

print(f'{verdict}: {reason}')
"

# 7. Download Outputs
log "Downloading outputs..."

# Need full task objects again to get URLs
RES1=$(get_status "$ID1")
URL1=$(get_json_value "$RES1" "['result']['url']")
if [ -n "$URL1" ]; then
    curl -s "$URL1" > "$OUT_DIR/mix_t1_cat.png"
fi

RES2=$(get_status "$ID2")
URL2=$(get_json_value "$RES2" "['result']['url']")
if [ -n "$URL2" ]; then
    curl -s "$URL2" > "$OUT_DIR/mix_t2_edit.png"
fi

RES3=$(get_status "$ID3")
URL3=$(get_json_value "$RES3" "['result']['url']")
if [ -n "$URL3" ]; then
    curl -s "$URL3" > "$OUT_DIR/mix_t3_bird.png"
fi

# Verify Files
echo "File Check:" > "$OUT_DIR/mix_files_check.txt"
file "$OUT_DIR/mix_t1_cat.png" >> "$OUT_DIR/mix_files_check.txt" 2>&1
file "$OUT_DIR/mix_t2_edit.png" >> "$OUT_DIR/mix_files_check.txt" 2>&1
file "$OUT_DIR/mix_t3_bird.png" >> "$OUT_DIR/mix_files_check.txt" 2>&1

# 8. Final Metrics
curl -s "$BASE_URL/metrics" > "$OUT_DIR/mix_metrics_after.json"

# Append metrics summary to report
echo "" >> "$OUT_DIR/mix_queue_proof.txt"
echo "Metrics Summary:" >> "$OUT_DIR/mix_queue_proof.txt"
python3 -c "
import json
try:
    with open('$OUT_DIR/mix_metrics_before.json') as f: b = json.load(f)
    with open('$OUT_DIR/mix_metrics_after.json') as f: a = json.load(f)
    print(f\"Queue Length: {b.get('queue_length')} -> {a.get('queue_length')}\")
    print(f\"Success Count: {b.get('success_count')} -> {a.get('success_count')}\")
except:
    print('Metrics parse error')
" >> "$OUT_DIR/mix_queue_proof.txt"

log "Done. Report at $OUT_DIR/mix_queue_proof.txt"
