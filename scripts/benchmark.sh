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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
  }]
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

    if [ "$http_code" = "200" ] && request_ok "$body_file"; then
        echo "$latency" > "$TMP_DIR/$request_id.ok"
    else
        echo "$http_code $latency $size_download" > "$TMP_DIR/$request_id.fail"
    fi
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

BENCHMARK_START="$(date +%s)"

for request_id in $(seq 1 "$TOTAL_REQUESTS"); do
    while [ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$CONCURRENCY" ]; do
        sleep 0.1
    done

    run_one "$request_id" &
done

wait

BENCHMARK_END="$(date +%s)"
ELAPSED=$((BENCHMARK_END - BENCHMARK_START))
[ "$ELAPSED" -eq 0 ] && ELAPSED=1

SUCCESS_COUNT=$(find "$TMP_DIR" -name '*.ok' | wc -l | tr -d ' ')
FAIL_COUNT=$(find "$TMP_DIR" -name '*.fail' | wc -l | tr -d ' ')

find "$TMP_DIR" -name '*.ok' -exec cat {} \; | sort -n > "$TMP_DIR/latencies.txt"

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
