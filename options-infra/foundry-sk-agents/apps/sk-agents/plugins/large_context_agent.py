"""
Large Context Agent Plugin - Handles file processing and summarization tasks.
"""

from typing import Annotated

from semantic_kernel.functions import kernel_function

from plugins.file_processor import FileProcessorPlugin
from telemetry import get_tracer, get_logger

logger = get_logger("plugins.large_context_agent")
tracer = get_tracer("plugins.large_context_agent")


class LargeContextAgentPlugin:
    """Plugin that invokes the Large Context Agent for file processing tasks."""
    
    def __init__(self, file_processor_plugin: FileProcessorPlugin):
        self.file_processor = file_processor_plugin
    
    @kernel_function(
        name="invoke_large_context_agent",
        description="Invoke the Large Context Agent to process and summarize a single file. Call this once per file you need to process."
    )
    async def invoke_large_context_agent(
        self,
        task_description: Annotated[str, "Description of what to do with the file"],
        file_name: Annotated[str, "The name of the single file to process"]
    ) -> Annotated[str, "Result from processing the file"]:
        """
        Invoke the Large Context Agent to process a single file.
        
        Args:
            task_description: Description of what to do with the file
            file_name: The name of the single file to process
            
        Returns:
            Result from the Large Context Agent
        """
        with tracer.start_as_current_span("large_context_agent_invocation") as span:
            span.set_attribute("task", task_description)
            span.set_attribute("file", file_name)
            
            logger.info(f"Large Context Agent processing file '{file_name}': {task_description}")
            
            # Call the file processor for the single file
            summary = await self.file_processor.process_file(file_name)
            
            result = f"""
## Large Context Agent Response

**Task:** {task_description}

**File Processed:** {file_name}

{summary}
"""
            return result
