FROM ghcr.io/astral-sh/uv:0.9.7 AS uv
FROM python:3.13-slim

WORKDIR /app

COPY --from=uv /uv /uvx /bin/
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY app ./app
RUN uv sync --frozen --no-dev

ENV PATH="/app/.venv/bin:$PATH" \
    PORT=8000 \
    PYTHONUNBUFFERED=1

EXPOSE 8000

CMD ["a2a-agent"]

