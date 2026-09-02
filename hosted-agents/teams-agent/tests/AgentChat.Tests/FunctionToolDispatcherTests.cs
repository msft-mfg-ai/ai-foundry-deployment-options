using AgentChat.Bots;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class FunctionToolDispatcherTests
{
    [Fact]
    public async Task get_current_time_returns_iso_utc_timestamp()
    {
        var result = await FunctionToolDispatcher.ExecuteAsync("get_current_time", "{}");
        var doc = System.Text.Json.JsonDocument.Parse(result);
        var utc = doc.RootElement.GetProperty("utc").GetString();
        utc.Should().NotBeNullOrEmpty();
        DateTimeOffset.Parse(utc!).Should().BeCloseTo(DateTimeOffset.UtcNow, TimeSpan.FromSeconds(5));
    }

    [Theory]
    [InlineData("2+2",         "4")]
    [InlineData("10 * 3",      "30")]
    [InlineData("100 / 4",     "25")]
    [InlineData("2 * (3 + 5)", "16")]
    public async Task calculate_evaluates_simple_arithmetic(string expression, string expected)
    {
        var args = System.Text.Json.JsonSerializer.Serialize(new { expression });
        var result = await FunctionToolDispatcher.ExecuteAsync("calculate", args);
        var doc = System.Text.Json.JsonDocument.Parse(result);
        doc.RootElement.GetProperty("result").GetString().Should().Be(expected);
    }

    [Fact]
    public async Task calculate_returns_error_on_invalid_expression()
    {
        var args = System.Text.Json.JsonSerializer.Serialize(new { expression = "not a math expression" });
        var result = await FunctionToolDispatcher.ExecuteAsync("calculate", args);
        var doc = System.Text.Json.JsonDocument.Parse(result);
        doc.RootElement.TryGetProperty("error", out var err).Should().BeTrue();
        err.GetString().Should().NotBeNullOrEmpty();
    }

    [Fact]
    public async Task calculate_returns_error_on_malformed_arguments_json()
    {
        var result = await FunctionToolDispatcher.ExecuteAsync("calculate", "not json");
        var doc = System.Text.Json.JsonDocument.Parse(result);
        doc.RootElement.TryGetProperty("error", out _).Should().BeTrue();
    }

    [Fact]
    public async Task calculate_returns_error_when_expression_property_missing()
    {
        var result = await FunctionToolDispatcher.ExecuteAsync("calculate", "{}");
        var doc = System.Text.Json.JsonDocument.Parse(result);
        doc.RootElement.TryGetProperty("error", out _).Should().BeTrue();
    }

    [Fact]
    public async Task unknown_function_returns_error_payload()
    {
        var result = await FunctionToolDispatcher.ExecuteAsync("nonexistent_tool", "{}");
        var doc = System.Text.Json.JsonDocument.Parse(result);
        doc.RootElement.GetProperty("error").GetString().Should().Contain("nonexistent_tool");
    }

    [Fact]
    public async Task all_results_are_valid_json()
    {
        // Foundry expects ToolOutput.Output to be a string the model can read.
        // JSON works as a serialization format. Verify we always return valid JSON.
        var inputs = new[]
        {
            ("get_current_time", "{}"),
            ("calculate",        "{\"expression\":\"1+1\"}"),
            ("calculate",        "{}"),
            ("calculate",        "not json"),
            ("missing",          "{}")
        };

        foreach (var (name, args) in inputs)
        {
            var result = await FunctionToolDispatcher.ExecuteAsync(name, args);
            var act = () => System.Text.Json.JsonDocument.Parse(result);
            act.Should().NotThrow(because: $"output for ({name}, {args}) must parse as JSON; got: {result}");
        }
    }
}
