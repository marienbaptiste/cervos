# Cervos Debug — Backend (FastAPI + liblc3)
# Handles audio processing, LC3 BLE simulation, and whisper.cpp proxy.

FROM python:3.12-slim

# Build deps for liblc3 Python bindings (meson build system)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential meson ninja-build git pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install liblc3 Python bindings from source
RUN git clone --depth 1 https://github.com/google/liblc3.git /tmp/liblc3 \
    && cd /tmp/liblc3 \
    && pip install --no-cache-dir . \
    && rm -rf /tmp/liblc3

WORKDIR /app

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy backend source
COPY backend/*.py ./

# Copy frontend static files
COPY frontend/ ./static/

EXPOSE 8090

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8090"]
