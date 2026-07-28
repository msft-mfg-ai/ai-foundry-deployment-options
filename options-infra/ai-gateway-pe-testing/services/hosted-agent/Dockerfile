# Minimal container for the BYOM hosted-agent probe.
# Built + pushed to ACR by the azd postprovision hook, then referenced by
# BYOM tests via project.beta.agents.create_version_from_image(HOSTED_AGENT_IMAGE).
FROM mcr.microsoft.com/devcontainers/python:3.13

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py ./

ENV PORT=8080
EXPOSE 8080

CMD ["python", "main.py"]
