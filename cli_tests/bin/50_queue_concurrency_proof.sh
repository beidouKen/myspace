#!/bin/bash
# 50_queue_concurrency_proof.sh
# description: Verify parallel processing and queueing behavior (assumes 2 backends)
# env: BASE_URL, API_KEY, STEPS, POLL_INTERVAL

source "$(dirname "$0")/common.sh"
set -euo pipefail

# --- Config ---
PROMPTS=("a cute cat, high detail" "a cute dog, high detail" "a cute bird, high detail")
NAMES=("cat" "dog" "bird")
STEPS=${STEPS:-30} # Enough steps to make them last a few seconds
POLL_INTR=${POLL_INTERVAL:-0.3}
PROOF_DIR="$OUT_DIR/queue_proof"

mkdir -p "$PROOF_DIR"

log "Starting Queue Concurrency Proof Test..."
log "Target Steps: $STEPS, Poll Interval: $POLL_INTR"

# --- 1. Get initial metrics ---
log "Fetching metrics_before..."
$CURL_AUTH "$BASE_URL/metrics" > "$PROOF_DIR/metrics_before.json"
BACKEND_COUNT=$(python3 -c "import sys, json; print(len(json.load(sys.stdin).get('backends', {})))" < "$PROOF_DIR/metrics_before.json")
log "Detected Backend Count: $BACKEND_COUNT"

if [ "$BACKEND_COUNT" -lt 2 ]; then
    log "${RED}WARNING:${NC} Backend count is less than 2 ($BACKEND_COUNT). This test expects at least 2 backends to prove parallelism."
fi

# --- 2. Submit 3 Tasks ---
TASK_IDS=()
SUBMISSION_TIMES=()

log "Submitting 3 tasks concurrently..."

# We use & to fire requests almost simultaneously
pids=()
tmp_res_dir=$(mktemp -d)

for i in {0..2}; do
    name="${NAMES[$i]}"
    prompt="${PROMPTS[$i]}"
    (
        payload=$(printf '{"prompt": "%s", "steps": %d, "sync": false, "size": "256x256"}' "$prompt" "$STEPS")
        ts=$(date +%s.%3N)
        resp=$($CURL_AUTH -X POST -H "Content-Type: application/json" -d "$payload" "$BASE_URL/v1/images/generations")
        echo "$ts" > "$tmp_res_dir/$i.ts"
        echo "$resp" > "$tmp_res_dir/$i.resp"
    ) &
    pids+=($!)
done

wait "${pids[@]}"

# Gather submission results
submissions_json="["
for i in {0..2}; do
    ts=$(cat "$tmp_res_dir/$i.ts")
    resp=$(cat "$tmp_res_dir/$i.resp")
    tid=$(get_json_value "$resp" "['task_id']")
    
    if [ -z "$tid" ] || [ "$tid" == "None" ]; then
        fail "Failed to submit '${NAMES[$i]}': $resp"
    fi
    
    TASK_IDS+=("$tid")
    SUBMISSION_TIMES+=("$ts")
    log "Submitted '${NAMES[$i]}' at $ts -> ID: $tid"
    
    item=$(printf '{"name": "%s", "prompt": "%s", "submitted_at": %s, "task_id": "%s"}' "${NAMES[$i]}" "${PROMPTS[$i]}" "$ts" "$tid")
    if [ "$i" -gt 0 ]; then submissions_json+=","; fi
    submissions_json+="$item"
done
submissions_json+="]"
echo "$submissions_json" > "$PROOF_DIR/submissions.json"
rm -rf "$tmp_res_dir"

# --- 3. Poll Loop ---
TIMELINE_LOG="$PROOF_DIR/timeline.log"
: > "$TIMELINE_LOG"

log "Polling loop started..."
metrics_during_captured=false
start_poll_loop=$(date +%s)

# Status tracking
statuses=("pending" "pending" "pending")
start_times=("0" "0" "0")
finish_times=("0" "0" "0")

while true; do
    loop_ts=$(date +%s.%3N)
    line_log="t=$loop_ts"
    all_done=true
    
    processing_count=0
    
    for i in {0..2}; do
        tid="${TASK_IDS[$i]}"
        current_status="${statuses[$i]}"
        
        # Only poll if not terminal state to save requests, 
        # BUT we need accurate finish time so we poll until completed/failed
        if [[ "$current_status" != "completed" && "$current_status" != "failed" && "$current_status" != "expired" && "$current_status" != "cancelled" ]]; then
             all_done=false
             resp=$($CURL_AUTH "$BASE_URL/v1/tasks/$tid")
             new_status=$(get_json_value "$resp" "['status']")
             
             # Track Start Time (first time seeing processing)
             # Ideally use server-side "start_time" if available, but for now we observe manually or fetch from details
             if [ "$new_status" == "processing" ]; then
                 processing_count=$((processing_count + 1))
                 if [ "${start_times[$i]}" == "0" ]; then
                     # Try to get server-side start time
                     svr_start=$(get_json_value "$resp" "['start_time']")
                     if [ -n "$svr_start" ] && [ "$svr_start" != "None" ]; then
                         start_times[$i]=$svr_start
                     else
                         start_times[$i]=$loop_ts
                     fi
                 fi
             fi
             
             # Track Finish Time
             if [[ "$new_status" == "completed" || "$new_status" == "failed" ]]; then
                 svr_finish=$(get_json_value "$resp" "['completion_time']")
                 if [ -n "$svr_finish" ] && [ "$svr_finish" != "None" ]; then
                     finish_times[$i]=$svr_finish
                 else
                     finish_times[$i]=$loop_ts
                 fi
             fi
             
             statuses[$i]=$new_status
        elif [[ "$current_status" == "completed" || "$current_status" == "failed" ]]; then
             # Already done, just keep status for log
             : 
        fi
        
        line_log="$line_log ${NAMES[$i]}=${statuses[$i]}"
    done
    
    echo "$line_log" >> "$TIMELINE_LOG"
    
    # Capture "metrics_during" if we see at least 2 processing (proving parallelism)
    if [ "$processing_count" -ge 2 ] && [ "$metrics_during_captured" = false ]; then
        $CURL_AUTH "$BASE_URL/metrics" > "$PROOF_DIR/metrics_during.json"
        metrics_during_captured=true
        log "Captured metrics_during (processing=$processing_count)"
    fi
    
    if [ "$all_done" = true ]; then
        break
    fi
    
    # Safety timeout
    now=$(date +%s)
    if [ $((now - start_poll_loop)) -gt 300 ]; then
        fail "Timeout polling tasks"
    fi
    
    sleep "$POLL_INTR"
