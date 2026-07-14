# Foundry hosted-agent — matches the shape used by
# microsoft-foundry/foundry-samples BYO Responses agents.
FROM python:3.13-slim

# ── System deps for the diagnostic bash tool (curl, dnsutils for nslookup /
# ── dig, openssl, jq) and for the Copilot CLI's own dependencies (ca-certs,
# ── git).
RUN apt-get update && apt-get install --no-install-recommends -y \
    ca-certificates \
    curl \
    dnsutils \
    openssl \
    jq \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt user_agent/requirements.txt
RUN pip install --no-cache-dir -r user_agent/requirements.txt

# Pre-download the Copilot CLI runtime into an image-baked cache so the
# container doesn't call out to github.com on cold-start (essential when the
# agent is deployed into a PE-locked Foundry project).
ENV COPILOT_CLI_EXTRACT_DIR=/opt/copilot-runtime
ENV COPILOT_CLI_PATH=/opt/copilot-runtime/copilot
ENV COPILOT_SKIP_CLI_DOWNLOAD=1
RUN mkdir -p /opt/copilot-runtime && python -m copilot download-runtime && \
    test -x /opt/copilot-runtime/copilot

COPY . user_agent/
WORKDIR /app/user_agent

EXPOSE 8088
CMD ["python", "main.py"]
