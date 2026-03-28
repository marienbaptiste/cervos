# Cervos Debug — whisper.cpp server (CUDA build)
# Builds whisper.cpp from source with CUDA GPU acceleration.

FROM nvidia/cuda:12.6.3-devel-ubuntu22.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Clone whisper.cpp and build with CUDA + static linking
RUN git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git /whisper.cpp
WORKDIR /whisper.cpp

RUN cmake -B build \
    -DWHISPER_BUILD_SERVER=ON \
    -DGGML_CUDA=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --config Release -j$(nproc) --target whisper-server

# Download model
ARG MODEL=large-v3
RUN bash models/download-ggml-model.sh ${MODEL}

# --- Runtime stage ---
FROM nvidia/cuda:12.6.3-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /whisper.cpp/build/bin/whisper-server /usr/local/bin/whisper-server
COPY --from=builder /whisper.cpp/models/ggml-*.bin /models/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
