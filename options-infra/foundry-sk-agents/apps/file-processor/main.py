"""
FastAPI File Processor Service
Processes files with a simulated 3-minute delay and returns hardcoded responses.
Instrumented with OpenTelemetry for App Insights.
"""

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from typing import List

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from azure.monitor.opentelemetry import configure_azure_monitor
from pydantic import BaseModel

# Application logger name prefix
APP_LOGGER_NAME = "file_processor"


# Configure logging with proper named loggers
def configure_logging():
    """Configure logging with proper format and filter noisy loggers."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # Suppress noisy loggers
    noisy_loggers = [
        "azure.core.pipeline.policies.http_logging_policy",
        "azure.identity",
        "azure.monitor.opentelemetry",
        "azure.monitor.opentelemetry.exporter",
        "opentelemetry.sdk",
        "opentelemetry.instrumentation",
        "opentelemetry.exporter",
        "httpcore",
        "urllib3",
    ]
    for logger_name in noisy_loggers:
        logging.getLogger(logger_name).setLevel(logging.WARNING)

    # Ensure our app logger is at INFO level
    logging.getLogger(APP_LOGGER_NAME).setLevel(logging.INFO)


# Use named logger
logger = logging.getLogger(f"{APP_LOGGER_NAME}.main")

# Configuration
PROCESSING_DELAY_SECONDS = int(
    os.environ.get("PROCESSING_DELAY_SECONDS", "180")
)  # 3 minutes default
APP_INSIGHTS_CONNECTION_STRING = os.environ.get(
    "APPLICATIONINSIGHTS_CONNECTION_STRING", ""
)


# Setup OpenTelemetry
def setup_telemetry():
    """Configure OpenTelemetry with Azure Monitor."""
    configure_logging()

    if not APP_INSIGHTS_CONNECTION_STRING:
        logger.warning(
            "APPLICATIONINSIGHTS_CONNECTION_STRING not set, telemetry disabled"
        )
        return

    configure_azure_monitor(
        connection_string=APP_INSIGHTS_CONNECTION_STRING,
        service_name="file-processor-service",
        logger_name=APP_LOGGER_NAME,  # Only export logs from our app logger
    )
    logger.info("OpenTelemetry configured with Azure Monitor")


# Models
class FileProcessRequest(BaseModel):
    """Request model for file processing."""

    files: List[str]


class FileProcessResponse(BaseModel):
    """Response model for file processing."""

    status: str
    summary: str
    processed_files: List[str]
    processing_time_seconds: int


class HealthResponse(BaseModel):
    """Health check response."""

    status: str
    service: str


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    # Startup
    setup_telemetry()
    logger.info(
        f"File Processor Service starting. Delay configured: {PROCESSING_DELAY_SECONDS}s"
    )
    yield
    # Shutdown
    logger.info("File Processor Service shutting down")


# Create FastAPI app
app = FastAPI(
    title="File Processor Service",
    description="Processes files with simulated delay and returns summaries",
    version="1.0.0",
    lifespan=lifespan,
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Instrument FastAPI with OpenTelemetry
FastAPIInstrumentor.instrument_app(app)

tracer = trace.get_tracer(f"{APP_LOGGER_NAME}.main")


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint."""
    return HealthResponse(status="healthy", service="file-processor")


@app.post("/process-files", response_model=FileProcessResponse)
async def process_files(request: FileProcessRequest):
    """
    Process a list of files with a 3-minute delay.
    Returns a hardcoded summary response.
    """
    with tracer.start_as_current_span("process_files") as span:
        span.set_attribute("files.count", len(request.files))
        span.set_attribute("files.names", ", ".join(request.files))

        if not request.files:
            raise HTTPException(status_code=400, detail="No files provided")

        logger.info(f"Processing {len(request.files)} files: {request.files}")
        logger.info(f"Starting {PROCESSING_DELAY_SECONDS}s processing delay...")

        # Simulate long processing time (3 minutes)
        with tracer.start_as_current_span("file_processing_delay"):
            await asyncio.sleep(PROCESSING_DELAY_SECONDS)

        # Generate hardcoded response
        summary = generate_hardcoded_summary(request.files)

        response = FileProcessResponse(
            status="completed",
            summary=summary,
            processed_files=request.files,
            processing_time_seconds=PROCESSING_DELAY_SECONDS,
        )

        logger.info(f"Processing complete for {len(request.files)} files")
        span.set_attribute("processing.status", "completed")

        return response


def generate_hardcoded_summary(files: List[str]) -> str:
    """Generate a hardcoded summary for the processed files."""
    file_list = "\n".join([f"  - {f}" for f in files])

    return f"""# File Processing Summary

## Processed Files ({len(files)} total):
{file_list}

## Analysis Results:
The following insights were extracted from the provided files:

### Key Findings:
1. **Document Structure**: All files have been successfully parsed and validated.
2. **Content Analysis**: The documents contain a mix of technical specifications, 
   business requirements, and implementation details.
3. **Data Quality**: Files are well-formatted with consistent structure.

### Recommendations:
- Consider consolidating related documents for better organization
- Update metadata tags for improved searchability
- Review security classifications on sensitive documents

### Statistics:
- Total files processed: {len(files)}
- Average processing time per file: {PROCESSING_DELAY_SECONDS / len(files):.2f} seconds
- Success rate: 100%

*This summary was generated by the File Processor Service.*
"""


@app.get("/")
async def root():
    """Root endpoint with service information."""
    return {
        "service": "File Processor Service",
        "version": "1.0.0",
        "endpoints": {"health": "/health", "process_files": "/process-files (POST)"},
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=3000)
