#!/usr/bin/env bash
# =============================================================================
# API Test — targeted validation for chat, streaming, and tool calling
# =============================================================================
set -euo pipefail

ENDPOINT="${ENDPOINT:-http://127.0.0.1:8081/v1}"
API_KEY="${API_KEY:-sk-prod-key-1}"
MODEL="${MODEL:-mistralai/Mistral-7B-Instruct-v0.3}"
TEST_MODE="${TEST_MODE:-full}"    # chat | stream | tools | full
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-180}"
INSECURE_TLS="${INSECURE_TLS:-0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

check() {
    local name="$1"
    local result="$2"
    if [ "$result" = "ok" ]; then
        echo -e "  ${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${NC} $name — $result"
        FAIL=$((FAIL + 1))
    fi
}

curl_common() {
    local args=(-sS --max-time "$REQUEST_TIMEOUT")
    if [ "$INSECURE_TLS" = "1" ]; then
        args+=(-k)
    fi
    curl "${args[@]}" "$@"
}

post_json() {
    local path="$1"
    local payload_file="$2"
    local body_file="$3"
    local meta_file="$4"

    if curl_common \
        -o "$body_file" \
        -w "%{http_code}" \
        -X POST "$ENDPOINT/$path" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --data @"$payload_file" \
        > "$meta_file" 2>"$TMP_DIR/curl.stderr"; then
        :
    else
        echo "000" > "$meta_file"
    fi
}

run_chat_test() {
    local payload="$TMP_DIR/chat.json"
    local body="$TMP_DIR/chat.body"
    local meta="$TMP_DIR/chat.meta"

    cat > "$payload" <<EOF
{
  "model": "$MODEL",
  "messages": [
    {"role":"system","content":"Be concise."},
    {"role":"user","content":"Reply with exactly: hello from mistral"}
  ],
  "temperature": 0,
  "max_tokens": 16
}
EOF

    post_json "chat/completions" "$payload" "$body" "$meta"
    local http_code
    http_code="$(cat "$meta")"

    if [ "$http_code" != "200" ]; then
        check "Chat completion" "HTTP $http_code"
        return
    fi

    if grep -q '"choices"' "$body"; then
        check "Chat completion" "ok"
        echo ""
        echo "Chat response:"
        sed -n '1,20p' "$body"
    else
        check "Chat completion" "missing choices in response"
    fi
}

run_stream_test() {
    local payload="$TMP_DIR/stream.json"
    local body="$TMP_DIR/stream.body"
    local meta="$TMP_DIR/stream.meta"

    cat > "$payload" <<EOF
{
  "model": "$MODEL",
  "messages": [
    {"role":"system","content":"Be concise."},
    {"role":"user","content":"Count to three."}
  ],
  "temperature": 0,
  "max_tokens": 24,
  "stream": true
}
EOF

    post_json "chat/completions" "$payload" "$body" "$meta"
    local http_code
    http_code="$(cat "$meta")"

    if [ "$http_code" != "200" ]; then
        check "Streaming chat" "HTTP $http_code"
        return
    fi

    if grep -q 'data:' "$body"; then
        check "Streaming chat" "ok"
    else
        check "Streaming chat" "missing SSE data frames"
    fi
}

run_tool_test() {
    local payload="$TMP_DIR/tools.json"
    local body="$TMP_DIR/tools.body"
    local meta="$TMP_DIR/tools.meta"

    cat > "$payload" <<EOF
{
  "model": "$MODEL",
  "messages": [
    {"role":"user","content":"What is the weather in Dallas? Use the provided tool."}
  ],
  "temperature": 0,
  "max_tokens": 128,
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

    post_json "chat/completions" "$payload" "$body" "$meta"
    local http_code
    http_code="$(cat "$meta")"

    if [ "$http_code" != "200" ]; then
        check "Tool calling" "HTTP $http_code"
        return
    fi

    if grep -Eq '"tool_calls"|"function_call"' "$body"; then
        check "Tool calling" "ok"
        echo ""
        echo "Tool response:"
        sed -n '1,40p' "$body"
    else
        check "Tool calling" "missing tool_calls in response"
    fi
}

echo "API Testing: $ENDPOINT"
echo "Model:       $MODEL"
echo "Mode:        $TEST_MODE"
echo "========================"

case "$TEST_MODE" in
    chat)
        run_chat_test
        ;;
    stream)
        run_stream_test
        ;;
    tools)
        run_tool_test
        ;;
    full)
        run_chat_test
        echo ""
        run_stream_test
        echo ""
        run_tool_test
        ;;
    *)
        echo -e "${RED}Unsupported TEST_MODE '$TEST_MODE'${NC}"
        exit 1
        ;;
esac

echo ""
echo "========================"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo -e "${GREEN}ALL TESTS PASSED${NC}" || echo -e "${RED}SOME TESTS FAILED${NC}"
exit "$FAIL"
