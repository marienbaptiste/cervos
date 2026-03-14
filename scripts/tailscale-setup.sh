#!/usr/bin/env bash
# Cervos — Tailscale mesh setup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$(dirname "$SCRIPT_DIR")/config.yaml"

echo "=== Tailscale Setup ==="

# Check if Tailscale is installed
if ! command -v tailscale &> /dev/null; then
    echo "Installing Tailscale..."
    if [[ "$(uname)" == "Darwin" ]]; then
        brew install --cask tailscale
    else
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
fi

# Start Tailscale
echo "Starting Tailscale..."
sudo tailscale up

echo "Tailscale IP: $(tailscale ip -4)"
echo ""
echo "=== Tailscale setup complete ==="
echo "Ensure your phone is also connected to the same Tailnet."
