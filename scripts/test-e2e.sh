#!/usr/bin/env bash
# Cervos — End-to-end smoke test
set -euo pipefail

echo "=== Cervos E2E Smoke Test ==="

PASS=0
FAIL=0

check() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" > /dev/null 2>&1; then
        echo "  [PASS] $name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $name"
        FAIL=$((FAIL + 1))
    fi
}

echo "Services:"
check "mlx-lm (port 8080)" "curl -sf http://localhost:8080/v1/models"
check "whisper (port 8081)" "curl -sf http://localhost:8081/health"
check "Ollama (port 11434)" "curl -sf http://localhost:11434/api/tags"
check "nginx (port 443)" "curl -sfk https://localhost:443/v1/health"
check "OpenClaw (port 8000)" "curl -sf http://localhost:8000/health"
check "SearXNG (port 8888)" "curl -sf http://localhost:8888/healthz"
check "Chroma (port 8500)" "curl -sf http://localhost:8500/api/v1/heartbeat"
check "Console (port 9090)" "curl -sf http://localhost:9090/"

echo ""
echo "Tailscale:"
check "Tailscale connected" "tailscale status"

echo ""
echo "--- Results: $PASS passed, $FAIL failed ---"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
