# Multi-stage build for optimized Alpine Python
FROM python:3.11-alpine AS builder

WORKDIR /app

# Install build dependencies (consolidated into single layer, cleaned in same step)
RUN apk add --no-cache gcc musl-dev libffi-dev

# Copy dependency files
COPY pyproject.toml uv.lock ./

# Install dependencies via uv, then remove uv itself — it's not needed at runtime
RUN pip install --no-cache-dir uv \
    && uv sync --frozen --no-dev \
    && pip uninstall -y uv \
    # Strip bytecode caches and test artefacts from the venv to shrink it
    && find /app/.venv -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true \
    && find /app/.venv -name '*.pyc' -delete \
    && find /app/.venv -name '*.pyo' -delete \
    && find /app/.venv -type d -name 'tests' -exec rm -rf {} + 2>/dev/null || true

# Production stage
FROM python:3.11-alpine

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    FLASK_APP=app \
    FLASK_ENV=production \
    # Tell Python not to allocate a large initial heap
    MALLOC_TRIM_THRESHOLD_=65536

# curl is only needed for the health check
RUN apk add --no-cache curl

# Copy only the stripped venv from builder — no compiler toolchain in the final image
COPY --from=builder /app/.venv /app/.venv

# Copy application code only (tests / docs excluded via .dockerignore)
COPY app/ ./app/
COPY wsgi.py ./

# Create logs directory
RUN mkdir -p logs

# Non-root user
RUN adduser -D -s /bin/sh app \
    && chown -R app:app /app
USER app

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:5000/api/client-ip || exit 1

# Use 1 worker + threads instead of 4 workers.
# This app is I/O-bound (HTTP calls to Pangolin), so threads are a better fit:
#   - 4 sync workers  ≈ 4 × ~80 MB = ~320 MB
#   - 1 gthread worker with 4 threads ≈ ~80 MB shared
# Raise --workers to 2 only if you need more CPU parallelism.
CMD ["/app/.venv/bin/gunicorn", \
     "--bind", "0.0.0.0:5000", \
     "--worker-class", "gthread", \
     "--workers", "1", \
     "--threads", "4", \
     "--timeout", "60", \
     "--keep-alive", "5", \
     "wsgi:app"]
