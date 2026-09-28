# Copilot-SDK-over-APIM canary. Built + pushed to ACR by `azd deploy` via the
# azure.ai.agents extension. Reaches APIM's private endpoint from inside the
# Foundry VNet, so it can validate the `copilot-sdk-via-apim-direct` topology
# that public GH-hosted runners cannot (APIM publicNetworkAccess=Disabled).
FROM mcr.microsoft.com/devcontainers/python:3.13

# LibreOffice (headless) so the agent can convert generated .pptx to pdf/png
# via `soffice --headless --convert-to pdf deck.pptx`. fonts-liberation gives
# Arial/Times/Courier substitutes so python-pptx defaults render correctly.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libreoffice-impress libreoffice-core \
        fonts-liberation fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# uv replaces pip: single-command lockless install straight from pyproject.toml,
# ~10x faster on rebuilds and no requirements.txt drift.
COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv

WORKDIR /app
COPY pyproject.toml ./
RUN uv pip install --system --no-cache .
COPY assets/ ./assets/
COPY main.py ./

ENV PORT=8080
EXPOSE 8080
CMD ["python", "main.py"]
