using AgentChat.Services;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using System.Text.Json;

namespace AgentChat.Bots;

internal sealed class AgentProgressMapper
{
    private const string LoadSkillTool = "load_skill";
    private const string ReadSkillResourceTool = "read_skill_resource";
    private readonly List<AgentTodoProgressState> _todos;
    private readonly Dictionary<string, List<AgentTodoProgressState>>
        _pendingTodoAdds =
        new(StringComparer.Ordinal);
    private readonly Dictionary<string, string[]> _pendingTodoCompletions =
        new(StringComparer.Ordinal);

    public AgentProgressMapper(
        List<AgentTodoProgressState>? persistedTodos = null)
    {
        _todos = persistedTodos ?? [];
    }

    public string? GetProgress(AgentResponseUpdate update)
    {
        foreach (var content in update.Contents)
        {
            var progress = content switch
            {
                FunctionCallContent call => FromFunctionCall(call),
                McpServerToolCallContent call => FromToolName(call.Name),
                WebSearchToolCallContent => "Researching content...",
                ImageGenerationToolCallContent => "Creating visual assets...",
                CodeInterpreterToolCallContent => "Working in the analysis workspace...",
                FunctionResultContent result => FromFunctionResult(result),
                WebSearchToolResultContent => "Research complete; reviewing sources...",
                ImageGenerationToolResultContent => "Visual asset created; preparing it...",
                CodeInterpreterToolResultContent => "Analysis workspace step completed...",
                McpServerToolResultContent => "Tool completed; reviewing the result...",
                ToolResultContent => "Tool completed; reviewing the result...",
                AgentProgressContent progressContent => FromProgressStage(
                    progressContent.Stage),
                _ => null,
            };

            if (progress is not null)
            {
                return progress;
            }
        }

        return null;
    }

    private string FromFunctionCall(FunctionCallContent call)
    {
        if (string.Equals(
                call.Name,
                "inspect_teams_sso_token",
                StringComparison.Ordinal))
        {
            return "Starting Teams sign-in...";
        }
        if (string.Equals(
                call.Name,
                "get_my_graph_profile",
                StringComparison.Ordinal))
        {
            return "Getting your Microsoft Graph profile...";
        }
        if (string.Equals(
                call.Name,
                "inspect_my_mcp_access",
                StringComparison.Ordinal))
        {
            return "Checking your delegated MCP access...";
        }

        if (call.Name is LoadSkillTool or ReadSkillResourceTool)
        {
            return FromSkillArguments(call.Arguments);
        }

        if (string.Equals(call.Name, "code", StringComparison.Ordinal))
        {
            return FromCode(call.Arguments);
        }
        if (string.Equals(
                call.Name,
                "todos_add",
                StringComparison.Ordinal))
        {
            return AddTodos(call.CallId, call.Arguments);
        }
        if (string.Equals(
                call.Name,
                "todos_complete",
                StringComparison.Ordinal))
        {
            _pendingTodoCompletions[call.CallId] =
                call.Arguments?.Values
                    .SelectMany(ExtractTodoIds)
                    .ToArray()
                ?? [];
            return "Updating the plan...";
        }
        if (string.Equals(
                call.Name,
                "generate_image",
                StringComparison.Ordinal))
        {
            return "Generating an image...";
        }
        if (string.Equals(
                call.Name,
                "return_file",
                StringComparison.Ordinal))
        {
            return "Selecting the final file to return...";
        }

        return FromToolName(call.Name);
    }

    private string FromFunctionResult(FunctionResultContent result)
    {
        if (_pendingTodoAdds.Remove(result.CallId, out var addedTodos))
        {
            if (result.Exception is not null)
            {
                foreach (var todo in addedTodos)
                {
                    _todos.Remove(todo);
                }
                return "Plan update returned an issue; continuing...";
            }

            var createdTodos = ExtractCreatedTodos(result.Result).ToArray();
            for (var index = 0; index < createdTodos.Length; index++)
            {
                if (index >= addedTodos.Count)
                {
                    var additionalTodo = new AgentTodoProgressState
                    {
                        Title = SanitizeTodoTitle(createdTodos[index].Title),
                    };
                    _todos.Add(additionalTodo);
                    addedTodos.Add(additionalTodo);
                }
                addedTodos[index].Id = createdTodos[index].Id;
                addedTodos[index].Title =
                    SanitizeTodoTitle(createdTodos[index].Title);
            }
            return RenderPlan();
        }

        if (!_pendingTodoCompletions.Remove(
                result.CallId,
                out var completedIds))
        {
            return result.Exception is null
                ? "Tool completed; reviewing the result..."
                : "Tool returned an issue; continuing with another approach...";
        }

        if (result.Exception is not null
            || !TryGetCompletedCount(result.Result, out var completedCount)
            || completedCount <= 0)
        {
            return result.Exception is null
                ? "Plan unchanged; continuing with the remaining steps..."
                : "Plan update returned an issue; continuing...";
        }

        var remaining = completedCount;
        foreach (var completedId in completedIds)
        {
            var todo = _todos.FirstOrDefault(item =>
                !item.Completed
                && string.Equals(
                    item.Id,
                    completedId,
                    StringComparison.Ordinal));
            if (todo is null)
            {
                continue;
            }

            todo.Completed = true;
            if (--remaining == 0)
            {
                break;
            }
        }

        return RenderPlan();
    }

