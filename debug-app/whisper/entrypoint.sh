#!/bin/sh
# Cervos Debug — whisper.cpp server entrypoint
# Finds the first available model and starts the server.

MODEL_FILE=$(ls /models/ggml-*.bin 2>/dev/null | head -1)

if [ -z "$MODEL_FILE" ]; then
    echo "ERROR: No model found in /models/"
    exit 1
fi

echo "Starting whisper.cpp server with model: $MODEL_FILE"

exec whisper-server \
    --model "$MODEL_FILE" \
    --host 0.0.0.0 \
    --port 8080 \
    "$@"
