"""Application configuration settings."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    # Azure Configuration
    azure_subscription_id: str = ""
    azure_resource_group: str = ""
    apim_service_name: str = ""

    # Log Analytics Configuration (required for token usage queries)
    # This is the Log Analytics Workspace ID (customerId), not the resource ID
    log_analytics_workspace_id: str = ""

    # Application Settings
    use_mock_data: bool = False
    host: str = "0.0.0.0"
    port: int = 8000
    debug: bool = False

    @property
    def is_configured(self) -> bool:
        """Check if Azure settings are configured."""
        return bool(
            self.azure_subscription_id
            and self.azure_resource_group
            and self.apim_service_name
        )

    @property
    def is_log_analytics_configured(self) -> bool:
        """Check if Log Analytics is configured for usage queries."""
        return bool(self.log_analytics_workspace_id)


@lru_cache
def get_settings() -> Settings:
    """Get cached application settings."""
    return Settings()
