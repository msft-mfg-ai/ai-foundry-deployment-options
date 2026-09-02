using AgentChat.Bots;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class UrlSafetyTests
{
    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not a url")]
    [InlineData("/relative/path")]
    [InlineData("javascript:alert(1)")]
    [InlineData("file:///etc/passwd")]
    [InlineData("http://example.com")]
    [InlineData("ftp://example.com")]
    [InlineData("data:text/html,<script>")]
    public void Rejects_invalid_or_wrong_scheme(string url)
    {
        UrlSafety.TryValidatePublicHttpsUrl(url, out _, out var reason).Should().BeFalse();
        reason.Should().NotBeNullOrEmpty();
    }

    [Theory]
    [InlineData("https://localhost/foo")]
    [InlineData("https://LocalHost/foo")]
    [InlineData("https://127.0.0.1")]
    [InlineData("https://127.0.0.1:8443/path")]
    [InlineData("https://169.254.169.254/metadata/instance")]   // Azure IMDS
    [InlineData("https://169.254.169.254")]
    public void Rejects_loopback_and_imds(string url)
    {
        UrlSafety.TryValidatePublicHttpsUrl(url, out _, out var reason).Should().BeFalse();
        reason.Should().NotBeEmpty();
    }

    [Theory]
    [InlineData("https://10.0.0.5")]
    [InlineData("https://10.255.255.255")]
    [InlineData("https://172.16.0.1")]
    [InlineData("https://172.31.255.255")]
    [InlineData("https://192.168.0.1")]
    [InlineData("https://192.168.255.255")]
    [InlineData("https://100.64.0.1")]                          // CGNAT
    [InlineData("https://100.127.255.254")]
    [InlineData("https://169.254.5.10")]                        // link-local
    [InlineData("https://0.0.0.0")]
    public void Rejects_rfc1918_and_other_private_ipv4(string url)
    {
        UrlSafety.TryValidatePublicHttpsUrl(url, out _, out _).Should().BeFalse();
    }

    [Theory]
    [InlineData("https://[::1]")]                               // IPv6 loopback
    [InlineData("https://[fe80::1]")]                           // link-local
    [InlineData("https://[fc00::1]")]                           // ULA
    [InlineData("https://[fd00::1]")]                           // ULA
    public void Rejects_ipv6_private_loopback_ula(string url)
    {
        UrlSafety.TryValidatePublicHttpsUrl(url, out _, out _).Should().BeFalse();
    }

    [Theory]
    [InlineData("https://172.15.0.1")]   // just outside RFC1918 — public
    [InlineData("https://172.32.0.1")]   // just outside RFC1918
    [InlineData("https://100.63.0.1")]   // just outside CGNAT
    [InlineData("https://100.128.0.1")]
    public void Accepts_ips_adjacent_to_private_ranges(string url)
    {
        UrlSafety.TryValidatePublicHttpsUrl(url, out var uri, out var reason).Should().BeTrue(because: reason);
        uri.Should().NotBeNull();
    }

    [Theory]
    [InlineData("https://learn.microsoft.com/en-us/azure/foundry/")]
    [InlineData("https://raw.githubusercontent.com/microsoft/typescript/main/README.md")]
    [InlineData("https://example.com/some/path?q=1")]
    [InlineData("https://api.openai.com/v1/models")]
    [InlineData("https://example.com:8443/")]
    public void Accepts_public_https_urls(string url)
    {
        UrlSafety.TryValidatePublicHttpsUrl(url, out var parsed, out var reason).Should().BeTrue(because: reason);
        parsed.Should().NotBeNull();
        parsed!.Scheme.Should().Be("https");
    }

    [Fact]
    public void Returns_parsed_uri_on_success()
    {
        UrlSafety.TryValidatePublicHttpsUrl("https://example.com/path?q=1", out var uri, out _).Should().BeTrue();
        uri.Host.Should().Be("example.com");
        uri.AbsolutePath.Should().Be("/path");
        uri.Query.Should().Be("?q=1");
    }
}

