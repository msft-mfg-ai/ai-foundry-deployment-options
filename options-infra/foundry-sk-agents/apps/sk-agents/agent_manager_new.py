"""
Agent Manager - Manages agents using Semantic Kernel with Azure AI Foundry Agent Service.

This module creates TWO Azure AI Foundry Agents:
1. Master Agent - Orchestrates tasks and delegates to the Large Context Agent
2. Large Context Agent - Processes files and handles large context operations
"""

from datetime import date
from typing import Optional, Annotated, Callable, AsyncIterator

from azure.identity.aio import DefaultAzureCredential
from semantic_kernel import Kernel
from semantic_kernel.agents import AzureAIAgent, AzureAIAgentSettings, AzureAIAgentThread
from semantic_kernel.functions import kernel_function
from semantic_kernel.contents import FunctionCallContent, FunctionResultContent
from semantic_kernel.contents.chat_message_content import ChatMessageContent, TextContent

from config import settings
from models import InvokeResult
from telemetry import get_tracer, get_logger
from plugins import FileProcessorPlugin, KnowledgePlugin

logger = get_logger("agent_manager")
tracer = get_tracer("agent_manager")


# =============================================================================
# Agent Instructions
# =============================================================================

MASTER_AGENT_INSTRUCTIONS = """
You are the Master Agent, an intelligent orchestrator that helps users with various tasks.
You have access to the following tools:

1. invoke_large_context_agent - For processing and summarizing a SINGLE file. If the user provides multiple files, you MUST call this tool once for each file separately.
2. get_capabilities - For answering questions about your capabilities
3. get_system_status - For getting system health information

IMPORTANT RULES FOR MULTIPLE FILES:
- When users ask to summarize or process multiple files (e.g., "summarize files: a.pdf, b.pdf, c.pdf"), 
  you MUST call invoke_large_context_agent SEPARATELY for each file.
- Make ALL the tool calls in PARALLEL in a single response - do not wait for one to complete before calling the next.
- Example: For 3 files, return 3 parallel invoke_large_context_agent calls, one for each file.

When users ask about capabilities or what you can do, use the get_capabilities tool.
When users ask about system status, use the get_system_status tool.

Always be helpful and provide clear, informative responses.
"""

LARGE_CONTEXT_AGENT_INSTRUCTIONS = """
You are the Large Context Agent, a specialized agent for processing files and handling large context operations.

Your primary responsibility is to:
1. Receive file processing requests from the Master Agent
2. Use the process_file tool to fetch and process file content
3. Analyze, summarize, or extract information from the file content
4. Return a comprehensive summary or analysis to the Master Agent

When processing files:
- Always provide a clear, structured summary
- Include key points, main topics, and important details
- If the file contains data, provide relevant statistics or insights
- Format your response in a clear, readable manner

You are an expert at understanding and summarizing complex documents.
"""


# =============================================================================
# Plugins
# =============================================================================

class MasterAgentPlugin:
    """Plugin that provides tools for the Master Agent."""
    
    def __init__(self, agent_manager: "AgentManager"):
        self._agent_manager = agent_manager
        self.knowledge_plugin = KnowledgePlugin()
    
    @kernel_function(
        name="invoke_large_context_agent",
        description="Invoke the Large Context Agent to process and summarize a SINGLE file. Call this tool once per file - if you have 3 files, call this 3 times."
    )
    async def invoke_large_context_agent(
        self,
        task_description: Annotated[str, "Description of what to do with the file"],
        file_name: Annotated[str, "The name of a SINGLE file to process"]
    ) -> Annotated[str, "Result from the Large Context Agent"]:
        """Invoke the Large Context Agent for a single file."""
        logger.info(f"Master Agent invoking Large Context Agent for file: {file_name}")
        
        # Build the message to send to the Large Context Agent
        message = f"Process the following file: {file_name}\n\nTask: {task_description}"
        
        # Invoke the Large Context Agent
        result = await self._agent_manager.invoke_large_context_agent(message)
        
        return result.response
    
    @kernel_function(
        name="get_capabilities",
        description="Get information about what the agent can do and its capabilities"
    )
    async def get_capabilities(self) -> Annotated[str, "Agent capabilities information"]:
        """Return agent capabilities."""
        return await self.knowledge_plugin.get_capabilities()
    
    @kernel_function(
        name="get_system_status",
        description="Get the current system status and health information"
    )
    async def get_system_status(self) -> Annotated[str, "System status information"]:
        """Return system status."""
        return await self.knowledge_plugin.get_system_status()


