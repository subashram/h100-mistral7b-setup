#!/usr/bin/env bash
# =============================================================================
# Benchmark — concurrent multi-user load test for the OpenAI-compatible API
# =============================================================================
set -euo pipefail

ENDPOINT="${ENDPOINT:-https://localhost/v1}"
API_KEY="${API_KEY:-sk-prod-key-1}"
MODEL="${MODEL:-mistralai/Mistral-7B-Instruct-v0.3}"
TOTAL_REQUESTS="${TOTAL_REQUESTS:-200}"
CONCURRENCY="${CONCURRENCY:-32}"
MAX_TOKENS="${MAX_TOKENS:-64}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-180}"
TEST_MODE="${TEST_MODE:-chat}"          # chat | stream | tools
PROMPT="${PROMPT:-Explain batching in one short paragraph.}"
INSECURE_TLS="${INSECURE_TLS:-1}"
KEEP_TMP_DIR="${KEEP_TMP_DIR:-0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
TMP_DIR="$(mktemp -d)"
cleanup() {
    if [ "$KEEP_TMP_DIR" = "1" ]; then
        echo "Preserving benchmark artifacts in $TMP_DIR"
    else
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

require_int() {
    local name="$1"
    local value="$2"
    case "$value" in
        ''|*[!0-9]*)
            err "$name must be a positive integer (got '$value')"
            exit 1
            ;;
    esac
}

build_payload() {
    local request_id="$1"
    case "$TEST_MODE" in
        chat)
            cat <<EOF
{
  "model": "$MODEL",
  "messages": [
    {"role":"system","content":"Be concise and accurate."},
    {"role":"user","content":"$PROMPT Request $request_id."}
  ],
  "max_tokens": $MAX_TOKENS
}
EOF
            ;;
        stream)
            cat <<EOF
{
  "model": "$MODEL",
  "messages": [
    {"role":"system","content":"Be concise and accurate."},
    {"role":"user","content":"$PROMPT Request $request_id."}
  ],
  "max_tokens": $MAX_TOKENS,
  "stream": true
}
EOF
            ;;
        tools)
            cat <<EOF
{
  "model": "$MODEL",
  "messages": [
    {"role":"user","content":"What is the weather in Dallas for request $request_id?"}
  ],
  "temperature": 0,
  "max_tokens": $MAX_TOKENS,
  "tools": [{
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get weather for a location",
      "parameters": {
        "type": "object",
        "properties": {
          "location": {"type": "string"}
        },
        "required": ["location"]
      }
    }
  }],
  "tool_choice": "auto"
}
EOF
            ;;
        *)
            err "Unsupported TEST_MODE '$TEST_MODE' (use chat, stream, or tools)"
            exit 1
            ;;
    esac
}

request_ok() {
    local body_file="$1"
    case "$TEST_MODE" in
        chat)
            grep -q '"choices"' "$body_file"
            ;;
        stream)
            grep -q 'data:' "$body_file"
            ;;
        tools)
            grep -Eq 'tool_calls|function_call' "$body_file"
            ;;
    esac
}

run_one() {
    local request_id="$1"
    local body_file="$TMP_DIR/$request_id.body"
    local meta_file="$TMP_DIR/$request_id.meta"
    local ok_file="$TMP_DIR/$request_id.ok"
    local fail_file="$TMP_DIR/$request_id.fail"
    local curl_flags=(-sS --max-time "$REQUEST_TIMEOUT")

    if [ "$INSECURE_TLS" = "1" ]; then
        curl_flags+=(-k)
    fi

    build_payload "$request_id" > "$TMP_DIR/$request_id.payload.json"

    if curl "${curl_flags[@]}" \
        -o "$body_file" \
        -w "%{http_code} %{time_total} %{size_download}" \
        -X POST "$ENDPOINT/chat/completions" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --data @"$TMP_DIR/$request_id.payload.json" \
        > "$meta_file" 2>"$TMP_DIR/$request_id.stderr"; then
        :
    else
        echo "000 0 0" > "$meta_file"
    fi

    local http_code latency size_download
    read -r http_code latency size_download < "$meta_file"

    rm -f "$ok_file" "$fail_file"

    if [ "$http_code" = "200" ]; then
        if request_ok "$body_file"; then
            printf "%s\n" "$latency" > "$ok_file"
            return 0
        fi
    fi

    printf "%s %s %s\n" "$http_code" "$latency" "$size_download" > "$fail_file"
    return 0
}

