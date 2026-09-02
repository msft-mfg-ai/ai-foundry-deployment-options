using AgentChat.Bots;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class GeneratedFileLinkParserTests
{
    [Fact]
    public void Extract_finds_powerpoint_download_link()
    {
        var files = GeneratedFileLinkParser.Extract(
            "Your deck is ready. [Download the PowerPoint](https://files.example.com/output/deck.pptx?sig=abc)");

        files.Should().ContainSingle();
        files[0].Name.Should().Be("deck.pptx");
        files[0].Url.Should().Be("https://files.example.com/output/deck.pptx?sig=abc");
    }

    [Fact]
    public void Extract_infers_powerpoint_name_for_extensionless_download_url()
    {
        var files = GeneratedFileLinkParser.Extract(
            "[Download the PowerPoint](https://files.example.com/download?id=123)");

        files.Should().ContainSingle();
        files[0].Name.Should().Be("presentation.pptx");
    }

    [Fact]
    public void Extract_ignores_ordinary_web_links()
    {
        GeneratedFileLinkParser.Extract(
            "[Microsoft](https://www.microsoft.com/)").Should().BeEmpty();
    }
}