class LargeContextAgentPlugin:
    """Plugin that provides file processing tools for the Large Context Agent."""
    
    def __init__(self, file_processor: FileProcessorPlugin):
        self._file_processor = file_processor
    
    @kernel_function(
        name="process_file",
        description="Process a file and return its content for analysis. Use this to fetch file content before summarizing."
    )
    async def process_file(
        self,
        file_name: Annotated[str, "The name of the file to process"]
    ) -> Annotated[str, "The processed file content"]:
        """Process a file and return its content."""
        logger.info(f"Large Context Agent processing file: {file_name}")
        return await self._file_processor.process_file(file_name)


# =============================================================================
# Intermediate Message Handler
# =============================================================================

async def on_intermediate_message(agent_response: ChatMessageContent):
    """Handle intermediate messages from the agent during streaming."""
    logger.info(f"Intermediate response from Agent")
    for item in agent_response.items or []:
        if isinstance(item, FunctionResultContent):
            result_preview = str(item.result)[:100] + "..." if len(str(item.result)) > 100 else str(item.result)
            logger.info(f"Function Result for '{item.name}': {result_preview}")
        elif isinstance(item, FunctionCallContent):
            logger.info(f"Function Call: {item.name} with arguments: {item.arguments}")
        elif isinstance(item, TextContent):
            text_preview = item.text[:100] + "..." if len(item.text) > 100 else item.text
            logger.info(f"Text: {text_preview}")
        else:
            logger.info(f"Other content: {type(item).__name__}")


# =============================================================================
# Agent Manager
# =============================================================================

