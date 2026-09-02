using AgentChat.Bots;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class ConsentLinkParserTests
{
    [Fact]
    public void ExtractConsentUrl_returns_clean_url_unchanged()
    {
        ConsentLinkParser.ExtractConsentUrl("https://consent.example/login?data=abc")
            .Should().Be("https://consent.example/login?data=abc");
    }

    [Fact]
    public void ExtractConsentUrl_extracts_url_from_prose_prefix()
    {
        ConsentLinkParser.ExtractConsentUrl("OAuth consent required. Please visit: https://consent.example/login?data=xyz")
            .Should().Be("https://consent.example/login?data=xyz");
    }

    [Fact]
    public void ExtractConsentUrl_returns_null_when_no_url_exists()
    {
        ConsentLinkParser.ExtractConsentUrl("OAuth consent required but no link was provided")
            .Should().BeNull();
    }

    [Fact]
    public void ExtractConsentUrl_uses_first_url_when_multiple_are_present()
    {
        ConsentLinkParser.ExtractConsentUrl("Open https://first.example/login then ignore https://second.example/login")
            .Should().Be("https://first.example/login");
    }

    [Theory]
    [InlineData("https://consent.example/login.", "https://consent.example/login")]
    [InlineData("https://consent.example/login,", "https://consent.example/login")]
    [InlineData("(https://consent.example/login)", "https://consent.example/login")]
    [InlineData("[https://consent.example/login]", "https://consent.example/login")]
    public void ExtractConsentUrl_strips_trailing_punctuation(string raw, string expected)
    {
        ConsentLinkParser.ExtractConsentUrl(raw).Should().Be(expected);
    }
}
