# Copilot-SDK-over-APIM canary. Built + pushed to ACR by `azd deploy` via the
# azure.ai.agents extension. Reaches APIM's private endpoint from inside the
# Foundry VNet, so it can validate the `copilot-sdk-via-apim-direct` topology
# that public GH-hosted runners cannot (APIM publicNetworkAccess=Disabled).
FROM mcr.microsoft.com/devcontainers/python:3.13

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py ./

ENV PORT=8080
EXPOSE 8080
CMD ["python", "main.py"]
