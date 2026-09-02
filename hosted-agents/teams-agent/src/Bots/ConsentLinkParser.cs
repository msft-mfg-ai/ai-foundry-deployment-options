using System.Text.RegularExpressions;

namespace AgentChat.Bots;

public static class ConsentLinkParser
{
    /// <summary>
    /// Extracts the first HTTP(S) URL from a Foundry <c>consent_link</c> value.
    /// Foundry may send either a bare URL or prose such as
    /// "OAuth consent required. Please visit: https://..."; when multiple URLs
    /// are present, the first URL is used.
    /// </summary>
    public static string? ExtractConsentUrl(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;

        var match = Regex.Match(raw.Trim(), @"https?://\S+", RegexOptions.IgnoreCase);
        if (!match.Success) return null;

        var url = match.Value.Trim().TrimEnd('.', ',', ')', ']');
        return string.IsNullOrWhiteSpace(url) ? null : url;
    }
}
