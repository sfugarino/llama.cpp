#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Smoke-test llama-server through the k3s NodePort.
# Usage:  ./scripts/test.sh [http://<node-ip>:30990]
# Qwen3 is a hybrid thinking model: /no_think in the system prompt and the
# per-request chat_template_kwargs flag both disable thinking for speed.
# ---------------------------------------------------------------------------
set -euo pipefail
URL=${1:-http://127.0.0.1:30990}

echo "== GET $URL/health =="
curl -sf --retry 10 --retry-delay 5 "$URL/health"
echo

echo "== GET $URL/props (loaded model / slots) =="
curl -sf "$URL/props" | python3 -m json.tool | head -40 || true

echo "== POST /v1/chat/completions (thinking disabled) =="
time curl -s --max-time 600 "$URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{
        "messages": [
            {"role": "system", "content": "/no_think"},
            {"role": "user", "content": "In one sentence: why does layer-splitting help run bigger models on small devices?"}
        ],
        "max_tokens": 128,
        "chat_template_kwargs": {"enable_thinking": false},
        "stream": false
    }' | python3 -m json.tool
