#!/usr/bin/env bash
# Cervos — Full setup script
# Runs native + Docker setup, joins Tailnet, generates certs, pulls models, runs self-test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Cervos Setup ==="
echo "Root: $ROOT_DIR"

# Step 1: Native macOS setup
echo ""
echo "--- Step 1: Native setup ---"
"$SCRIPT_DIR/setup-native.sh"

# Step 2: Docker services
echo ""
echo "--- Step 2: Docker services ---"
"$SCRIPT_DIR/setup-docker.sh"

# Step 3: Tailscale
echo ""
echo "--- Step 3: Tailscale ---"
"$SCRIPT_DIR/tailscale-setup.sh"

# Step 4: mTLS certificates
echo ""
echo "--- Step 4: Certificates ---"
"$SCRIPT_DIR/generate-certs.sh"

# Step 5: Self-test
echo ""
echo "--- Step 5: Self-test ---"
"$SCRIPT_DIR/test-e2e.sh"

echo ""
echo "=== Cervos setup complete ==="
