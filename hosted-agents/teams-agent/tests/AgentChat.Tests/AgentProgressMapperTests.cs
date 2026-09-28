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
    public void Return_file_tool_reports_final_file_selection()
    {
        var progress = Progress(new FunctionCallContent(
            "call-1",
            "return_file",
            new Dictionary<string, object?>
            {
                ["filename"] = "confidential-deck.pptx",
            }));

        progress.Should().Be("Selecting the final file to return...");
        progress.Should().NotContain("confidential");
    }

    [Fact]
    public void Harness_todo_creation_exposes_only_safe_plan_titles()
    {
        var progress = Progress(new FunctionCallContent(
            "call-1",
            "todos_add",
            new Dictionary<string, object?>
            {
                ["items"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["title"] = "Research the topic",
                        ["description"] = "secret query and raw tool data",
                    },
                    new Dictionary<string, object?>
                    {
                        ["title"] = "Build and review the deck",
                    },
                },
            }));

        progress.Should().Be(
            "Plan:\n1. Research the topic (pending)\n2. Build and review the deck (pending)");
        progress.Should().NotContain("secret");
    }

    [Fact]
    public void Harness_todo_completion_reports_pending_plan_update()
        => Progress(new FunctionCallContent(
                "call-1",
                "todos_complete",
                new Dictionary<string, object?>
                {
                    ["items"] = new object[]
                    {
                        new Dictionary<string, object?>
                        {
                            ["id"] = 1,
                            ["reason"] = "Research completed",
                        },
                    },
                }))
            .Should()
            .Be("Updating the plan...");

    [Fact]
    public void Successful_todo_result_checks_the_matching_item_by_id()
    {
        var mapper = new AgentProgressMapper();
        mapper.GetProgress(Update(new FunctionCallContent(
            "add-call",
            "todos_add",
            new Dictionary<string, object?>
            {
                ["items"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["title"] = "Research the topic",
                    },
                    new Dictionary<string, object?>
                    {
                        ["title"] = "Build the deck",
                    },
                },
            })));
        mapper.GetProgress(Update(new FunctionResultContent(
            "add-call",
            new object[]
            {
                new Dictionary<string, object?>
                {
                    ["id"] = 1,
                    ["title"] = "Research the topic",
                },
                new Dictionary<string, object?>
                {
                    ["id"] = 2,
                    ["title"] = "Build the deck",
                },
            })));
        var completionCall = new FunctionCallContent(
            "complete-call",
            "todos_complete",
            new Dictionary<string, object?>
            {
                ["items"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["id"] = 2,
                        ["reason"] = "Deck built",
                    },
                },
            });
        mapper.GetProgress(Update(completionCall));

        mapper.GetProgress(Update(new FunctionResultContent(
                "complete-call",
                1)))
            .Should()
            .Be(
                "Plan:\n1. Research the topic (pending)\n2. Build the deck (done)");
    }

    [Fact]
    public void Zero_todo_result_does_not_check_an_item()
    {
        var mapper = new AgentProgressMapper();
        mapper.GetProgress(Update(new FunctionCallContent(
            "add-call",
            "todos_add",
            new Dictionary<string, object?>
            {
                ["items"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["title"] = "Research the topic",
                    },
                },
            })));
        mapper.GetProgress(Update(new FunctionResultContent(
            "add-call",
            new object[]
            {
                new Dictionary<string, object?>
                {
                    ["id"] = 1,
                    ["title"] = "Research the topic",
                },
            })));
        mapper.GetProgress(Update(new FunctionCallContent(
            "complete-call",
            "todos_complete",
            new Dictionary<string, object?>
            {
                ["items"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["id"] = 999,
                    },
                },
            })));

        mapper.GetProgress(Update(new FunctionResultContent(
                "complete-call",
                0)))
            .Should()
            .Be("Plan unchanged; continuing with the remaining steps...");
    }

    [Fact]
    public void Repeated_todo_add_updates_reconcile_cumulative_items()
    {
        var mapper = new AgentProgressMapper();

        mapper.GetProgress(Update(new FunctionCallContent(
                "add-call",
                "todos_add",
                new Dictionary<string, object?>
                {
                    ["todos"] = new object[]
                    {
                        new Dictionary<string, object?>
                        {
                            ["title"] = "Calculate the result",
                        },
                    },
                })))
            .Should()
            .Be("Plan:\n1. Calculate the result (pending)");

        mapper.GetProgress(Update(new FunctionCallContent(
                "add-call",
                "todos_add",
                new Dictionary<string, object?>
                {
                    ["todos"] = new object[]
                    {
                        new Dictionary<string, object?>
                        {
                            ["title"] = "Calculate the result",
                        },
                        new Dictionary<string, object?>
                        {
                            ["title"] = "Verify the result",
                        },
                    },
                })))
            .Should()
            .Be(
                "Plan:\n1. Calculate the result (pending)\n2. Verify the result (pending)");
    }

    [Fact]
    public void Persisted_todos_can_be_completed_in_a_later_invocation()
    {
        var persisted = new List<AgentTodoProgressState>
        {
            new()
            {
                Id = "2",
                Title = "Build the deck",
            },
        };
        var mapper = new AgentProgressMapper(persisted);
        mapper.GetProgress(Update(new FunctionCallContent(
            "complete-call",
            "todos_complete",
            new Dictionary<string, object?>
            {
                ["items"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["id"] = 2,
                        ["reason"] = "Deck built",
                    },
                },
            })));

        mapper.GetProgress(Update(new FunctionResultContent(
                "complete-call",
                1)))
            .Should()
            .Be("Plan:\n1. Build the deck (done)");
        persisted.Should().ContainSingle(item => item.Completed);
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
    public void Function_exceptions_report_recovery_without_claiming_terminal_failure()
    {
        var result = new FunctionResultContent(
            "call-1",
            "The function failed.")
        {
            Exception = new InvalidOperationException("sensitive detail"),
        };

        var progress = Progress(result);

        progress.Should().Be(
            "Tool returned an issue; continuing with another approach...");
        progress.Should().NotContain("sensitive");
        progress.Should().NotBe("Tool failed; adjusting the approach...");
    }

    [Fact]
    public void Generated_files_report_preparation()
        => Progress(new AgentProgressContent(
                AgentProgressStage.PreparingGeneratedFile))
            .Should().Be("Preparing the generated file...");

    private static string? Progress(AIContent content)
        => new AgentProgressMapper().GetProgress(Update(content));

    private static AgentResponseUpdate Update(AIContent content)
        => new(
            ChatRole.Assistant,
            [content]);
}