    private string AddTodos(
        string callId,
        IDictionary<string, object?>? arguments)
    {
        var titles = arguments?.Values
            .SelectMany(ExtractTodoTitles)
            .Select(SanitizeTodoTitle)
            .Where(title => title.Length > 0)
            .Take(6)
            .ToArray() ?? [];
        if (_pendingTodoAdds.TryGetValue(callId, out var pendingTodos))
        {
            for (var index = 0; index < titles.Length; index++)
            {
                if (index < pendingTodos.Count)
                {
                    pendingTodos[index].Title = titles[index];
                    continue;
                }
                if (_todos.Count >= 6)
                {
                    break;
                }

                var additionalTodo = new AgentTodoProgressState
                {
                    Title = titles[index],
                };
                _todos.Add(additionalTodo);
                pendingTodos.Add(additionalTodo);
            }
            return RenderPlan();
        }

        var newTodos = titles
            .Take(Math.Max(0, 6 - _todos.Count))
            .Select(title => new AgentTodoProgressState
            {
                Title = title,
            })
            .ToList();
        if (newTodos.Count == 0)
        {
            return _todos.Count == 0
                ? "Planning the work..."
                : RenderPlan();
        }

        _todos.AddRange(newTodos);
        _pendingTodoAdds[callId] = newTodos;
        return RenderPlan();
    }

    private string RenderPlan()
        => "Plan:\n"
            + string.Join(
                "\n",
                _todos.Take(6).Select((item, index) =>
                    $"{index + 1}. {item.Title} ({(item.Completed ? "done" : "pending")})"));

    private static IEnumerable<string> ExtractTodoTitles(object? value)
    {
        if (value is JsonElement element)
        {
            if (element.ValueKind == JsonValueKind.Array)
            {
                return element.EnumerateArray()
                    .SelectMany(item => ExtractTodoTitles(item));
            }
            if (element.ValueKind == JsonValueKind.Object
                && TryGetJsonString(element, "title", out var jsonTitle))
            {
                return [jsonTitle];
            }
            return [];
        }

        if (value is IDictionary<string, object?> dictionary)
        {
            var title = GetDictionaryString(dictionary, "title");
            return title is not null
                ? [title]
                : [];
        }
        if (value is IEnumerable<KeyValuePair<string, object?>> pairs)
        {
            var title = GetPairString(pairs, "title");
            return title is not null
                ? [title]
                : [];
        }
        if (value is IEnumerable<object?> values)
        {
            return values.SelectMany(ExtractTodoTitles);
        }

        var titleProperty = value?.GetType().GetProperty("Title");
        return titleProperty?.GetValue(value) is string reflectedTitle
            ? [reflectedTitle]
            : [];
    }

    private static IEnumerable<(string Id, string Title)> ExtractCreatedTodos(
        object? value)
    {
        if (value is null)
        {
            return [];
        }

        JsonElement element;
        try
        {
            element = value is JsonElement jsonElement
                ? jsonElement
                : JsonSerializer.SerializeToElement(value);
        }
        catch (NotSupportedException)
        {
            return [];
        }

        return ExtractCreatedTodos(element);
    }

    private static IEnumerable<(string Id, string Title)> ExtractCreatedTodos(
        JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Array)
        {
            return element.EnumerateArray().SelectMany(ExtractCreatedTodos);
        }
        if (element.ValueKind != JsonValueKind.Object
            || !TryGetJsonId(element, out var id)
            || !TryGetJsonString(element, "title", out var title))
        {
            return [];
        }

