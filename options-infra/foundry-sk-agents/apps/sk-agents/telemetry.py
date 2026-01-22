"""
OpenTelemetry setup and configuration for Azure Monitor.
"""

import logging
from opentelemetry import trace
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from azure.monitor.opentelemetry import configure_azure_monitor

from config import settings

# Use named logger for this module
logger = logging.getLogger("sk_agents.telemetry")

# Application logger name prefix - all app logs should use this
APP_LOGGER_NAME = "sk_agents"


def configure_logging() -> None:
    """Configure logging with proper format and levels."""
    # Set up root logger
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # Suppress noisy loggers from Azure SDK and OpenTelemetry internals
    noisy_loggers = [
        "azure.core.pipeline.policies.http_logging_policy",
        "azure.identity",
        "azure.monitor.opentelemetry",
        "azure.monitor.opentelemetry.exporter",
        "opentelemetry.sdk",
        "opentelemetry.instrumentation",
        "opentelemetry.exporter",
        "httpx",
        "httpcore",
        "urllib3",
        "msal",
    ]

    for logger_name in noisy_loggers:
        logging.getLogger(logger_name).setLevel(logging.WARNING)

    # Ensure our app loggers are at INFO level
    logging.getLogger(APP_LOGGER_NAME).setLevel(logging.INFO)


def setup_telemetry() -> None:
    """Configure OpenTelemetry with Azure Monitor exporter."""
    # Configure logging first
    configure_logging()

    if not settings.APPLICATIONINSIGHTS_CONNECTION_STRING:
        logger.warning(
            "APPLICATIONINSIGHTS_CONNECTION_STRING not set, telemetry disabled"
        )
        return

    configure_azure_monitor(
        connection_string=settings.APPLICATIONINSIGHTS_CONNECTION_STRING,
        service_name=settings.SERVICE_NAME,
        # Disable logging of Azure SDK internal operations
        enable_live_metrics=False,
        logger_name=APP_LOGGER_NAME,  # Only export logs from our app logger
    )

    # Instrument httpx for outgoing HTTP calls
    HTTPXClientInstrumentor().instrument()

    logger.info("OpenTelemetry configured with Azure Monitor")


def get_tracer(name: str) -> trace.Tracer:
    """Get a tracer instance for the given module name."""
    # Prefix with app name for consistent naming
    if not name.startswith(APP_LOGGER_NAME):
        name = f"{APP_LOGGER_NAME}.{name}"
    return trace.get_tracer(name)


def get_logger(name: str) -> logging.Logger:
    """Get a named logger for the given module."""
    # Prefix with app name for consistent naming
    if not name.startswith(APP_LOGGER_NAME):
        name = f"{APP_LOGGER_NAME}.{name}"
    return logging.getLogger(name)
