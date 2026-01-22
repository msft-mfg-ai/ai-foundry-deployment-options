"""
File Processor Plugin - Calls the external File Processor API.
"""

from typing import Annotated

import httpx
from semantic_kernel.functions import kernel_function

from config import settings
from telemetry import get_tracer, get_logger

logger = get_logger("plugins.file_processor")
tracer = get_tracer("plugins.file_processor")


class FileProcessorPlugin:
    """Plugin for calling the File Processor API."""
    
    def __init__(self, base_url: str | None = None):
        self.base_url = base_url or settings.FILE_PROCESSOR_URL
        self.client = httpx.AsyncClient(timeout=settings.FILE_PROCESSOR_TIMEOUT)
    
    @kernel_function(
        name="process_file",
        description="Process and summarize a single file using the File Processor API"
    )
    async def process_file(
        self,
        file_name: Annotated[str, "The name of the file to process"]
    ) -> Annotated[str, "Summary of the processed file"]:
        """
        Process a single file using the File Processor API.
        
        Args:
            file_name: The name of the file to process
            
        Returns:
            Summary of the processed file
        """
        with tracer.start_as_current_span("file_processor_plugin") as span:
            span.set_attribute("file.name", file_name)
            
            logger.info(f"Calling File Processor API with file: {file_name}")
            
            try:
                response = await self.client.post(
                    f"{self.base_url}/process-files",
                    json={"files": [file_name.strip()]}
                )
                response.raise_for_status()
                result = response.json()
                
                span.set_attribute("processing.status", result.get("status", "unknown"))
                return result.get("summary", "No summary available")
                
            except httpx.TimeoutException:
                logger.error("File Processor API timeout")
                return f"Error: File processing timed out for {file_name}. Please try again later."
            except Exception as e:
                logger.error(f"File Processor API error: {e}")
                return f"Error processing file {file_name}: {str(e)}"
    
    async def close(self) -> None:
        """Close the HTTP client."""
        await self.client.aclose()
