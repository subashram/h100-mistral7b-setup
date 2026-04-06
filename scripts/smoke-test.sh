#!/usr/bin/env bash
# =============================================================================
# Smoke Test — validates the full stack is working
# =============================================================================
set -euo pipefail

ENDPOINT="${ENDPOINT:-https://localhost/v1}"
API_KEY="${API_KEY:-sk-prod-key-1}"
PASS=0; FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

check() {
    local name="$1"; local result="$2"
    if [ "$result" = "ok" ]; then
        echo -e "  ${GREEN}✓${NC} $name"
        PASS=$((PASS+1))
    else
        echo -e "  ${RED}✗${NC} $name — $result"
        FAIL=$((FAIL+1))
    fi
}

echo "Smoke Testing: $ENDPOINT"
echo "========================"

# --- 1. Health endpoint ---
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$ENDPOINT/../health" 2>/dev/null || echo "000")
[ "$HTTP_CODE" = "200" ] && check "Health endpoint" "ok" || check "Health endpoint" "HTTP $HTTP_CODE"

# --- 2. Models list ---
MODELS=$(curl -sk -H "Authorization: Bearer $API_KEY" "$ENDPOINT/models" 2>/dev/null)
echo "$MODELS" | grep -q "Mistral" && check "Models endpoint" "ok" || check "Models endpoint" "no Mistral model found"

# --- 3. Basic chat completion ---
RESPONSE=$(curl -sk -X POST "$ENDPOINT/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "mistralai/Mistral-7B-Instruct-v0.3",
        "messages": [{"role":"user","content":"Say hello in exactly 3 words."}],
        "max_tokens": 20
    }' 2>/dev/null)
echo "$RESPONSE" | grep -q '"choices"' && check "Chat completion" "ok" || check "Chat completion" "bad response"

# --- 4. Streaming ---
STREAM=$(curl -sk -X POST "$ENDPOINT/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "mistralai/Mistral-7B-Instruct-v0.3",
        "messages": [{"role":"user","content":"Count to 3."}],
        "max_tokens": 20,
        "stream": true
    }' 2>/dev/null)
echo "$STREAM" | grep -q "data:" && check "Streaming" "ok" || check "Streaming" "no SSE events"

# --- 5. Function calling ---
TOOL_RESPONSE=$(curl -sk -X POST "$ENDPOINT/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "mistralai/Mistral-7B-Instruct-v0.3",
        "messages": [{"role":"user","content":"What is the weather in Dallas?"}],
        "max_tokens": 100,
        "tools": [{
            "type": "function",
            "function": {
                "name": "get_weather",
                "description": "Get weather for a location",
                "parameters": {
                    "type": "object",
                    "properties": {"location": {"type": "string"}},
                    "required": ["location"]
                }
            }
        }]
    }' 2>/dev/null)
echo "$TOOL_RESPONSE" | grep -q "tool_calls\|function_call" && \
    check "Function calling" "ok" || check "Function calling" "no tool_calls in response"

# --- 6. Auth rejection (no key) ---
AUTH_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "$ENDPOINT/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"mistralai/Mistral-7B-Instruct-v0.3","messages":[{"role":"user","content":"test"}]}' \
    2>/dev/null || echo "000")
[ "$AUTH_CODE" = "401" ] && check "Auth rejection (no key)" "ok" || check "Auth rejection" "expected 401, got $AUTH_CODE"

# --- 7. Auth rejection (bad key) ---
BAD_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST "$ENDPOINT/chat/completions" \
    -H "Authorization: Bearer sk-invalid-key" \
    -H "Content-Type: application/json" \
    -d '{"model":"mistralai/Mistral-7B-Instruct-v0.3","messages":[{"role":"user","content":"test"}]}' \
    2>/dev/null || echo "000")
[ "$BAD_CODE" = "401" ] && check "Auth rejection (bad key)" "ok" || check "Auth rejection (bad key)" "expected 401, got $BAD_CODE"

# --- 8. Concurrent load test (10 parallel requests) ---
echo ""
echo "Concurrent load test (10 parallel requests)..."
PIDS=()
TIMES=()
for i in $(seq 1 10); do
    (
        START=$(date +%s%N)
        curl -sk -X POST "$ENDPOINT/chat/completions" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"mistralai/Mistral-7B-Instruct-v0.3\",
                \"messages\": [{\"role\":\"user\",\"content\":\"Say $i.\"}],
                \"max_tokens\": 10
            }" -o /dev/null -w "%{http_code} %{time_total}" 2>/dev/null
    ) &
    PIDS+=($!)
done

ALL_OK=true
for pid in "${PIDS[@]}"; do
    wait "$pid" || ALL_OK=false
done
$ALL_OK && check "10 concurrent requests" "ok" || check "10 concurrent requests" "some failed"

# --- Summary ---
echo ""
echo "========================"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo -e "${GREEN}ALL TESTS PASSED${NC}" || echo -e "${RED}SOME TESTS FAILED${NC}"
exit $FAIL
