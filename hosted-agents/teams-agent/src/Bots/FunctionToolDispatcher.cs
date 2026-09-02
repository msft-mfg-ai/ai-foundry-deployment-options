using System.Data;
using System.Text.Json;

namespace AgentChat.Bots;

/// <summary>
/// Pure dispatcher for developer-defined function tools the agent can call.
/// Returns a JSON-serializable string (matching what Foundry expects for
/// ToolOutput.Output) — no Bot Framework / Foundry SDK dependencies, so
/// it's trivially testable in isolation.
/// </summary>
public static class FunctionToolDispatcher
{
    public static Task<string> ExecuteAsync(string name, string arguments, CancellationToken ct = default)
    {
        switch (name)
        {
            case "get_current_time":
                return Task.FromResult(JsonSerializer.Serialize(new { utc = DateTime.UtcNow.ToString("O") }));

            case "calculate":
                return Task.FromResult(Calculate(arguments));

            default:
                return Task.FromResult(JsonSerializer.Serialize(new { error = $"unknown function {name}" }));
        }
    }

    private static string Calculate(string arguments)
    {
        try
        {
            using var doc = JsonDocument.Parse(arguments);
            var expr = doc.RootElement.GetProperty("expression").GetString() ?? "";

            // DataTable.Compute supports a safe subset of arithmetic operations.
            // It's not Turing-complete and doesn't allow arbitrary code execution,
            // but the input is trusted (only the LLM can invoke this).
            var dt = new DataTable();
            var val = dt.Compute(expr, "");
            return JsonSerializer.Serialize(new { expression = expr, result = val?.ToString() });
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = ex.Message });
        }
    }
}
