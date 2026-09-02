using Newtonsoft.Json.Linq;

namespace AgentChat.Bots;

/// <summary>
/// Pure helpers for building a Teams app manifest JSON for a given Foundry
/// agent + bot id. Extracted from ManifestController so it can be unit-tested
/// without HTTP context.
/// </summary>
public static class ManifestBuilder
{
    public const string SchemaUrl       = "https://developer.microsoft.com/json-schemas/teams/v1.17/MicrosoftTeams.schema.json";
    public const string ManifestVersion = "1.17";
    public const string AppVersion      = "1.0.0";

    public const int MaxShortNameChars = 30;
    public const int MaxFullNameChars  = 100;
    public const int MaxShortDescChars = 80;
    public const int MaxFullDescChars  = 4000;

    // Teams caps bot.commandLists at 10 commands. Order = user-facing priority.
    // Every entry must map to a real handler in FoundryBot.HandleCommandAsync.
    // /reset is intentionally omitted — /new is the alias and both still work
    // if typed.
    private static readonly (string title, string description)[] DefaultCommands =
    {
        ("/agents",   "Pick a Foundry agent"),
        ("/agent",    "Show active agent + project info"),
        ("/new",      "Start a fresh thread (alias: /reset)"),
        ("/tokens",   "Show token usage for this conversation"),
        ("/tools",    "Show or hide tool-call cards (on/off)"),
        ("/thinking", "Show or hide live thinking status (on/off)"),
        ("/debug",    "Show redacted runtime and request diagnostics"),
        ("/stop",     "Cancel the running turn"),
        ("/signout",  "Sign out (clears cached Teams SSO token)"),
        ("/help",     "List commands")
    };

    public static JObject Build(
        string agentName,
        string agentDescription,
        string botId,
        Guid? manifestId = null,
        string? ssoAadAppId = null,
        string? ssoResource = null,
        string? tabContentUrl = null)
    {
        if (string.IsNullOrWhiteSpace(agentName))
            throw new ArgumentException("agentName is required", nameof(agentName));
        if (string.IsNullOrWhiteSpace(botId))
            throw new ArgumentException("botId is required", nameof(botId));

        var shortDesc = string.IsNullOrEmpty(agentDescription)
            ? $"Foundry agent: {agentName}"
            : agentDescription;
        if (shortDesc.Length > MaxShortDescChars)
            shortDesc = shortDesc.Substring(0, MaxShortDescChars - 3) + "...";

        var fullDesc = string.IsNullOrEmpty(agentDescription)
            ? $"Chat with the Foundry agent '{agentName}'. Switch agents at any time with /agents."
            : agentDescription;
        if (fullDesc.Length > MaxFullDescChars)
            fullDesc = fullDesc.Substring(0, MaxFullDescChars);

        var nameShort = agentName.Length > MaxShortNameChars
            ? agentName.Substring(0, MaxShortNameChars)
            : agentName;
        var nameFull  = $"Foundry: {agentName}";
        if (nameFull.Length > MaxFullNameChars)
            nameFull = nameFull.Substring(0, MaxFullNameChars);

        var botBlock = new JObject
        {
            ["botId"]              = botId,
            ["scopes"]             = new JArray("personal", "team", "groupChat"),
            ["supportsFiles"]      = false,
            ["isNotificationOnly"] = false,
            ["commandLists"] = new JArray
            {
                new JObject
                {
                    ["scopes"]   = new JArray("personal", "team", "groupChat"),
                    ["commands"] = new JArray(DefaultCommands.Select(c => new JObject
                    {
                        ["title"]       = c.title,
                        ["description"] = c.description
                    }))
                }
            }
        };

        var manifest = new JObject
        {
            ["$schema"]         = SchemaUrl,
            ["manifestVersion"] = ManifestVersion,
            ["version"]         = AppVersion,
            ["id"]              = (manifestId ?? Guid.NewGuid()).ToString(),
            ["developer"] = new JObject
            {
                ["name"]          = "Foundry POC",
                ["websiteUrl"]    = "https://www.example.com",
                ["privacyUrl"]    = "https://www.example.com/privacy",
                ["termsOfUseUrl"] = "https://www.example.com/terms"
            },
            ["icons"]       = new JObject { ["color"] = "color.png", ["outline"] = "outline.png" },
            ["name"]        = new JObject { ["short"] = nameShort, ["full"] = nameFull },
            ["description"] = new JObject { ["short"] = shortDesc, ["full"] = fullDesc },
            ["accentColor"] = "#5B67D1",
            ["bots"]        = new JArray { botBlock },
            ["validDomains"] = new JArray()
        };

        // Teams SSO wiring — Teams uses webApplicationInfo to attempt silent
        // SSO against the bot's AAD app. Required for OAuth identity
        // passthrough to MCP servers without an extra sign-in click.
        if (!string.IsNullOrEmpty(ssoAadAppId))
        {
            var webAppInfo = new JObject { ["id"] = ssoAadAppId };
            if (!string.IsNullOrEmpty(ssoResource))
                webAppInfo["resource"] = ssoResource;
            manifest["webApplicationInfo"] = webAppInfo;
            manifest["validDomains"] = new JArray("token.botframework.com", "*.botframework.com");
            manifest["permissions"] = new JArray("identity", "messageTeamMembers");
        }

        if (!string.IsNullOrWhiteSpace(tabContentUrl))
        {
            if (!Uri.TryCreate(tabContentUrl, UriKind.Absolute, out var tabUri)
                || tabUri.Scheme != Uri.UriSchemeHttps)
                throw new ArgumentException("tabContentUrl must be an absolute HTTPS URL", nameof(tabContentUrl));

            manifest["staticTabs"] = new JArray
            {
                new JObject
                {
                    ["entityId"] = "foundry-agent-chat",
                    ["name"] = "Chat",
                    ["contentUrl"] = tabUri.AbsoluteUri,
                    ["websiteUrl"] = tabUri.AbsoluteUri,
                    ["scopes"] = new JArray("personal")
                }
            };

            var validDomains = (JArray)manifest["validDomains"]!;
            if (!validDomains.Any(domain =>
                    string.Equals(domain.ToString(), tabUri.Host, StringComparison.OrdinalIgnoreCase)))
            {
                validDomains.Add(tabUri.Host);
            }
        }

        return manifest;
    }

