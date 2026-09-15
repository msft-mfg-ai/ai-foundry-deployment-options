using AgentChat.Bots;
using AgentChat.Services;
using FluentAssertions;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using Xunit;

namespace AgentChat.Tests;

public class AgentProgressMapperTests
{
    [Theory]
    [InlineData("load_skill")]
    [InlineData("read_skill_resource")]
    public void Unknown_skill_tools_report_task_guidance(string toolName)
        => Progress(new FunctionCallContent(
                "call-1",
                toolName,
                new Dictionary<string, object?>()))
            .Should().Be("Loading task guidance...");

    [Theory]
    [InlineData("image-generation", "Loading image-generation guidance...")]
    [InlineData("powerpoint", "Loading presentation guidance...")]
    public void Skill_tools_report_known_guidance(
        string skillName,
        string expected)
        => Progress(new FunctionCallContent(
                "call-1",
                "load_skill",
                new Dictionary<string, object?>
                {
                    ["skill_name"] = skillName,
                }))
            .Should().Be(expected);

    [Fact]
    public void PowerPoint_code_reports_deck_construction_without_exposing_code()
    {
        var progress = Progress(new FunctionCallContent(
            "call-1",
            "code",
            new Dictionary<string, object?>
            {
                ["code"] =
                    "from pptx import Presentation\nsecret = 'do-not-display'",
            }));

        progress.Should().Be("Building the presentation...");
        progress.Should().NotContain("secret");
    }

    [Fact]
    public void Rendering_code_reports_visual_quality_check()
        => Progress(new FunctionCallContent(
                "call-1",
                "code",
                new Dictionary<string, object?>
                {
                    ["code"] = "subprocess.run(['soffice', '--headless'])",
                }))
            .Should().Be("Rendering and checking the presentation...");

    [Fact]
    public void Web_search_does_not_expose_the_query()
    {
        var call = new WebSearchToolCallContent("call-1")
        {
            Queries = ["confidential acquisition target"],
        };

        Progress(call).Should().Be("Researching content...");
    }

    [Fact]
    public void Unknown_tool_names_are_not_exposed()
        => Progress(new FunctionCallContent(
                "call-1",
                "internal_customer_records_lookup",
                new Dictionary<string, object?>()))
            .Should().Be("Using the configured tools...");

    [Fact]
    public void Teams_sso_diagnostic_reports_sign_in()
        => Progress(new FunctionCallContent(
                "call-1",
                "inspect_teams_sso_token",
                new Dictionary<string, object?>()))
            .Should().Be("Starting Teams sign-in...");

    [Fact]
    public void Image_tool_reports_generation_without_exposing_prompt()
    {
        var progress = Progress(new FunctionCallContent(
            "call-1",
            "generate_image",
            new Dictionary<string, object?>
            {
                ["prompt"] = "confidential product design",
            }));

        progress.Should().Be("Generating an image...");
        progress.Should().NotContain("confidential");
    }

    [Fact]
    public void Function_results_report_completion_without_exposing_result()
    {
        var progress = Progress(new FunctionResultContent(
            "call-1",
            "confidential tool result"));

        progress.Should().Be("Tool completed; reviewing the result...");
        progress.Should().NotContain("confidential");
    }

    [Fact]
    public void Generated_files_report_preparation()
        => Progress(new AgentProgressContent(
                AgentProgressStage.PreparingGeneratedFile))
            .Should().Be("Preparing the generated file...");

    private static string? Progress(AIContent content)
        => AgentProgressMapper.GetProgress(
            new AgentResponseUpdate(
                ChatRole.Assistant,
                [content]));
}
