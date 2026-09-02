using Microsoft.Extensions.Configuration;

namespace AgentChat.Auth;

public sealed class AdminChatAuthOptions
{
    public const string FoundryScope = "https://ai.azure.com/.default";
    public const string OpenIdConnectCallbackPath = "/signin-oidc";
    public const string SignedOutCallbackPath = "/signout-oidc-callback";

    public bool Enabled { get; init; }
    public string Instance { get; init; } = "https://login.microsoftonline.com/";
    public string? TenantId { get; init; }
    public string? ClientId { get; init; }
    public string? ClientSecret { get; init; }

    public static AdminChatAuthOptions FromConfiguration(IConfiguration config)
    {
        var section = config.GetSection("AdminChatAuth");
        return new AdminChatAuthOptions
        {
            Enabled = section.GetValue<bool?>("Enabled") ?? false,
            Instance = section["Instance"] ?? "https://login.microsoftonline.com/",
            TenantId = section["TenantId"] ?? config["TeamsApp:TenantId"] ?? config["TeamsSso:TenantId"] ?? config["AZURE_TENANT_ID"],
            ClientId = section["ClientId"] ?? config["TeamsApp:BackendAppId"] ?? config["TeamsSso:AadAppId"],
            ClientSecret = section["ClientSecret"] ?? config["TeamsApp:BackendSecret"]
        };
    }

    public void ValidateIfEnabled()
    {
        if (!Enabled) return;
        if (string.IsNullOrWhiteSpace(TenantId)) throw new InvalidOperationException("AdminChatAuth:TenantId, TeamsApp:TenantId, or AZURE_TENANT_ID is required when AdminChatAuth is enabled.");
        if (string.IsNullOrWhiteSpace(ClientId)) throw new InvalidOperationException("AdminChatAuth:ClientId or TeamsApp:BackendAppId is required when AdminChatAuth is enabled.");
        if (string.IsNullOrWhiteSpace(ClientSecret)) throw new InvalidOperationException("AdminChatAuth:ClientSecret or TeamsApp:BackendSecret is required when AdminChatAuth is enabled.");
    }
}
