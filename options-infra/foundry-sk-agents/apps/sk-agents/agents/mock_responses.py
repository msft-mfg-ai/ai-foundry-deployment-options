"""
Mock Agent Responses - Handles mock responses when Azure is not configured.

This module provides mock implementations for testing without Azure connection.
(Open/Closed Principle - extending behavior without modifying existing agents)
"""

from typing import Optional

from semantic_kernel.functions import KernelArguments

from telemetry import get_logger

logger = get_logger("mock_responses")


class MockResponseGenerator:
    """Generates mock responses for testing without Azure connection."""

    def __init__(self, master_plugin, large_context_invoker):
        """
        Initialize mock response generator.

        Args:
            master_plugin: MasterAgentPlugin instance for mock calls
            large_context_invoker: Callable to invoke large context agent
        """
        self._master_plugin = master_plugin
        self._large_context_invoker = large_context_invoker

    async def generate_master_response(
        self,
        message: str,
        user_first_name: Optional[str] = None,
        user_last_name: Optional[str] = None,
    ) -> tuple[str, list[str]]:
        """Generate mock response for Master Agent."""
        message_lower = message.lower()
        plugins_invoked = []
        user_name = f"{user_first_name or ''} {user_last_name or ''}".strip()
        greeting = f"Hi {user_name}! " if user_name else ""

        # Check for file processing requests
        if any(
            word in message_lower
            for word in ["summarize", "process", "analyze", "files", "file"]
        ):
            if ":" in message:
                files_part = message.split(":")[-1].strip()
                files = [f.strip() for f in files_part.split(",")]
            else:
                files = ["document.pdf"]

            results = []
            for file_name in files:
                plugins_invoked.append("invoke_large_context_agent")
                result = await self._large_context_invoker(
                    f"Process the following file: {file_name}\n\nTask: Summarize and analyze file",
                    user_first_name=user_first_name,
                    user_last_name=user_last_name,
                )
                results.append(result.response)

            combined_result = (
                f"{greeting}Here are the summaries:\n\n" + "\n\n---\n\n".join(results)
            )
            return combined_result, plugins_invoked

        # Check for capabilities request
        if any(
            word in message_lower for word in ["capabilities", "help", "what can you"]
        ):
            plugins_invoked.append("get_capabilities")
            mock_args = KernelArguments(
                user_first_name=user_first_name or "",
                user_last_name=user_last_name or "",
            )
            result = await self._master_plugin.get_capabilities(mock_args)
            return result, plugins_invoked

        # Check for status request
        if any(word in message_lower for word in ["status", "health"]):
            plugins_invoked.append("get_system_status")
            mock_args = KernelArguments(user_id="mock_user")
            result = await self._master_plugin.get_system_status(mock_args)
            return result, plugins_invoked

        # Default response
        return (
            f"""
{greeting}I'm the Master Agent. I can help you with:

1. **File Processing**: Ask me to summarize or analyze files
   Example: "Summarize these files: report.pdf, data.csv, notes.txt"
   (I will delegate to the Large Context Agent for each file)

2. **System Information**: Ask about my capabilities or system status

How can I assist you today?
""",
            plugins_invoked,
        )

    async def generate_large_context_response(
        self, message: str, process_file_func
    ) -> str:
        """Generate mock response for Large Context Agent."""
        if ":" in message:
            file_name = message.split(":")[-1].strip().split("\n")[0].strip()
        else:
            file_name = "unknown_file"

        content = await process_file_func(file_name)

        return f"""
## Large Context Agent Analysis

**File:** {file_name}

### Summary
{content}

### Key Points
- This is a mock response from the Large Context Agent
- In production, this agent uses Azure AI Foundry to analyze content
- The file processor service was called to retrieve the file content
"""
