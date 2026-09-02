using AgentChat.Auth;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class TeamsTabAuthOptionsTests
{
    [Fact]
    public void FromConfiguration_uses_shared_backend_settings()
    {
        var options = TeamsTabAuthOptions.FromConfiguration(TestServices.Config(
            Key("TeamsTab:Enabled", "true"),
            Key("TeamsTab:PublicOrigin", "https://proxy.example.com/"),
            Key("TeamsApp:TenantId", "tenant-id"),
            Key("TeamsApp:BackendAppId", "client-id"),
            Key("TeamsApp:BackendSecret", "secret"),
            Key("TeamsApp:IdentifierUri", "api://client-id/access_as_user")));

        options.Enabled.Should().BeTrue();
        options.TenantId.Should().Be("tenant-id");
        options.ClientId.Should().Be("client-id");
        options.NormalizedAudience.Should().Be("api://client-id");
        options.ApiScope.Should().Be("api://client-id/access_as_user");
        options.PublicOrigin.Should().Be("https://proxy.example.com");
    }

    [Fact]
    public void ValidateIfEnabled_rejects_non_https_public_origin()
    {
        var options = TeamsTabAuthOptions.FromConfiguration(TestServices.Config(
            Key("TeamsTab:Enabled", "true"),
            Key("TeamsTab:PublicOrigin", "http://proxy.example.com"),
            Key("TeamsApp:TenantId", "tenant-id"),
            Key("TeamsApp:BackendAppId", "client-id"),
            Key("TeamsApp:BackendSecret", "secret"),
            Key("TeamsApp:IdentifierUri", "api://client-id")));

        var act = options.ValidateIfEnabled;

        act.Should().Throw<InvalidOperationException>().WithMessage("*HTTPS*");
    }

    private static KeyValuePair<string, string?> Key(string key, string value) => new(key, value);
}
