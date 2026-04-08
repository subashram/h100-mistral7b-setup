#!/usr/bin/env bash
# =============================================================================
# Capability Test — verifies supported and intentionally unsupported features
# =============================================================================
set -euo pipefail

TARGET_STACK="${TARGET_STACK:-mistral}"   # mistral | small32 | mistral-alias
API_KEY="${API_KEY:-sk-prod-key-1}"

if [ "${ENDPOINT:-}" != "" ]; then
    ENDPOINT="$ENDPOINT"
elif [ "$TARGET_STACK" = "small32" ]; then
    ENDPOINT="https://127.0.0.1:8443/mistral/small32/v1"
elif [ "$TARGET_STACK" = "mistral-alias" ]; then
    ENDPOINT="https://127.0.0.1:8443/mistral/7b/v1"
else
    ENDPOINT="https://127.0.0.1:8443/v1"
fi

if [ "${MODEL:-}" != "" ]; then
    MODEL="$MODEL"
elif [ "$TARGET_STACK" = "small32" ]; then
    MODEL="mistralai/Mistral-Small-3.2-24B-Instruct-2506"
else
    MODEL="mistralai/Mistral-7B-Instruct-v0.3"
fi

REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-180}"
INSECURE_TLS="${INSECURE_TLS:-1}"

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

get_request() {
    local path="$1"
    local body_file="$2"
    local meta_file="$3"

    if curl_common \
        -o "$body_file" \
        -w "%{http_code}" \
        -H "Authorization: Bearer $API_KEY" \
        "$ENDPOINT/$path" \
        > "$meta_file" 2>"$TMP_DIR/curl.stderr"; then
        :
    else
        echo "000" > "$meta_file"
    fi
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

expect_supported_models() {
    local body="$TMP_DIR/models.body"
    local meta="$TMP_DIR/models.meta"
    get_request "models" "$body" "$meta"
    if [ "$(cat "$meta")" != "200" ]; then
        check "Models endpoint" "HTTP $(cat "$meta")"
        return
    fi
    if grep -q '"data"' "$body"; then
        check "Models endpoint" "ok"
    else
        check "Models endpoint" "missing model data"
    fi
}

expect_supported_chat() {
    local payload="$TMP_DIR/chat.json"
    local body="$TMP_DIR/chat.body"
    local meta="$TMP_DIR/chat.meta"

    cat > "$payload" <<EOF
{
  "model": "$MODEL",
  "messages": [
    {"role":"system","content":"Be concise."},
    {"role":"user","content":"Reply with exactly: capability check"}
  ],
  "temperature": 0,
  "max_tokens": 16
}
EOF

    post_json "chat/completions" "$payload" "$body" "$meta"
    if [ "$(cat "$meta")" != "200" ]; then
        check "Chat completions" "HTTP $(cat "$meta")"
        return
    fi
    if grep -q '"choices"' "$body"; then
        check "Chat completions" "ok"
    else
        check "Chat completions" "missing choices"
    fi
}

expect_supported_stream() {
    local payload="$TMP_DIR/stream.json"
    local body="$TMP_DIR/stream.body"
    local meta="$TMP_DIR/stream.meta"

    cat > "$payload" <<EOF
{
  "model": "$MODEL",
  "messages": [
    {"role":"user","content":"Count to three."}
  ],
  "temperature": 0,
  "max_tokens": 24,
  "stream": true
}
EOF

    post_json "chat/completions" "$payload" "$body" "$meta"
    if [ "$(cat "$meta")" != "200" ]; then
        check "Streaming chat" "HTTP $(cat "$meta")"
        return
    fi
    if grep -q 'data:' "$body"; then
        check "Streaming chat" "ok"
    else
        check "Streaming chat" "missing SSE frames"
    fi
}

expect_supported_tools() {
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
    if [ "$(cat "$meta")" != "200" ]; then
        check "Tool calling" "HTTP $(cat "$meta")"
        return
    fi
    if grep -Eq '"tool_calls"|"function_call"' "$body"; then
        check "Tool calling" "ok"
    else
        check "Tool calling" "missing tool call data"
    fi
}

expect_unsupported_endpoint() {
    local name="$1"
    local path="$2"
    local payload="$3"
    local body="$TMP_DIR/${name// /_}.body"
    local meta="$TMP_DIR/${name// /_}.meta"
    local payload_file="$TMP_DIR/${name// /_}.json"

    printf '%s\n' "$payload" > "$payload_file"
    post_json "$path" "$payload_file" "$body" "$meta"

    if [ "$(cat "$meta")" = "200" ]; then
        check "$name" "unexpectedly returned HTTP 200"
    else
        check "$name" "ok"
    fi
}

expect_unsupported_document_qna() {
    local payload="$TMP_DIR/document_qna.json"
    local body="$TMP_DIR/document_qna.body"
    local meta="$TMP_DIR/document_qna.meta"

    cat > "$payload" <<EOF
{
  "model": "$MODEL",
  "messages": [{
    "role": "user",
    "content": [
      {
        "type": "text",
        "text": "What is the last sentence in the document?"
      },
      {
        "type": "document_url",
        "document_url": "https://arxiv.org/pdf/1805.04770"
      }
    ]
  }]
}
EOF

    post_json "chat/completions" "$payload" "$body" "$meta"
    if [ "$(cat "$meta")" = "200" ]; then
        check "Document QnA workflow" "unexpectedly returned HTTP 200"
    else
        check "Document QnA workflow" "ok"
    fi
}

echo "Capability Testing: $ENDPOINT"
echo "Model:              $MODEL"
echo "Lane:               $TARGET_STACK"
echo "=============================="

echo "Supported features"
expect_supported_models
expect_supported_chat
expect_supported_stream
expect_supported_tools

echo ""
echo "Intentionally unsupported in this deployment"
expect_unsupported_endpoint "Embeddings endpoint" "embeddings" "{\"model\":\"$MODEL\",\"input\":\"test\"}"
expect_unsupported_endpoint "OCR endpoint" "ocr" "{\"model\":\"$MODEL\",\"document\":{\"type\":\"document_url\",\"document_url\":\"https://arxiv.org/pdf/1805.04770\"}}"
expect_unsupported_endpoint "Agents endpoint" "agents" "{\"name\":\"demo-agent\"}"
expect_unsupported_endpoint "Conversations endpoint" "conversations" "{\"name\":\"demo-conversation\"}"
expect_unsupported_document_qna

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo -e "${GREEN}ALL TESTS PASSED${NC}" || echo -e "${RED}SOME TESTS FAILED${NC}"
exit "$FAIL"