summarize_count() {
    local pattern="$1"
    find "$TMP_DIR" -name "$pattern" -print | wc -l | tr -d ' '
}

collect_latency_files() {
    find "$TMP_DIR" -name '*.ok' -exec cat {} \; | sort -n > "$TMP_DIR/latencies.txt"
}

SUCCESS_COUNT=0
FAIL_COUNT=0

run_benchmark() {
    BENCHMARK_START="$(date +%s)"

    export ENDPOINT API_KEY MODEL TOTAL_REQUESTS CONCURRENCY MAX_TOKENS REQUEST_TIMEOUT TEST_MODE PROMPT INSECURE_TLS TMP_DIR
    export -f build_payload request_ok run_one

    seq 1 "$TOTAL_REQUESTS" | xargs -n 1 -P "$CONCURRENCY" -I '{}' bash -lc 'run_one "$1"' _ '{}'

    BENCHMARK_END="$(date +%s)"
    ELAPSED=$((BENCHMARK_END - BENCHMARK_START))
    [ "$ELAPSED" -eq 0 ] && ELAPSED=1

    SUCCESS_COUNT="$(summarize_count '*.ok')"
    FAIL_COUNT="$(summarize_count '*.fail')"
    collect_latency_files
}

require_int "TOTAL_REQUESTS" "$TOTAL_REQUESTS"
require_int "CONCURRENCY" "$CONCURRENCY"
require_int "MAX_TOKENS" "$MAX_TOKENS"
require_int "REQUEST_TIMEOUT" "$REQUEST_TIMEOUT"

if [ "$TOTAL_REQUESTS" -eq 0 ] || [ "$CONCURRENCY" -eq 0 ]; then
    err "TOTAL_REQUESTS and CONCURRENCY must be greater than zero"
    exit 1
fi

log "Benchmarking $ENDPOINT"
echo "Mode:          $TEST_MODE"
echo "Model:         $MODEL"
echo "Requests:      $TOTAL_REQUESTS"
echo "Concurrency:   $CONCURRENCY"
echo "Max tokens:    $MAX_TOKENS"
echo "Timeout (s):   $REQUEST_TIMEOUT"
echo ""

run_benchmark

if [ -s "$TMP_DIR/latencies.txt" ]; then
    AVG_LATENCY=$(awk '{sum+=$1} END {printf "%.3f", sum/NR}' "$TMP_DIR/latencies.txt")
    P50_LATENCY=$(awk '{
        values[NR]=$1
    } END {
        idx = int((NR + 1) * 0.50)
        if (idx < 1) idx = 1
        if (idx > NR) idx = NR
        printf "%.3f", values[idx]
    }' "$TMP_DIR/latencies.txt")
    P95_LATENCY=$(awk '{
        values[NR]=$1
    } END {
        idx = int((NR + 1) * 0.95)
        if (idx < 1) idx = 1
        if (idx > NR) idx = NR
        printf "%.3f", values[idx]
    }' "$TMP_DIR/latencies.txt")
else
    AVG_LATENCY="n/a"
    P50_LATENCY="n/a"
    P95_LATENCY="n/a"
fi

REQ_PER_SEC=$(awk -v total="$TOTAL_REQUESTS" -v elapsed="$ELAPSED" 'BEGIN {printf "%.2f", total/elapsed}')
SUCCESS_RATE=$(awk -v ok="$SUCCESS_COUNT" -v total="$TOTAL_REQUESTS" 'BEGIN {printf "%.2f", (ok/total)*100}')

echo "========================"
echo "Benchmark Summary"
echo "========================"
echo "Successful requests: $SUCCESS_COUNT"
echo "Failed requests:     $FAIL_COUNT"
echo "Success rate:        $SUCCESS_RATE%"
echo "Wall time:           ${ELAPSED}s"
echo "Observed req/s:      $REQ_PER_SEC"
echo "Avg latency:         $AVG_LATENCY s"
echo "P50 latency:         $P50_LATENCY s"
echo "P95 latency:         $P95_LATENCY s"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    warn "Sample failures:"
    find "$TMP_DIR" -name '*.fail' | sort | head -n 5 | while read -r fail_file; do
        request_id="$(basename "$fail_file" .fail)"
        printf "  request %s: %s\n" "$request_id" "$(cat "$fail_file")"
    done
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
