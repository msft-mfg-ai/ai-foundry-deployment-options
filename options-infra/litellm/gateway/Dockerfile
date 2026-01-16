# https://docs.litellm.ai/docs/proxy/deploy#deploy-with-database
# docker run \
#     -v $(pwd)/litellm_config.yaml:/app/config.yaml \
#     -e LITELLM_MASTER_KEY=sk-1234 \
#     -e DATABASE_URL=postgresql://<user>:<password>@<host>:<port>/<dbname> \
#     -e AZURE_API_KEY=d6*********** \
#     -e AZURE_API_BASE=https://openai-***********/ \
#     -p 4000:4000 \
#     ghcr.io/berriai/litellm-database:main-stable \
#     --config /app/config.yaml --detailed_debug

# Use the provided base image
FROM ghcr.io/berriai/litellm:main-stable

# Set the working directory to /app
WORKDIR /app

# Copy the configuration file into the container at /app
COPY config.yaml .

# Make sure your docker/entrypoint.sh is executable
RUN chmod +x ./docker/entrypoint.sh

# Expose the necessary port
EXPOSE 4000/tcp

# Override the CMD instruction with your desired command and arguments
# WARNING: FOR PROD DO NOT USE `--detailed_debug` it slows down response times, instead use the following CMD
# CMD ["--port", "4000", "--config", "config.yaml"]

CMD ["--port", "4000", "--config", "/app/config.yaml", "--detailed_debug"]