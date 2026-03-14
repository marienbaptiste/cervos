#!/usr/bin/env bash
# Cervos — Docker services setup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(dirname "$SCRIPT_DIR")/server"

echo "=== Docker Services Setup ==="

# Create data directories
mkdir -p "$(dirname "$SCRIPT_DIR")/data/chroma"
touch "$(dirname "$SCRIPT_DIR")/data/audit.jsonl"

# Create cloud kill switch (enabled by default)
sudo touch /var/run/cloud-enabled

# Start Docker services
echo "Starting Docker services..."
cd "$SERVER_DIR"
docker compose up -d

echo "Waiting for services to be healthy..."
sleep 5

# Health checks
echo "Checking nginx..."
curl -sk https://localhost:443/v1/health || echo "  nginx: waiting..."

echo "Checking SearXNG..."
curl -s http://localhost:8888/healthz || echo "  searxng: waiting..."

echo "Checking Chroma..."
curl -s http://localhost:8500/api/v1/heartbeat || echo "  chroma: waiting..."

echo "=== Docker setup complete ==="
