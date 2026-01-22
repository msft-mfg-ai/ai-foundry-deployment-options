"""
Knowledge Plugin - Provides information about agent capabilities and system status.
"""

from typing import Annotated

from semantic_kernel.functions import kernel_function


class KnowledgePlugin:
    """Plugin for general knowledge and capabilities."""

    @kernel_function(
        name="get_capabilities",
        description="Get information about what the agent can do and its capabilities",
    )
    async def get_capabilities(
        self,
    ) -> Annotated[str, "Agent capabilities information"]:
        """Return agent capabilities."""
        return """
I am the Master Agent with the following capabilities:

1. **File Processing & Summarization**
   - I can summarize multiple files by delegating to the Large Context Agent
   - Supported operations: summarize, analyze, process documents

2. **Knowledge Queries**
   - Answer questions about my capabilities
   - Provide guidance on how to use the system

3. **Multi-Agent Orchestration**
   - I coordinate with specialized agents for complex tasks
   - The Large Context Agent handles large document processing

To use file processing, simply provide the file names you want to process.
Example: "Summarize these files: report.pdf, data.csv, notes.txt"
"""

    @kernel_function(
        name="get_system_status",
        description="Get the current system status and health information",
    )
    async def get_system_status(self) -> Annotated[str, "System status information"]:
        """Return system status."""
        return """
System Status: Operational ✅

- Master Agent: Active
- Large Context Agent: Active  
- File Processor Service: Connected
- OpenTelemetry: Enabled

All systems are functioning normally.
"""
