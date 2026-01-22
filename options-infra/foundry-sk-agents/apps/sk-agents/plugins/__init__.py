"""
Plugins for the SK Agents service.
"""

from plugins.file_processor import FileProcessorPlugin
from plugins.knowledge import KnowledgePlugin
from plugins.large_context_agent import LargeContextAgentPlugin

# Only export the plugins that are used as tools by the master agent
# FileProcessorPlugin is used internally by LargeContextAgentPlugin
__all__ = [
    "FileProcessorPlugin",  # Internal use only
    "KnowledgePlugin", 
    "LargeContextAgentPlugin",
]
