"""Reusable client + fixtures for ai-gateway-quota integration tests."""

from .config import (
    GATEWAY_URL,
    API_URL,
    DISCOVERY_API_URL,
    AZURE_OPENAI_API_URL,
    CONFIG_JSON_URL,
    CONFIG_UPDATE_URL,
    API_VERSION,
    TENANT_ID,
    CLIENT_ID,
    CLIENT_SECRET,
    AUDIENCE,
    APIM_SUBSCRIPTION_KEY,
    TEST_ACCESS_TOKEN,
    DEFAULT_MODEL,
    FAILOVER_MODEL,
    DEFAULT_CONTRACT_NAME,
    validate_required_config,
)
from .client import (
    GatewayResponse,
    get_credential,
    get_token,
    send_request,
    send_request_streaming,
    send_responses,
    send_chat_at_path,
    print_response,
    get_config_json,
    get_config_html,
    post_config_update,
)

__all__ = [
    'GATEWAY_URL', 'API_URL', 'DISCOVERY_API_URL', 'AZURE_OPENAI_API_URL',
    'CONFIG_JSON_URL', 'CONFIG_UPDATE_URL', 'API_VERSION', 'TENANT_ID',
    'CLIENT_ID', 'CLIENT_SECRET', 'AUDIENCE', 'APIM_SUBSCRIPTION_KEY',
    'TEST_ACCESS_TOKEN', 'DEFAULT_MODEL', 'FAILOVER_MODEL',
    'DEFAULT_CONTRACT_NAME', 'validate_required_config', 'GatewayResponse',
    'get_credential', 'get_token', 'send_request', 'send_request_streaming',
    'send_responses', 'send_chat_at_path', 'print_response', 'get_config_json',
    'get_config_html', 'post_config_update',
]