        return [(id, title)];
    }

    private static IEnumerable<string> ExtractTodoIds(object? value)
    {
        if (value is JsonElement element)
        {
            if (element.ValueKind == JsonValueKind.Array)
            {
                return element.EnumerateArray()
                    .SelectMany(item => ExtractTodoIds(item));
            }
            return element.ValueKind == JsonValueKind.Object
                && TryGetJsonId(element, out var jsonId)
                ? [jsonId]
                : [];
        }
        if (value is IDictionary<string, object?> dictionary)
        {
            return GetPairId(dictionary) is { } dictionaryId
                ? [dictionaryId]
                : [];
        }
        if (value is IEnumerable<KeyValuePair<string, object?>> pairs)
        {
            return GetPairId(pairs) is { } dictionaryId
                ? [dictionaryId]
                : [];
        }
        if (value is IEnumerable<object?> values)
        {
            return values.SelectMany(ExtractTodoIds);
        }

        return value?.GetType().GetProperty("Id")?.GetValue(value)
            is string reflectedId
            ? [reflectedId]
            : [];
    }

    private static bool TryGetCompletedCount(object? value, out int count)
    {
        if (value is int integer)
        {
            count = integer;
            return true;
        }
        if (value is long longInteger
            && longInteger is >= int.MinValue and <= int.MaxValue)
        {
            count = (int)longInteger;
            return true;
        }
        if (value is JsonElement element
            && element.ValueKind == JsonValueKind.Number
            && element.TryGetInt32(out count))
        {
            return true;
        }
        return int.TryParse(value?.ToString(), out count);
    }

    private static bool TryGetJsonString(
        JsonElement element,
        string propertyName,
        out string value)
    {
        foreach (var property in element.EnumerateObject())
        {
            if (string.Equals(
                    property.Name,
                    propertyName,
                    StringComparison.OrdinalIgnoreCase)
                && property.Value.ValueKind == JsonValueKind.String)
            {
                value = property.Value.GetString()!;
                return true;
            }
        }

        value = "";
        return false;
    }

    private static bool TryGetJsonId(
        JsonElement element,
        out string value)
    {
        foreach (var property in element.EnumerateObject())
        {
            if (!string.Equals(
                    property.Name,
                    "id",
                    StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (property.Value.ValueKind == JsonValueKind.String)
            {
                value = property.Value.GetString()!;
                return true;
            }
            if (property.Value.ValueKind == JsonValueKind.Number)
            {
                value = property.Value.GetRawText();
                return true;
            }
        }

        value = "";
        return false;
    }

    private static string? GetDictionaryString(
        IDictionary<string, object?> dictionary,
        string key)
        => GetPairString(dictionary, key);

    private static string? GetPairString(
        IEnumerable<KeyValuePair<string, object?>> pairs,
        string key)
        => pairs.FirstOrDefault(pair =>
                string.Equals(
                    pair.Key,
                    key,
                    StringComparison.OrdinalIgnoreCase))
            .Value as string;

    private static string? GetPairId(
        IEnumerable<KeyValuePair<string, object?>> pairs)
    {
        var value = pairs.FirstOrDefault(pair =>
                string.Equals(
                    pair.Key,
                    "id",
                    StringComparison.OrdinalIgnoreCase))
            .Value;
        return value switch
        {
            string stringId => stringId,
            int integerId => integerId.ToString(),
            long longId => longId.ToString(),
            _ => null,
        };
    }

    private static string SanitizeTodoTitle(string title)
    {
        var sanitized = string.Join(
            " ",
            title.Split(
                ['\r', '\n', '\t'],
                StringSplitOptions.RemoveEmptyEntries
                | StringSplitOptions.TrimEntries));
        return sanitized.Length <= 120
            ? sanitized
            : sanitized[..117] + "...";
    }

    private static string FromSkillArguments(
        IDictionary<string, object?>? arguments)
    {
        var knownValues = arguments?.Values
            .OfType<string>()
            .ToArray() ?? [];
        if (knownValues.Any(value =>
                value.Contains(
                    "image-generation",
                    StringComparison.OrdinalIgnoreCase)))
        {
            return "Loading image-generation guidance...";
        }
        if (knownValues.Any(value =>
                value.Contains(
                    "powerpoint",
                    StringComparison.OrdinalIgnoreCase)))
        {
            return "Loading presentation guidance...";
        }

        return "Loading task guidance...";
    }

    private static string FromCode(
        IDictionary<string, object?>? arguments)
    {
        if (arguments?.TryGetValue("code", out var value) != true
            || value is not string code)
        {
            return "Working in the analysis workspace...";
        }

        if (ContainsAny(
                code,
                "soffice",
                "libreoffice",
                "pdftoppm",
                "fitz",
                "pymupdf",
                "render",
                "thumbnail"))
        {
            return "Rendering and checking the presentation...";
        }

        if (ContainsAny(
                code,
                "python-pptx",
                "from pptx",
                "import pptx",
                "Presentation(",
                ".pptx"))
        {
            return "Building the presentation...";
        }

        if (ContainsAny(
                code,
                "from PIL",
                "import PIL",
                "Image.open",
                "Image.new",
                ".png",
                ".jpg",
                ".jpeg"))
        {
            return "Preparing visual assets...";
        }

        return "Working in the analysis workspace...";
    }

    private static string FromToolName(string name)
        => ContainsAny(
                name,
                "search",
                "learn",
                "browse",
                "fetch")
            ? "Researching content..."
            : "Using the configured tools...";

    private static string FromProgressStage(AgentProgressStage stage)
        => stage switch
        {
            AgentProgressStage.PreparingGeneratedFile =>
                "Preparing the generated file...",
            _ => "Preparing the response...",
        };

    private static bool ContainsAny(
        string value,
        params string[] candidates)
        => candidates.Any(candidate =>
            value.Contains(
                candidate,
                StringComparison.OrdinalIgnoreCase));

}
