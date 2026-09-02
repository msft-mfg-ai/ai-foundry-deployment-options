using AgentChat.Bots;
using FluentAssertions;
using OpenAI.Responses;
using Xunit;

namespace AgentChat.Tests;

/// <summary>
/// Renderer rewrites OpenAI Responses message annotations (url_citation,
/// file_citation, container_file_citation, file_path) using each annotation's
/// character index range so the rendered text is markdown-friendly.
/// </summary>
public class AgentMessageRendererTests
{
    [Fact]
    public void ApplyAnnotations_returns_text_unchanged_when_no_annotations()
    {
        var text = "Hello world.";
        AgentMessageRenderer.ApplyAnnotations(text, Array.Empty<ResponseMessageAnnotation>()).Should().Be(text);
    }

    [Fact]
    public void ApplyAnnotations_handles_empty_text()
    {
        AgentMessageRenderer.ApplyAnnotations("", Array.Empty<ResponseMessageAnnotation>()).Should().Be("");
    }

    [Fact]
    public void ApplyAnnotations_rewrites_uri_citation_to_markdown_link()
    {
        var text = "see this【1†source】end";
        var marker = "【1†source】";
        var start = text.IndexOf(marker);
        var end   = start + marker.Length;
        var ann = new UriCitationMessageAnnotation(new Uri("https://learn.microsoft.com/test"), start, end, "Test docs");

        var rendered = AgentMessageRenderer.ApplyAnnotations(text, new[] { ann });

        rendered.Should().Contain("[[Test docs]](https://learn.microsoft.com/test)");
        rendered.Should().NotContain(marker);
    }

    [Fact]
    public void ApplyAnnotations_uses_fallback_title_when_uri_citation_title_empty()
    {
        var text = "Cite [?]";
        var ann = new UriCitationMessageAnnotation(new Uri("https://example.com"), text.IndexOf("[?]"), text.Length, "");

        var rendered = AgentMessageRenderer.ApplyAnnotations(text, new[] { ann });

        rendered.Should().Contain("[[source]](https://example.com/)");
    }

    [Fact]
    public void ApplyAnnotations_handles_multiple_uri_citations_in_descending_order()
    {
        var text = "see [1] and [2] end";
        var a1Start = text.IndexOf("[1]");
        var a2Start = text.IndexOf("[2]");

        var ann1 = new UriCitationMessageAnnotation(new Uri("https://a.com"), a1Start, a1Start + 3, "A");
        var ann2 = new UriCitationMessageAnnotation(new Uri("https://b.com"), a2Start, a2Start + 3, "B");

        var rendered = AgentMessageRenderer.ApplyAnnotations(text, new[] { ann1, ann2 });

        rendered.Should().Contain("[[A]](https://a.com/)");
        rendered.Should().Contain("[[B]](https://b.com/)");
        rendered.Should().NotContain("[1]");
        rendered.Should().NotContain("[2]");
    }

    [Fact]
    public void ApplyAnnotations_ignores_out_of_range_indices()
    {
        var text = "short";
        var ann = new UriCitationMessageAnnotation(new Uri("https://x.com"), 100, 200, "X");
        AgentMessageRenderer.ApplyAnnotations(text, new[] { ann }).Should().Be(text);
    }

    [Fact]
    public void TextAsFile_produces_valid_data_url_attachment()
    {
        var att = AgentMessageRenderer.TextAsFile("notes.txt", "hello world");

        att.Name.Should().Be("notes.txt");
        att.ContentType.Should().Be("text/plain");
        att.ContentUrl.Should().StartWith("data:text/plain;base64,");

        var base64 = att.ContentUrl!.Split(',')[1];
        var bytes = Convert.FromBase64String(base64);
        System.Text.Encoding.UTF8.GetString(bytes).Should().Be("hello world");
    }

    [Theory]
    [InlineData("image.png")]
    [InlineData("file.bin")]
    [InlineData("noext")]
    public void TextAsFile_always_uses_text_plain(string filename)
    {
        var att = AgentMessageRenderer.TextAsFile(filename, "x");
        att.ContentType.Should().Be("text/plain");
    }
}