done

log "All tasks finished."

# --- 4. Get Final Metrics ---
log "Fetching metrics_after..."
$CURL_AUTH "$BASE_URL/metrics" > "$PROOF_DIR/metrics_after.json"

# --- 5. Download Images ---
log "Downloading images..."
for i in {0..2}; do
    tid="${TASK_IDS[$i]}"
    name="${NAMES[$i]}"
    url="$BASE_URL/outputs/$tid.png"
    out_path="$OUT_DIR/queue_${name}.png"
    
    if curl -s -f -o "$out_path" "$url"; then
        log "Downloaded $out_path"
    else
        log "${RED}Error downloading $out_path${NC}"
    fi
done

# Check files
log "Verifying images..."
file "$OUT_DIR"/queue_*.png > "$PROOF_DIR/file_check.txt"
cat "$PROOF_DIR/file_check.txt"

# --- 6. Analyze & Summarize ---
SUMMARY_FILE="$PROOF_DIR/summary.txt"
{
    echo "Queue Concurrency Proof Summary"
    echo "==============================="
    echo "Backend Count: $BACKEND_COUNT"
    echo ""
    echo "Tasks:"
    printf "%-10s %-20s %-20s %-20s\n" "Name" "Submitted" "Started" "Finished"
    
    for i in {0..2}; do
        printf "%-10s %-20s %-20s %-20s\n" "${NAMES[$i]}" "${SUBMISSION_TIMES[$i]}" "${start_times[$i]}" "${finish_times[$i]}"
    done
    echo ""
    
    # Analysis using python
    echo "timings = {" > "$PROOF_DIR/timings.py"
    for i in {0..2}; do
        echo "  '${NAMES[$i]}': {'start': ${start_times[$i]}, 'finish': ${finish_times[$i]}}," >> "$PROOF_DIR/timings.py"
    done
    echo "}" >> "$PROOF_DIR/timings.py"
    
    # Run analysis logic
    python3 -c "
import sys
# Load timings
exec(open('$PROOF_DIR/timings.py').read())

items = list(timings.items()) # [('cat', {...}), ...]
# Sort by start time
items.sort(key=lambda x: x[1]['start'])

t1_name, t1_data = items[0]
t2_name, t2_data = items[1]
t3_name, t3_data = items[2]

print(f'Execution Order: {t1_name}, {t2_name} -> {t3_name} (Queued)')

# 1. Parallelism Check (First two should start roughly together)
start_diff = abs(t1_data['start'] - t2_data['start'])
print(f'Parallel Pair ({t1_name}, {t2_name}) Start Diff: {start_diff:.3f}s')

is_parallel = start_diff < 1.0
print(f'PARALLELISM CHECK: {\"PASS\" if is_parallel else \"FAIL (diff >= 1s)\"}')

# 2. Queueing Check (Third should wait for a slot)
# Slot frees up when the *first* of parallel tasks finishes.
first_finish_time = min(t1_data['finish'], t2_data['finish'])
queue_wait_diff = t3_data['start'] - first_finish_time

print(f'{t3_name} Start: {t3_data[\"start\"]}')
print(f'First Slot Free: {first_finish_time} (by {t1_name if t1_data[\"finish\"] == first_finish_time else t2_name})')
print(f'Gap: {queue_wait_diff:.3f}s')

# Allow 1.0s tolerance. It expects t3 start >= first_finish - 1.0
is_queued = t3_data['start'] >= (first_finish_time - 1.0)
print(f'QUEUE CHECK: {\"PASS\" if is_queued else \"FAIL (Started too early)\"}')

if is_parallel and is_queued:
    print('OVERALL RESULT: PASS')
else:
    print('OVERALL RESULT: FAIL')
    sys.exit(1)

" >> "$SUMMARY_FILE" 2>&1

}

log "Summary Generated at $SUMMARY_FILE"
cat "$SUMMARY_FILE"

# Clean up temp
rm -f "$PROOF_DIR/timings.py"

