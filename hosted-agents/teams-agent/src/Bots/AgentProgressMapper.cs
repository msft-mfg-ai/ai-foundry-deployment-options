using AgentChat.Services;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;

namespace AgentChat.Bots;

internal static class AgentProgressMapper
{
    private const string LoadSkillTool = "load_skill";
    private const string ReadSkillResourceTool = "read_skill_resource";

    public static string? GetProgress(AgentResponseUpdate update)
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

    private static string FromFunctionCall(FunctionCallContent call)
    {
        if (string.Equals(
                call.Name,
                "inspect_teams_sso_token",
                StringComparison.Ordinal))
        {
            return "Starting Teams sign-in...";
        }

        if (call.Name is LoadSkillTool or ReadSkillResourceTool)
        {
            return "Loading presentation guidance...";
        }

        if (string.Equals(call.Name, "code", StringComparison.Ordinal))
        {
            return FromCode(call.Arguments);
        }

        return FromToolName(call.Name);
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
