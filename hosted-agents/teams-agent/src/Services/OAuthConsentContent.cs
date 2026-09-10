using Microsoft.Extensions.AI;

namespace AgentChat.Services;

public sealed class OAuthConsentContent(
    string toolboxName,
    string toolName,
    string consentUrl) : AIContent
{
    public string ToolboxName { get; } = toolboxName;

    public string ToolName { get; } = toolName;

    public string ConsentUrl { get; } = consentUrl;
}
