# Cervos Voice Service — App layer (source code only, rebuilds in seconds)
# Requires base image: docker build -f backend/Dockerfile.base -t cervos-voice-base .

FROM cervos-voice-base

ENV TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1

WORKDIR /app

# Copy backend source
COPY backend/*.py ./

# Copy frontend static files
COPY frontend/ ./static/

EXPOSE 8090

CMD ["python3", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8090"]
