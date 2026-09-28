using System.Text.Json;
using AgentChat.Bots;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class FoundryBotSsoPayloadTests
{
    [Fact]
    public void TokenExchangeJsonElementPreservesProtocolFields()
    {
        var value = JsonSerializer.SerializeToElement(new
        {
            id = "exchange-id",
            token = "teams-token",
            connectionName = "teams-sso",
        });

        var payload = FoundryBot.ToJObject(value);

        payload.Value<string>("id").Should().Be("exchange-id");
        payload.Value<string>("token").Should().Be("teams-token");
        payload.Value<string>("connectionName").Should().Be("teams-sso");
    }

    [Fact]
    public void VerifyStateJsonElementPreservesMagicCode()
    {
        var value = JsonSerializer.SerializeToElement(new
        {
            state = "123456",
        });

        var payload = FoundryBot.ToJObject(value);

        payload.Value<string>("state").Should().Be("123456");
    }

    [Fact]
    public void SignInFailureJsonElementPreservesFailureCode()
    {
        var value = JsonSerializer.SerializeToElement(new
        {
            code = "invokeerror",
            message = "Sign-in failed",
        });

        var payload = FoundryBot.ToJObject(value);

        payload.Value<string>("code").Should().Be("invokeerror");
        payload.Value<string>("message").Should().Be("Sign-in failed");
    }
}
