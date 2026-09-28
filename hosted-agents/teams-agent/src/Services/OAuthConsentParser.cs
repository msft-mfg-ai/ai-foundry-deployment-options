using System.Text.RegularExpressions;
using ModelContextProtocol;

namespace AgentChat.Services;

public static partial class OAuthConsentParser
{
    public static OAuthConsentContent? TryParse(
        Exception exception,
        string toolboxName)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            var isConsentRequired =
                current is McpProtocolException protocolException
                    && (int)protocolException.ErrorCode == -32006
                || current.Message.Contains(
                    "CONSENT_REQUIRED",
                    StringComparison.OrdinalIgnoreCase)
                || current.Message.Contains(
                    "OAuth consent required",
                    StringComparison.OrdinalIgnoreCase);
            if (!isConsentRequired)
            {
                continue;
            }

            var consentUrl = ExtractConsentUrl(current.Message);
            if (consentUrl is null)
            {
                continue;
            }

            return new OAuthConsentContent(
                toolboxName,
                ExtractToolName(current.Message) ?? toolboxName,
                consentUrl);
        }

        return null;
    }

    public static string? ExtractConsentUrl(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        var match = HttpUrlRegex().Match(raw);
        if (!match.Success)
        {
            return null;
        }

        var candidate = match.Value.TrimEnd('.', ',', ')', ']', '"', '\'');
        return Uri.TryCreate(candidate, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttps
                || uri.Scheme == Uri.UriSchemeHttp)
            ? uri.AbsoluteUri
            : null;
    }

    private static string? ExtractToolName(string message)
    {
        var match = ToolNameRegex().Match(message);
        return match.Success ? match.Groups["name"].Value : null;
    }

    [GeneratedRegex(@"https?://[^\s""']+", RegexOptions.IgnoreCase)]
    private static partial Regex HttpUrlRegex();

    [GeneratedRegex(@"""name""\s*:\s*""(?<name>[^""]+)""", RegexOptions.IgnoreCase)]
    private static partial Regex ToolNameRegex();
}
