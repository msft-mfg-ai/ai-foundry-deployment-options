namespace AgentChat.Services;

public static class FoundryPlaygroundUrl
{
    public static string? Build(
        string? projectResourceId,
        string? agentName,
        string? agentVersion)
    {
        if (string.IsNullOrWhiteSpace(projectResourceId) ||
            string.IsNullOrWhiteSpace(agentName) ||
            string.IsNullOrWhiteSpace(agentVersion))
        {
            return null;
        }

        var segments = projectResourceId.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var subscriptionId = SegmentAfter(segments, "subscriptions");
        var resourceGroup = SegmentAfter(segments, "resourceGroups");
        var accountName = SegmentAfter(segments, "accounts");
        var projectName = SegmentAfter(segments, "projects");
        if (!Guid.TryParse(subscriptionId, out var subscriptionGuid) ||
            string.IsNullOrWhiteSpace(resourceGroup) ||
            string.IsNullOrWhiteSpace(accountName) ||
            string.IsNullOrWhiteSpace(projectName))
        {
            return null;
        }

        var subscriptionBytes = Convert.FromHexString(
            subscriptionGuid.ToString("N"));
        var encodedSubscription = Convert.ToBase64String(subscriptionBytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');

        return "https://ai.azure.com/nextgen/r/"
            + $"{encodedSubscription},{Uri.EscapeDataString(resourceGroup)},,"
            + $"{Uri.EscapeDataString(accountName)},{Uri.EscapeDataString(projectName)}"
            + $"/build/agents/{Uri.EscapeDataString(agentName)}/build"
            + $"?version={Uri.EscapeDataString(agentVersion)}";
    }

    private static string? SegmentAfter(string[] segments, string marker)
    {
        var index = Array.FindIndex(
            segments,
            segment => segment.Equals(marker, StringComparison.OrdinalIgnoreCase));
        return index >= 0 && index + 1 < segments.Length
            ? segments[index + 1]
            : null;
    }
}
