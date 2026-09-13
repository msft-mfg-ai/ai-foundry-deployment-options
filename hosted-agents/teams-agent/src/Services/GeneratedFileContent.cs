using Microsoft.Extensions.AI;

namespace AgentChat.Services;

public sealed class GeneratedFileContent(
    string containerId,
    string fileId,
    string name,
    string mediaType,
    byte[] data) : AIContent
{
    public string ContainerId { get; } = containerId;
    public string FileId { get; } = fileId;
    public string Name { get; } = name;
    public string MediaType { get; } = mediaType;
    public ReadOnlyMemory<byte> Data { get; } = data;
}