class AgentManager:
    """Manages agents using Semantic Kernel with Azure AI Foundry Agent Service."""
    
    def __init__(self):
        # Agents
        self.master_agent: Optional[AzureAIAgent] = None
        self.large_context_agent: Optional[AzureAIAgent] = None
        
        # Agent definitions (for tracking IDs)
        self.master_agent_definition = None
        self.large_context_agent_definition = None
        
        # Client and threads
        self.agent_client = None
        self.master_thread: Optional[AzureAIAgentThread] = None
        self.large_context_thread: Optional[AzureAIAgentThread] = None
        
        # Plugins
        self.file_processor_plugin: Optional[FileProcessorPlugin] = None
        self.master_plugin: Optional[MasterAgentPlugin] = None
        self.large_context_plugin: Optional[LargeContextAgentPlugin] = None
        
        # Configuration
        self.credential: Optional[DefaultAzureCredential] = None
        self.ai_agent_settings: Optional[AzureAIAgentSettings] = None
        self.is_initialized = False
        
    async def initialize(self) -> None:
        """Initialize the agents and plugins."""
        with tracer.start_as_current_span("agent_manager_initialize"):
            try:
                # Initialize credential
                self.credential = DefaultAzureCredential()
                
                # Initialize file processor plugin
                self.file_processor_plugin = FileProcessorPlugin()
                
                # Setup agents
                if settings.AZURE_AI_PROJECT_CONNECTION_STRING:
                    logger.info("Initializing with Azure AI Foundry Agent Service")
                    logger.info(f"Connection string: {settings.AZURE_AI_PROJECT_CONNECTION_STRING[:50]}...")
                    await self._setup_agents()
                else:
                    logger.warning("No Azure AI connection configured (AZURE_AI_PROJECT_CONNECTION_STRING not set), using mock mode")
                    # Initialize plugins for mock mode
                    self.master_plugin = MasterAgentPlugin(self)
                    self.large_context_plugin = LargeContextAgentPlugin(self.file_processor_plugin)
                
                self.is_initialized = True
                logger.info("Agent Manager initialized successfully")
                
            except Exception as e:
                logger.error(f"Failed to initialize Agent Manager: {e}")
                import traceback
                logger.error(f"Traceback: {traceback.format_exc()}")
                raise
    
    async def _setup_agents(self) -> None:
        """Setup both agents using Azure AI Foundry Agent Service."""
        # Use AzureAIAgentSettings for configuration
        self.ai_agent_settings = AzureAIAgentSettings(
            endpoint=settings.AZURE_AI_PROJECT_CONNECTION_STRING,
            model_deployment_name=settings.AZURE_OPENAI_DEPLOYMENT,
        )
        
        logger.info(f"AzureAIAgentSettings - endpoint: {self.ai_agent_settings.endpoint}")
        logger.info(f"AzureAIAgentSettings - model: {self.ai_agent_settings.model_deployment_name}")
        
        if not self.ai_agent_settings.endpoint:
            logger.warning("No endpoint configured in AzureAIAgentSettings")
            return
        
        # Create the Azure AI Agent client
        logger.info("Creating Azure AI Agent client...")
        self.agent_client = AzureAIAgent.create_client(
            credential=self.credential,
            endpoint=self.ai_agent_settings.endpoint,
        )
        logger.info("Azure AI Agent client created")
        
        # List existing agents for debugging
        logger.info("Listing existing agents in Foundry...")
        existing_agents = {}
        async for agent in self.agent_client.agents.list_agents():
            logger.info(f"Found agent - ID: {agent.id}, Name: {agent.name}, Model: {agent.model}")
            existing_agents[agent.name] = agent
        
        # Setup Large Context Agent first (since Master Agent depends on it)
        await self._setup_large_context_agent(existing_agents)
        
        # Setup Master Agent (with plugin that references Large Context Agent)
        await self._setup_master_agent(existing_agents)
        
        logger.info("Both agents ready!")
    
    async def _setup_large_context_agent(self, existing_agents: dict) -> None:
        """Setup the Large Context Agent in Azure AI Foundry."""
        agent_name = "LargeContextAgent"
        
        # Initialize the plugin
        self.large_context_plugin = LargeContextAgentPlugin(self.file_processor_plugin)
        
        # Check if agent already exists
        if agent_name in existing_agents:
            # Update existing agent
            agent_definition = existing_agents[agent_name]
            logger.info(f"Updating existing Large Context Agent: {agent_definition.id}")
            agent_definition = await self.agent_client.agents.update_agent(
                agent_id=agent_definition.id,
                instructions=LARGE_CONTEXT_AGENT_INSTRUCTIONS,
                model=self.ai_agent_settings.model_deployment_name,
                temperature=0.2,
            )
            logger.info(f"Updated Large Context Agent: {agent_definition.id}")
        else:
            # Create new agent
            logger.info(f"Creating new Large Context Agent...")
            agent_definition = await self.agent_client.agents.create_agent(
                model=self.ai_agent_settings.model_deployment_name,
                name=agent_name,
                instructions=LARGE_CONTEXT_AGENT_INSTRUCTIONS,
                temperature=0.2,
            )
            logger.info(f"Created Large Context Agent: {agent_definition.id}")
        
        self.large_context_agent_definition = agent_definition
        
        # Create the Semantic Kernel AzureAIAgent with plugin
        self.large_context_agent = AzureAIAgent(
            client=self.agent_client,
            definition=agent_definition,
            plugins=[self.large_context_plugin],
            kernel=Kernel(),
        )
        
        logger.info(f"Large Context Agent ready - ID: {agent_definition.id}, Name: {agent_definition.name}")
    
    async def _setup_master_agent(self, existing_agents: dict) -> None:
        """Setup the Master Agent in Azure AI Foundry."""
        agent_name = "MasterAgent"
        
        # Initialize the plugin (with reference to this AgentManager for invoking Large Context Agent)
        self.master_plugin = MasterAgentPlugin(self)
        
        # Check if agent already exists
        if agent_name in existing_agents:
            # Update existing agent
            agent_definition = existing_agents[agent_name]
            logger.info(f"Updating existing Master Agent: {agent_definition.id}")
            agent_definition = await self.agent_client.agents.update_agent(
                agent_id=agent_definition.id,
                instructions=MASTER_AGENT_INSTRUCTIONS,
                model=self.ai_agent_settings.model_deployment_name,
                temperature=0.2,
            )
            logger.info(f"Updated Master Agent: {agent_definition.id}")
        else:
            # Create new agent
            logger.info(f"Creating new Master Agent...")
            agent_definition = await self.agent_client.agents.create_agent(
                model=self.ai_agent_settings.model_deployment_name,
                name=agent_name,
                instructions=MASTER_AGENT_INSTRUCTIONS,
                temperature=0.2,
            )
            logger.info(f"Created Master Agent: {agent_definition.id}")
        
        self.master_agent_definition = agent_definition
        
        # Create the Semantic Kernel AzureAIAgent with plugin
        self.master_agent = AzureAIAgent(
            client=self.agent_client,
            definition=agent_definition,
            plugins=[self.master_plugin],
            kernel=Kernel(),
        )
        
        logger.info(f"Master Agent ready - ID: {agent_definition.id}, Name: {agent_definition.name}")
    
    async def invoke_large_context_agent(
        self, 
        message: str,
    ) -> InvokeResult:
        """
        Invoke the Large Context Agent with a message.
        
        Args:
            message: Message to send to the Large Context Agent
            
        Returns:
            InvokeResult with response
        """
        with tracer.start_as_current_span("large_context_agent_invoke") as span:
            span.set_attribute("message.length", len(message))
            
            plugins_invoked = []
            
            try:
                if self.large_context_agent:
                    # Create thread if not exists
                    if self.large_context_thread is None:
                        self.large_context_thread = AzureAIAgentThread(client=self.agent_client)
                        logger.info("Created new Large Context Agent thread")
                    
                    response_text = ""
                    
                    logger.info(f"Invoking Large Context Agent with message: {message[:100]}...")
                    
                    async for agent_response in self.large_context_agent.invoke(
                        messages=message,
                        thread=self.large_context_thread,
                        on_intermediate_message=on_intermediate_message,
                    ):
                        # Process items in the response
                        for item in agent_response.items or []:
                            if isinstance(item, TextContent):
                                response_text = item.text
                            elif isinstance(item, FunctionCallContent):
                                plugins_invoked.append(item.name)
                        
                        # Update thread reference
                        self.large_context_thread = agent_response.thread
                    
                    if not response_text and agent_response:
                        response_text = str(agent_response.content) if agent_response.content else str(agent_response)
                    
                else:
                    # Mock mode
                    response_text = await self._mock_large_context_response(message)
                    plugins_invoked.append("process_file")
                
                return InvokeResult(
                    response=response_text,
                    agent_used="large_context_agent",
                    plugins_invoked=plugins_invoked
                )
                
            except Exception as e:
                logger.error(f"Error in Large Context Agent: {e}")
                import traceback
                logger.error(f"Traceback: {traceback.format_exc()}")
                
                return InvokeResult(
                    response=f"Error processing file: {str(e)}",
                    agent_used="large_context_agent",
                    plugins_invoked=plugins_invoked
                )
    
    async def _mock_large_context_response(self, message: str) -> str:
        """Generate mock response for Large Context Agent."""
        # Extract file name from message
        if ":" in message:
            file_name = message.split(":")[-1].strip().split("\n")[0].strip()
        else:
            file_name = "unknown_file"
        
        # Use the plugin to process the file
        content = await self.large_context_plugin.process_file(file_name)
        
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
    
    async def invoke_master_agent(
        self, 
        message: str, 
        context: Optional[dict] = None,
        on_intermediate: Optional[Callable[[ChatMessageContent], None]] = None,
    ) -> InvokeResult:
        """
        Invoke the Master Agent with a message using streaming.
        
        Args:
            message: User message
            context: Optional context dictionary
            on_intermediate: Optional callback for intermediate messages
            
        Returns:
            InvokeResult with response and metadata
        """
        with tracer.start_as_current_span("master_agent_invoke") as span:
            span.set_attribute("message.length", len(message))
            
            plugins_invoked = []
            
            try:
                if self.master_agent:
                    # Create thread if not exists
                    if self.master_thread is None:
                        self.master_thread = AzureAIAgentThread(client=self.agent_client)
                        logger.info("Created new Master Agent thread")
                    
                    response_text = ""
                    response_count = 0
                    additional_instructions = f"Today is {date.today().strftime('%Y-%m-%d')}"
                    
                    logger.info(f"Invoking Master Agent with message: {message[:100]}...")
                    
                    async for agent_response in self.master_agent.invoke(
                        messages=message,
                        thread=self.master_thread,
                        additional_instructions=additional_instructions,
                        on_intermediate_message=on_intermediate or on_intermediate_message,
                    ):
                        response_count += 1
                        logger.info(f"Processing response #{response_count}")
                        
                        # Process items in the response
                        for item in agent_response.items or []:
                            if isinstance(item, TextContent):
                                response_text = item.text
                                logger.info(f"Got text response: {response_text[:100]}...")
                            elif isinstance(item, FunctionCallContent):
                                plugins_invoked.append(item.name)
                                logger.info(f"Function called: {item.name}")
                            elif isinstance(item, FunctionResultContent):
                                logger.info(f"Function result for: {item.name}")
                        
                        # Update thread reference
                        self.master_thread = agent_response.thread
                    
                    logger.info(f"Master Agent completed. Processed {response_count} responses.")
                    
                    if not response_text and agent_response:
                        response_text = str(agent_response.content) if agent_response.content else str(agent_response)
                    
                else:
                    # Mock mode response
                    response_text, plugins_invoked = await self._generate_mock_response(message)
                
                span.set_attribute("response.length", len(response_text))
                span.set_attribute("plugins.invoked", ", ".join(plugins_invoked))
                
                return InvokeResult(
                    response=response_text,
                    agent_used="master_agent",
                    plugins_invoked=plugins_invoked
                )
                
            except Exception as e:
                logger.error(f"Error in master agent: {e}")
                import traceback
                logger.error(f"Traceback: {traceback.format_exc()}")
                span.record_exception(e)
                
                return InvokeResult(
                    response=f"I encountered an error processing your request: {str(e)}. Please try again.",
                    agent_used="master_agent",
                    plugins_invoked=plugins_invoked
                )
    
    async def invoke_master_agent_stream(
        self, 
        message: str, 
        context: Optional[dict] = None,
    ) -> AsyncIterator[str]:
        """
        Invoke the Master Agent with streaming response.
        
        Args:
            message: User message
            context: Optional context dictionary
            
        Yields:
            Streamed response chunks
        """
        with tracer.start_as_current_span("master_agent_invoke_stream") as span:
            span.set_attribute("message.length", len(message))
            
            try:
                if self.master_agent:
                    # Create thread if not exists
                    if self.master_thread is None:
                        self.master_thread = AzureAIAgentThread(client=self.agent_client)
                    
                    additional_instructions = f"Today is {date.today().strftime('%Y-%m-%d')}"
                    
                    async for agent_response in self.master_agent.invoke(
                        messages=message,
                        thread=self.master_thread,
                        additional_instructions=additional_instructions,
                        on_intermediate_message=on_intermediate_message,
                    ):
                        # Process items and yield text
                        for item in agent_response.items or []:
                            if isinstance(item, TextContent):
                                yield item.text
                            elif isinstance(item, FunctionCallContent):
                                yield f"\n[Calling tool: {item.name}]\n"
                            elif isinstance(item, FunctionResultContent):
                                yield f"\n[Tool {item.name} completed]\n"
                        
                        # Update thread reference
                        self.master_thread = agent_response.thread
                else:
                    # Mock mode
                    response_text, _ = await self._generate_mock_response(message)
                    yield response_text
                    
            except Exception as e:
                logger.error(f"Error in streaming: {e}")
                yield f"Error: {str(e)}"
    
    async def _generate_mock_response(self, message: str) -> tuple[str, list[str]]:
        """Generate mock response for testing without Azure connection."""
        message_lower = message.lower()
        plugins_invoked = []
        
        # Check for file processing requests
        if any(word in message_lower for word in ["summarize", "process", "analyze", "files", "file"]):
            # Extract file names (simple heuristic)
            if ":" in message:
                files_part = message.split(":")[-1].strip()
                files = [f.strip() for f in files_part.split(",")]
            else:
                files = ["document.pdf"]
            
            # Process each file separately using the Large Context Agent
            results = []
            for file_name in files:
                plugins_invoked.append("invoke_large_context_agent")
                result = await self.invoke_large_context_agent(
                    f"Process the following file: {file_name}\n\nTask: Summarize and analyze file"
                )
                results.append(result.response)
            
            combined_result = "\n\n---\n\n".join(results)
            return combined_result, plugins_invoked
        
        # Check for capabilities request
        if any(word in message_lower for word in ["capabilities", "help", "what can you"]):
            plugins_invoked.append("get_capabilities")
            result = await self.master_plugin.get_capabilities()
            return result, plugins_invoked
        
        # Check for status request
        if any(word in message_lower for word in ["status", "health"]):
            plugins_invoked.append("get_system_status")
            result = await self.master_plugin.get_system_status()
            return result, plugins_invoked
        
        # Default response
        return """
I'm the Master Agent. I can help you with:

1. **File Processing**: Ask me to summarize or analyze files
   Example: "Summarize these files: report.pdf, data.csv, notes.txt"
   (I will delegate to the Large Context Agent for each file)

2. **System Information**: Ask about my capabilities or system status

How can I assist you today?
""", plugins_invoked
    
    def get_agents_info(self) -> dict:
        """Get information about available agents."""
        master_id = None
        large_context_id = None
        
        if self.master_agent_definition:
            master_id = self.master_agent_definition.id
        if self.large_context_agent_definition:
            large_context_id = self.large_context_agent_definition.id
        
        return {
            "agents": [
                {
                    "name": "MasterAgent",
                    "id": master_id,
                    "description": "Orchestrates tasks and delegates to the Large Context Agent",
                    "status": "active" if self.is_initialized else "initializing",
                    "type": "AzureAIAgent (Foundry Agent Service)"
                },
                {
                    "name": "LargeContextAgent",
                    "id": large_context_id,
                    "description": "Processes files and handles large context operations",
                    "status": "active" if self.is_initialized else "initializing",
                    "type": "AzureAIAgent (Foundry Agent Service)"
                }
            ],
            "tools": [
                {
                    "name": "invoke_large_context_agent",
                    "description": "Delegates to Large Context Agent for file processing",
                    "agent": "MasterAgent"
                },
                {
                    "name": "get_capabilities",
                    "description": "Get agent capabilities",
                    "agent": "MasterAgent"
                },
                {
                    "name": "get_system_status",
                    "description": "Get system status",
                    "agent": "MasterAgent"
                },
                {
                    "name": "process_file",
                    "description": "Process a file and return its content",
                    "agent": "LargeContextAgent"
                }
            ]
        }
    
    async def cleanup(self) -> None:
        """Cleanup resources including Azure AI Foundry agents."""
        try:
            # Delete threads
            if self.master_thread:
                await self.master_thread.delete()
                logger.info("Deleted Master Agent thread")
            
            if self.large_context_thread:
                await self.large_context_thread.delete()
                logger.info("Deleted Large Context Agent thread")
            
            # Note: We don't delete the agents from Foundry on cleanup
            # so they persist between restarts. Uncomment below to delete:
            # if self.master_agent_definition and self.agent_client:
            #     await self.agent_client.agents.delete_agent(self.master_agent_definition.id)
            #     logger.info("Deleted Master Agent from Azure AI Foundry")
            # if self.large_context_agent_definition and self.agent_client:
            #     await self.agent_client.agents.delete_agent(self.large_context_agent_definition.id)
            #     logger.info("Deleted Large Context Agent from Azure AI Foundry")
            
            # Close the agent client
            if self.agent_client:
                await self.agent_client.close()
                logger.info("Closed agent client")
                
        except Exception as e:
            logger.warning(f"Error during agent cleanup: {e}")
        
        if self.file_processor_plugin:
            await self.file_processor_plugin.close()
        
        if self.credential:
            await self.credential.close()
