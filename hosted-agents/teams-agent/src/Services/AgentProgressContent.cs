using Microsoft.Extensions.AI;

namespace AgentChat.Services;

public enum AgentProgressStage
{
    PreparingGeneratedFile,
}

public sealed class AgentProgressContent(
    AgentProgressStage stage) : AIContent
{
    public AgentProgressStage Stage { get; } = stage;
}
