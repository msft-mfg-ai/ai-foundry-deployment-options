import logging


def setup_app_logging():
    # Clear any existing handlers
    for handler in logging.root.handlers[:]:
        logging.root.removeHandler(handler)

    # Set up logging with a format that shows request IDs
    log_format = "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    logging.basicConfig(level=logging.WARNING, format=log_format, force=True)

    # Create a handler for our loggers
    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.DEBUG)
    console_handler.setFormatter(logging.Formatter(log_format))

    # Azure SDK HTTP logging - this captures request/response headers including x-request-id
    azure_http_logger = logging.getLogger(
        "azure.core.pipeline.policies.http_logging_policy"
    )
    azure_http_logger.addHandler(console_handler)
    azure_http_logger.setLevel(logging.DEBUG)

    # OpenAI HTTP logging
    openai_logger = logging.getLogger("openai")
    openai_logger.addHandler(console_handler)
    openai_logger.setLevel(logging.DEBUG)

    # httpx logging (used by openai client)
    httpx_logger = logging.getLogger("httpx")
    httpx_logger.addHandler(console_handler)
    httpx_logger.setLevel(logging.DEBUG)

    # AI Projects logging
    ai_logger = logging.getLogger("azure.ai.projects")
    ai_logger.addHandler(console_handler)
    ai_logger.setLevel(logging.DEBUG)
