using AgentChat.Services;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class DebugValueRedactorTests
{
    [Theory]
    [InlineData("Authorization", "Bearer abc.def.ghi")]
    [InlineData("IDENTITY_HEADER", "platform-secret")]
    [InlineData("DATABASE_PASSWORD", "password")]
    [InlineData("APPLICATIONINSIGHTS_CONNECTION_STRING", "InstrumentationKey=value")]
    [InlineData("x-api-key", "api-key-value")]
    public void Sensitive_names_are_redacted(string name, string value)
        => DebugValueRedactor.SafeValue(name, value).Should().Be("[REDACTED]");

    [Fact]
    public void Jwt_values_are_redacted_even_with_safe_names()
        => DebugValueRedactor.SafeValue(
                "x-client-context",
                "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturevalue")
            .Should()
            .Be("[REDACTED]");

    [Theory]
    [InlineData("AZURE_CLIENT_ID", "2a36ef0d-f19b-4706-957b-b9fe76ffa7e7")]
    [InlineData("FOUNDRY_PROJECT_ENDPOINT", "https://foundry.example/api/projects/project-a")]
    [InlineData("x-client-agent-version", "11")]
    public void Operational_values_remain_visible(string name, string value)
        => DebugValueRedactor.SafeValue(name, value).Should().Be(value);
}
