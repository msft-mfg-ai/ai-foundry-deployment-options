namespace AgentChat.Services;

public static class DebugValueRedactor
{
    private static readonly string[] SensitiveNameMarkers =
    [
        "AUTHORIZATION",
        "COOKIE",
        "TOKEN",
        "SECRET",
        "PASSWORD",
        "PASSWD",
        "API_KEY",
        "ACCESS_KEY",
        "ACCOUNT_KEY",
        "PRIVATE_KEY",
        "CLIENT_SECRET",
        "CONNECTION_STRING",
        "CERTIFICATE",
        "CREDENTIAL",
        "IDENTITY_HEADER",
        "SIGNATURE",
        "SAS_TOKEN",
    ];

    public static string SafeValue(string name, string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value ?? "(null)";
        }

        var normalizedName = name.Replace('-', '_').ToUpperInvariant();
        if (SensitiveNameMarkers.Any(normalizedName.Contains) ||
            normalizedName.EndsWith("_KEY", StringComparison.Ordinal))
        {
            return "[REDACTED]";
        }

        if (value.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ||
            value.StartsWith("Basic ", StringComparison.OrdinalIgnoreCase) ||
            value.Contains("AccountKey=", StringComparison.OrdinalIgnoreCase) ||
            value.Contains("SharedAccessSignature ", StringComparison.OrdinalIgnoreCase) ||
            LooksLikeJwt(value))
        {
            return "[REDACTED]";
        }

        var escaped = value
            .Replace("\r", "\\r", StringComparison.Ordinal)
            .Replace("\n", "\\n", StringComparison.Ordinal)
            .Replace("```", "` ` `", StringComparison.Ordinal);
        return escaped.Length <= 2048
            ? escaped
            : $"{escaped[..2048]}... [TRUNCATED]";
    }

    private static bool LooksLikeJwt(string value)
    {
        var parts = value.Split('.');
        return parts.Length == 3 &&
               parts.All(part => part.Length >= 8 && part.All(IsBase64UrlCharacter));
    }

    private static bool IsBase64UrlCharacter(char value)
        => char.IsAsciiLetterOrDigit(value) || value is '-' or '_' or '=';
}
