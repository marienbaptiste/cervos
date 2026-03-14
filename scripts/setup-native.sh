#!/usr/bin/env bash
# Cervos — Native macOS inference stack setup
set -euo pipefail

echo "=== Native macOS Setup ==="

# Delegate to server-side native setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$(dirname "$SCRIPT_DIR")/server/native-setup.sh"
