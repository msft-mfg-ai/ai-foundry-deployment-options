namespace AgentChat.Auth;

public sealed class TeamsTabAuthOptions
{
    public const string Scheme = "TeamsTabBearer";
    public const string Policy = "TeamsTabUser";
    public const string DelegatedScope = "access_as_user";

    public bool Enabled { get; init; }
    public string Instance { get; init; } = "https://login.microsoftonline.com/";
    public string? TenantId { get; init; }
    public string? ClientId { get; init; }
    public string? ClientSecret { get; init; }
    public string? IdentifierUri { get; init; }
    public string? PublicOrigin { get; init; }

    public string Authority => $"{Instance.TrimEnd('/')}/{TenantId}";

    public string ApiScope
    {
        get
        {
            var resource = NormalizedAudience;
            return string.IsNullOrEmpty(resource) ? "" : $"{resource}/{DelegatedScope}";
        }
    }

    public string? NormalizedAudience
    {
        get
        {
            if (string.IsNullOrWhiteSpace(IdentifierUri)) return ClientId;
            var value = IdentifierUri.Trim().TrimEnd('/');
            var suffix = $"/{DelegatedScope}";
            return value.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)
                ? value[..^suffix.Length]
                : value;
        }
    }

    public static TeamsTabAuthOptions FromConfiguration(IConfiguration config)
    {
        var section = config.GetSection("TeamsTab");
        var tenantId = section["TenantId"]
            ?? config["TeamsApp:TenantId"]
            ?? config["TeamsSso:TenantId"]
            ?? config["AZURE_TENANT_ID"];
        var clientId = section["ClientId"]
            ?? config["TeamsApp:BackendAppId"]
            ?? config["TeamsSso:AadAppId"];
        var clientSecret = section["ClientSecret"]
            ?? config["TeamsApp:BackendSecret"];
        var identifierUri = section["IdentifierUri"]
            ?? config["TeamsApp:IdentifierUri"]
            ?? config["TeamsSso:Resource"];

        var enabled = section.GetValue<bool?>("Enabled")
            ?? (!string.IsNullOrWhiteSpace(tenantId)
                && !string.IsNullOrWhiteSpace(clientId)
                && !string.IsNullOrWhiteSpace(clientSecret)
                && !string.IsNullOrWhiteSpace(identifierUri)
                && !string.IsNullOrWhiteSpace(section["PublicOrigin"]));

        return new TeamsTabAuthOptions
        {
            Enabled = enabled,
            Instance = section["Instance"] ?? "https://login.microsoftonline.com/",
            TenantId = tenantId,
            ClientId = clientId,
            ClientSecret = clientSecret,
            IdentifierUri = identifierUri,
            PublicOrigin = section["PublicOrigin"]?.TrimEnd('/')
        };
    }

    public void ValidateIfEnabled()
    {
        if (!Enabled) return;
        if (string.IsNullOrWhiteSpace(TenantId))
            throw new InvalidOperationException("TeamsTab:TenantId or TeamsApp:TenantId is required when TeamsTab is enabled.");
        if (string.IsNullOrWhiteSpace(ClientId))
            throw new InvalidOperationException("TeamsTab:ClientId or TeamsApp:BackendAppId is required when TeamsTab is enabled.");
        if (string.IsNullOrWhiteSpace(ClientSecret))
            throw new InvalidOperationException("TeamsTab:ClientSecret or TeamsApp:BackendSecret is required when TeamsTab is enabled.");
        if (string.IsNullOrWhiteSpace(IdentifierUri))
            throw new InvalidOperationException("TeamsTab:IdentifierUri or TeamsApp:IdentifierUri is required when TeamsTab is enabled.");
        if (!Uri.TryCreate(PublicOrigin, UriKind.Absolute, out var origin) || origin.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("TeamsTab:PublicOrigin must be an absolute HTTPS origin when TeamsTab is enabled.");
    }
}
