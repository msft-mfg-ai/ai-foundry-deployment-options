using System.Text;
using System.Text.Json;

namespace AgentChat.Services;

public static class TokenClaimSummary
{
    private static readonly HashSet<string> AllowedClaims =
    [
        "aud",
        "iss",
        "tid",
        "oid",
        "sub",
        "name",
        "preferred_username",
        "upn",
        "email",
        "scp",
        "roles",
        "azp",
        "xms_par_app_azp",
        "appid",
        "idtyp",
        "ver",
        "iat",
        "nbf",
        "exp",
    ];

    public static IReadOnlyDictionary<string, string> Read(string token)
    {
        var parts = token.Split('.');
        if (parts.Length < 2)
        {
            throw new InvalidDataException(
                "The Bot Token Service returned a non-JWT token.");
        }

        using var payload = JsonDocument.Parse(
            DecodeBase64Url(parts[1]));
        if (payload.RootElement.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException(
                "The JWT payload is not an object.");
        }

        var claims = new SortedDictionary<string, string>(
            StringComparer.Ordinal);
        foreach (var property in payload.RootElement.EnumerateObject())
        {
            if (!AllowedClaims.Contains(property.Name))
            {
                continue;
            }

            claims[property.Name] = FormatValue(property.Value);
        }

        return claims;
    }

    public static string ToToolResult(string token)
        => JsonSerializer.Serialize(
            new
            {
                authenticated = true,
                tokenIncluded = false,
                claims = Read(token),
            },
            new JsonSerializerOptions
            {
                WriteIndented = true,
            });

    private static byte[] DecodeBase64Url(string value)
    {
        var normalized = value
            .Replace('-', '+')
            .Replace('_', '/');
        normalized = normalized.PadRight(
            normalized.Length + ((4 - normalized.Length % 4) % 4),
            '=');
        return Convert.FromBase64String(normalized);
    }

    private static string FormatValue(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Array)
        {
            return string.Join(
                ", ",
                value.EnumerateArray()
                    .Take(20)
                    .Select(item => item.ToString()));
        }

        if (value.ValueKind == JsonValueKind.String)
        {
            return value.GetString() ?? string.Empty;
        }

        return value.GetRawText();
    }
}
