#!/usr/bin/env bash
# Cervos — Native macOS setup for Apple Silicon inference stack
# Installs mlx-lm, lightning-whisper-mlx, and Ollama

set -euo pipefail

echo "=== Cervos Native macOS Setup ==="

# Check Apple Silicon
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Error: Apple Silicon (arm64) required"
    exit 1
fi

# Install Homebrew dependencies
echo "Installing Homebrew dependencies..."
brew install python@3.11 ffmpeg

# Install mlx-lm
echo "Installing mlx-lm..."
pip3 install mlx-lm

# Install lightning-whisper-mlx
echo "Installing lightning-whisper-mlx..."
pip3 install lightning-whisper-mlx

# Install Ollama (fallback)
echo "Installing Ollama..."
brew install ollama

# Pull default models
echo "Pulling default models..."
echo "  Qwen 2.5 32B Q4 (via mlx-lm)..."
# mlx-lm models are downloaded on first use

echo "  Whisper Large-v3..."
# lightning-whisper-mlx downloads on first use

echo "  Ollama fallback models..."
ollama pull llama3.1:8b-instruct-q4_K_M

echo "=== Native setup complete ==="
echo "Start mlx-lm:   mlx_lm.server --model mlx-community/Qwen2.5-32B-Instruct-4bit --port 8080"
echo "Start whisper:   lightning-whisper-mlx serve --port 8081"
echo "Start ollama:    ollama serve"
