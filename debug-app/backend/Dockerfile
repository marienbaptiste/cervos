# Cervos Debug — Backend (faster-whisper + CUDA + LC3)
# Single container: FastAPI + WebSocket streaming STT + LC3 BLE simulation

FROM nvidia/cuda:12.6.3-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-dev \
    build-essential git pkg-config \
    libcublas-12-6 libcudnn9-cuda-12 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY backend/requirements.txt .
RUN pip install --no-cache-dir  -r requirements.txt

# Copy backend source
COPY backend/*.py ./

# Copy frontend static files
COPY frontend/ ./static/

EXPOSE 8090

CMD ["python3", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8090"]
