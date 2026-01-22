"""
Configuration settings for the SK Agents service.
"""

import os


class Settings:
    """Application settings loaded from environment variables."""
    
    # Azure AI Foundry
    AZURE_AI_PROJECT_CONNECTION_STRING: str = os.environ.get(
        "AZURE_AI_PROJECT_CONNECTION_STRING", ""
    )
    
    # Azure OpenAI
    AZURE_OPENAI_ENDPOINT: str = os.environ.get("AZURE_OPENAI_ENDPOINT", "")
    AZURE_OPENAI_DEPLOYMENT: str = os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4.1-mini")
    
    # File Processor Service
    FILE_PROCESSOR_URL: str = os.environ.get("FILE_PROCESSOR_URL", "http://localhost:3001")
    FILE_PROCESSOR_TIMEOUT: float = float(os.environ.get("FILE_PROCESSOR_TIMEOUT", "300"))
    
    # Application Insights
    APPLICATIONINSIGHTS_CONNECTION_STRING: str = os.environ.get(
        "APPLICATIONINSIGHTS_CONNECTION_STRING", ""
    )
    
    # Service Info
    SERVICE_NAME: str = "sk-agents-service"
    SERVICE_VERSION: str = "1.0.0"


settings = Settings()
