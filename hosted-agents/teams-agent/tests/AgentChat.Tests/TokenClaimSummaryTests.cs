using System.Text;
using AgentChat.Services;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class TokenClaimSummaryTests
{
    [Fact]
    public void ToToolResult_ExposesOnlyAllowedClaims()
    {
        const string rawToken = "secret-token-material";
        var token = Jwt(
            """
            {
              "aud": "api://cloud-helper",
              "oid": "user-object-id",
              "name": "Adele",
              "scp": "user_impersonation",
              "exp": 1900000000,
              "aio": "internal-value",
              "nonce": "sensitive-value"
            }
            """,
            rawToken);

        var result = TokenClaimSummary.ToToolResult(token);

        result.Should().Contain("\"authenticated\": true");
        result.Should().Contain("\"tokenIncluded\": false");
        result.Should().Contain("api://cloud-helper");
        result.Should().Contain("user-object-id");
        result.Should().Contain("Adele");
        result.Should().Contain("user_impersonation");
        result.Should().NotContain("internal-value");
        result.Should().NotContain("sensitive-value");
        result.Should().NotContain(rawToken);
    }

    [Fact]
    public void Read_RejectsNonJwtTokens()
    {
        var action = () => TokenClaimSummary.Read("opaque-token");

        action.Should()
            .Throw<InvalidDataException>()
            .WithMessage("*non-JWT*");
    }

    private static string Jwt(
        string payload,
        string signature)
        => $"{Encode("""{"alg":"none"}""")}.{Encode(payload)}.{signature}";

    private static string Encode(string value)
        => Convert.ToBase64String(
                Encoding.UTF8.GetBytes(value))
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
}