    public static JObject BuildTab(
        string agentName,
        string agentDescription,
        string tabContentUrl,
        string ssoAadAppId,
        string ssoResource,
        Guid? manifestId = null)
    {
        if (string.IsNullOrWhiteSpace(agentName))
            throw new ArgumentException("agentName is required", nameof(agentName));
        if (!Uri.TryCreate(tabContentUrl, UriKind.Absolute, out var tabUri)
            || tabUri.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException("tabContentUrl must be an absolute HTTPS URL", nameof(tabContentUrl));
        if (string.IsNullOrWhiteSpace(ssoAadAppId))
            throw new ArgumentException("ssoAadAppId is required", nameof(ssoAadAppId));
        if (string.IsNullOrWhiteSpace(ssoResource))
            throw new ArgumentException("ssoResource is required", nameof(ssoResource));

        var shortDescription = string.IsNullOrWhiteSpace(agentDescription)
            ? $"Chat with Foundry agent {agentName}"
            : agentDescription;
        if (shortDescription.Length > MaxShortDescChars)
            shortDescription = shortDescription[..(MaxShortDescChars - 3)] + "...";

        var fullDescription = string.IsNullOrWhiteSpace(agentDescription)
            ? $"Chat with the Foundry agent '{agentName}' in a Teams personal tab."
            : agentDescription;
        if (fullDescription.Length > MaxFullDescChars)
            fullDescription = fullDescription[..MaxFullDescChars];

        var shortName = agentName.Length > MaxShortNameChars
            ? agentName[..MaxShortNameChars]
            : agentName;
        var fullName = $"Foundry: {agentName}";
        if (fullName.Length > MaxFullNameChars)
            fullName = fullName[..MaxFullNameChars];

        return new JObject
        {
            ["$schema"] = SchemaUrl,
            ["manifestVersion"] = ManifestVersion,
            ["version"] = AppVersion,
            ["id"] = (manifestId ?? Guid.NewGuid()).ToString(),
            ["developer"] = new JObject
            {
                ["name"] = "Foundry POC",
                ["websiteUrl"] = "https://www.example.com",
                ["privacyUrl"] = "https://www.example.com/privacy",
                ["termsOfUseUrl"] = "https://www.example.com/terms"
            },
            ["icons"] = new JObject { ["color"] = "color.png", ["outline"] = "outline.png" },
            ["name"] = new JObject { ["short"] = shortName, ["full"] = fullName },
            ["description"] = new JObject
            {
                ["short"] = shortDescription,
                ["full"] = fullDescription
            },
            ["accentColor"] = "#5B67D1",
            ["staticTabs"] = new JArray
            {
                new JObject
                {
                    ["entityId"] = "foundry-agent-chat",
                    ["name"] = "Chat",
                    ["contentUrl"] = tabUri.AbsoluteUri,
                    ["websiteUrl"] = tabUri.AbsoluteUri,
                    ["scopes"] = new JArray("personal")
                }
            },
            ["validDomains"] = new JArray(tabUri.Host),
            ["permissions"] = new JArray("identity"),
            ["webApplicationInfo"] = new JObject
            {
                ["id"] = ssoAadAppId,
                ["resource"] = ssoResource
            }
        };
    }

    /// <summary>
    /// Turn an arbitrary agent name into a filename-safe slug for the zip download.
    /// </summary>
    public static string SanitizeForFilename(string s)
    {
        if (string.IsNullOrEmpty(s)) return "agent";
        var chars = s.Select(c => char.IsLetterOrDigit(c) || c == '-' || c == '_' ? c : '_').ToArray();
        var result = new string(chars).Trim('_');
        return string.IsNullOrEmpty(result) ? "agent" : result;
    }
}
