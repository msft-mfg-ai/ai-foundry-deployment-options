FROM mcr.microsoft.com/devcontainers/python:3.13

WORKDIR /app

# Install uv for fast, reproducible dependency resolution.
RUN pip install --no-cache-dir uv

COPY pyproject.toml ./
COPY app ./app

# Sync deps into /app/.venv; --frozen would require a checked-in uv.lock.
RUN uv sync --no-dev

ENV PORT=8000
EXPOSE 8000

CMD ["/app/.venv/bin/python", "-m", "app.main"]
