using AgentChat.Bots;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class ThinkingStatusTests
{
    [Theory]
    [InlineData("get_weather", "Get weather")]
    [InlineData("getWeather",  "Get weather")]
    [InlineData("GetWeather",  "Get weather")]
    [InlineData("search-documents", "Search documents")]
    [InlineData("foo.bar.baz", "Foo bar baz")]
    [InlineData("a",           "A")]
    [InlineData("",            "Running tool")]
    [InlineData("__weird___name__", "Weird name")]
    public void Humanize_ProducesReadablePhrase(string input, string expected)
    {
        ThinkingStatus.Humanize(input).Should().Be(expected);
    }

    [Theory]
    [InlineData("web_search",          "🔍")]
    [InlineData("bingSearch",          "🔍")]
    [InlineData("get_calendar_events", "📅")]
    [InlineData("send_email",          "📧")]
    [InlineData("read_file",           "📄")]
    [InlineData("run_python",          "💻")]
    [InlineData("query_sql",           "🗄️")]
    [InlineData("get_weather",         "🌤️")]
    [InlineData("generate_image",      "🎨")]
    [InlineData("translate_text",      "🌐")]
    [InlineData("calculator",          "🧮")]
    [InlineData("lookup_user",         "👤")]
    [InlineData("create_github_issue", "🐙")]
    [InlineData("unknown_tool",        "🔧")]
    public void Emoji_PicksReasonableIcon(string name, string expected)
    {
        ThinkingStatus.Emoji(name).Should().Be(expected);
    }

    [Fact]
    public void ForFunctionCall_FormatsAsActivePresent()
    {
        var s = ThinkingStatus.ForFunctionCall("get_weather");
        s.Should().Be("🌤️ Get weather…");
    }

    [Fact]
    public void ForMcpCallCompleted_IncludesServerLabelAndCheck()
    {
        var s = ThinkingStatus.ForMcpCallCompleted("search_docs", "github");
        s.Should().Be("🔍 Search docs (github) ✓");
    }

    [Fact]
    public void ForMcpCallCompleted_OmitsBlankServerLabel()
    {
        var s = ThinkingStatus.ForMcpCallCompleted("search_docs", null);
        s.Should().Be("🔍 Search docs ✓");
    }

    [Fact]
    public void ForBatch_FormatsCount()
    {
        ThinkingStatus.ForBatch(3).Should().Be("🔧 Calling 3 tools…");
    }

    [Fact]
    public void Trim_RespectsMaxLengthWithEllipsis()
    {
        // Use a name that won't match any emoji rule so we control the length precisely.
        var longName = new string('x', 500);
        var s = ThinkingStatus.ForFunctionCall(longName);
        s.Length.Should().BeLessOrEqualTo(240);
        s.Should().EndWith("…");
    }
}
