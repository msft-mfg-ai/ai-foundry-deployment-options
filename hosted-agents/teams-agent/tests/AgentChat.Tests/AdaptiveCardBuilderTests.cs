using AdaptiveCards;
using AgentChat.Bots;
using AgentChat.Services;
using FluentAssertions;
using Microsoft.Agents.Core.Models;
using Newtonsoft.Json.Linq;
using Xunit;

namespace AgentChat.Tests;

/// <summary>
/// Tests for the AdaptiveCardBuilder. We assert <i>behavior</i> rather than
/// DOM structure: tests walk the whole card tree to find text/inputs/actions,
/// so they're stable across visual redesigns. Each card type has a small
/// number of cases that pin the user-visible contract — text appears, action
/// payloads carry the right keys, theming styles match the intent of the card.
/// </summary>
public class AdaptiveCardBuilderTests
{
    // ============================================================ Approval

    [Fact]
    public void ApprovalCard_uses_attention_style_to_signal_security_action()
    {
        var att = MakeApproval();
        var json = CardJson(att);
        StylesIn(json).Should().Contain("attention");
    }

    [Fact]
    public void ApprovalCard_includes_two_submit_actions_with_required_payload_shape()
    {
        var att = AdaptiveCardBuilder.BuildApprovalCard(
            toolName: "search", serverLabel: "microsoft_learn",
            arguments: "{\"q\":\"foundry\"}",
            approvalRequestId: "mcpr_123", conversationId: "conv_456");

        att.ContentType.Should().Be(AdaptiveCard.ContentType);
        var actions = (JArray)(CardJson(att))["actions"]!;
        actions.Should().HaveCount(2);

        actions.Select(a => ((JObject)a["data"]!)["approve"]!.Value<bool>())
            .Should().BeEquivalentTo(new[] { true, false });
        foreach (var act in actions)
        {
            var data = (JObject)act["data"]!;
            data["action"]!.ToString().Should().Be("mcp_approval");
            data["approval_request_id"]!.ToString().Should().Be("mcpr_123");
            data["conversationId"]!.ToString().Should().Be("conv_456");
        }
    }

    [Theory]
    [InlineData(true,  "Approve")]
    [InlineData(false, "Deny")]
    public void ApprovalCard_action_titles_match_approve_flag(bool approve, string titleContains)
    {
        var att = MakeApproval();
        var actions = (JArray)(CardJson(att))["actions"]!;
        var act = actions.First(a => ((JObject)a["data"]!)["approve"]!.Value<bool>() == approve);
        act["title"]!.ToString().Should().Contain(titleContains);
    }

    [Fact]
    public void ApprovalCard_renders_tool_name_in_the_visible_text()
    {
        var att = AdaptiveCardBuilder.BuildApprovalCard("microsoft_docs_fetch", "ms_learn", "{}", "appr", "conv");
        AllText(att).Should().Contain(t => t.Contains("microsoft_docs_fetch"));
    }

    [Fact]
    public void ApprovalCard_marks_approve_action_positive_and_deny_destructive()
    {
        var att = MakeApproval();
        var actions = (JArray)(CardJson(att))["actions"]!;
        var approve = actions.First(a => ((JObject)a["data"]!)["approve"]!.Value<bool>());
        var deny    = actions.First(a => !((JObject)a["data"]!)["approve"]!.Value<bool>());

        approve["style"]?.ToString().Should().Be("positive");
        deny["style"]?.ToString().Should().Be("destructive");
    }

    private static Attachment MakeApproval()
        => AdaptiveCardBuilder.BuildApprovalCard("x", "y", "{}", "appr", "conv");

    // ============================================================ Tool call

    [Fact]
    public void ToolCallCard_renders_tool_name_server_label_and_output()
    {
        var att = AdaptiveCardBuilder.BuildToolCallCard(
            toolName: "search", serverLabel: "learn",
            arguments: "{\"q\":\"x\"}", output: "result body", toolKind: "MCP");

        var text = AllText(att);
        text.Should().Contain(t => t.Contains("search"));
        text.Should().Contain(t => t.Contains("learn"));
        text.Should().Contain(t => t.Contains("result body"));
    }

    [Theory]
    [InlineData("MCP",             "🔧")]
    [InlineData("Function",        "🛠️")]
    [InlineData("CodeInterpreter", "🐍")]
    public void ToolCallCard_picks_icon_per_kind(string kind, string icon)
    {
        var att = AdaptiveCardBuilder.BuildToolCallCard("name", "", "{}", null, toolKind: kind);
        AllText(att).Should().Contain(t => t.Contains(icon));
    }

    [Fact]
    public void ToolCallCard_omits_output_section_when_output_null()
    {
        var att = AdaptiveCardBuilder.BuildToolCallCard("name", "", "{}", null, "MCP");
        AllText(att).Should().NotContain(t => t == "Output");
    }

    [Fact]
    public void ToolCallCard_truncates_long_output_with_marker()
    {
        var hugeOutput = new string('z', 5000);
        var att = AdaptiveCardBuilder.BuildToolCallCard("name", "", "{}", hugeOutput, "MCP");
        var allText = string.Join("\n", AllText(att));
        allText.Should().Contain("truncated");
    }

    // ============================================================ Agent picker

    [Fact]
    public void AgentPickerCard_lists_every_descriptor_as_a_choice()
    {
        var descriptors = new[]
        {
            new AgentService.AgentDescriptor("a", "Agent A", "first",  "https://x.example.com/a"),
            new AgentService.AgentDescriptor("b", "Agent B", "second", "https://x.example.com/b"),
            new AgentService.AgentDescriptor("c", "Agent C", "third",  "https://x.example.com/c")
        };

        var att = AdaptiveCardBuilder.BuildAgentPickerCard(descriptors, currentKey: "b");

        var input = FindFirst(att, "Input.ChoiceSet");
        input.Should().NotBeNull();
        ((JArray)input!["choices"]!).Should().HaveCount(3);
        input["value"]!.ToString().Should().Be("b");

        var actions = (JArray)(CardJson(att))["actions"]!;
        actions.Should().HaveCount(1);
        ((JObject)actions[0]!["data"]!)["action"]!.ToString().Should().Be("select_agent");
    }

    // ============================================================ Usage

    [Fact]
    public void UsageCard_renders_all_four_stats()
    {
        var att = AdaptiveCardBuilder.BuildUsageCard(promptTokens: 1234, completionTokens: 567, totalTokens: 1801, elapsed: TimeSpan.FromSeconds(2.5));
        var allText = string.Join("\n", AllText(att));
        allText.Should().Contain("1,234");
        allText.Should().Contain("567");
        allText.Should().Contain("1,801");
        allText.Should().Contain("2.5s");
        allText.Should().ContainAll(new[] { "Prompt", "Completion", "Total", "Elapsed" });
    }

    [Fact]
    public void UsageCard_renders_question_marks_when_usage_missing()
    {
        var att = AdaptiveCardBuilder.BuildUsageCard(null, null, null, TimeSpan.Zero);
        string.Join("\n", AllText(att)).Should().Contain("?");
    }

    // ============================================================ Cancel

    [Fact]
    public void CancelCard_has_cancel_action_with_response_metadata()
    {
        var att = AdaptiveCardBuilder.BuildCancelCard("conv_x", "resp_y");
        var actions = (JArray)(CardJson(att))["actions"]!;
        actions.Should().HaveCount(1);
        var data = (JObject)actions[0]!["data"]!;
        data["action"]!.ToString().Should().Be("cancel");
        data["conversationId"]!.ToString().Should().Be("conv_x");
        data["responseId"]!.ToString().Should().Be("resp_y");
        actions[0]!["style"]?.ToString().Should().Be("destructive");
    }

    // ============================================================ Consent

    [Fact]
    public void ConsentCard_uses_warning_style_and_renders_server_label()
    {
        var att = AdaptiveCardBuilder.BuildConsentCard("microsoft_learn", "https://consent.example/x", "conv_1");
        StylesIn((JToken)CardJson(att)).Should().Contain("warning");
        AllText(att).Should().Contain(t => t.Contains("microsoft_learn"));
    }

    [Fact]
    public void ConsentCard_renders_markdown_link_when_consent_link_is_a_url()
    {
        var att = AdaptiveCardBuilder.BuildConsentCard("srv", "https://consent.example/login?data=abc", "conv_1");
        var text = string.Join("\n", AllText(att));
        text.Should().Contain("[🔗 Open consent link](https://consent.example/login?data=abc)");
    }

    [Fact]
    public void ConsentCard_falls_back_to_placeholder_when_no_url_present()
    {
        var att = AdaptiveCardBuilder.BuildConsentCard("srv", "", "conv_1");
        att.Content.Should().NotBeNull();
        AllText(att).Should().Contain(t => t.Contains("no consent link returned"));
    }

    [Fact]
    public void ConsentCard_has_continue_and_cancel_submit_actions()
    {
        var att = AdaptiveCardBuilder.BuildConsentCard("srv", "https://consent.example/x", "conv_123");
        var actions = (JArray)(CardJson(att))["actions"]!;
        var submits = actions.OfType<JObject>().Where(a => a["type"]!.ToString() == "Action.Submit").ToList();
        submits.Should().HaveCount(2);

        var cont = submits.First(a => ((JObject)a["data"]!)["action"]!.ToString() == "consent_continue");
        ((JObject)cont["data"]!)["conversationId"]!.ToString().Should().Be("conv_123");
        ((JObject)cont["data"]!)["serverLabel"]!.ToString().Should().Be("srv");
        cont["style"]?.ToString().Should().Be("positive");

        var cancel = submits.First(a => ((JObject)a["data"]!)["action"]!.ToString() == "consent_cancel");
        cancel["style"]?.ToString().Should().Be("destructive");
    }

    [Fact]
    public void ConnectedAgentCard_renders_subagent_name_and_message()
    {
        var att = AdaptiveCardBuilder.BuildConnectedAgentCard("docs_assistant", "Looking up Azure docs");
        var text = AllText(att);
        text.Should().Contain(t => t.Contains("docs_assistant"));
        text.Should().Contain(t => t.Contains("Looking up Azure docs"));
    }

    [Fact]
    public void ConnectedAgentCard_handles_null_message()
    {
        var att = AdaptiveCardBuilder.BuildConnectedAgentCard("sub", null);
        AllText(att).Should().Contain(t => t.Contains("sub"));
    }

    // ============================================================ Help

    [Fact]
    public void HelpCard_renders_each_command()
    {
        var att = AdaptiveCardBuilder.BuildHelpCard(new[]
        {
            ("/agents", "Pick an agent"),
            ("/reset",  "Start over")
        });

        var text = string.Join("\n", AllText(att));
        text.Should().Contain("/agents");
        text.Should().Contain("Pick an agent");
        text.Should().Contain("/reset");
        text.Should().Contain("Start over");
    }

    // ============================================================ Info / Tokens / Agent info

    [Fact]
    public void InfoCard_includes_icon_in_title()
    {
        var att = AdaptiveCardBuilder.BuildInfoCard("Hello", "🎉", new[] { ("k", "v") });
        AllText(att).Should().Contain(t => t.Contains("🎉"));
        AllText(att).Should().Contain(t => t == "Hello");
    }

    [Fact]
    public void InfoCard_renders_facts()
    {
        var att = AdaptiveCardBuilder.BuildInfoCard("Title", null, new[]
        {
            ("Foo", "111"),
            ("Bar", "222")
        });
        var text = AllText(att);
        text.Should().Contain(t => t == "Foo");
        text.Should().Contain(t => t == "111");
        text.Should().Contain(t => t == "Bar");
        text.Should().Contain(t => t == "222");
    }

    [Fact]
    public void InfoCard_renders_section_headers_for_dash_prefixed_labels()
    {
        var att = AdaptiveCardBuilder.BuildInfoCard("T", null, new[]
        {
            ("--- Group A", ""),
            ("k1", "v1"),
            ("--- Group B", ""),
            ("k2", "v2")
        });
        var text = AllText(att);
        text.Should().Contain(t => t.Contains("Group A"));
        text.Should().Contain(t => t.Contains("Group B"));
        text.Should().Contain(t => t == "v1");
        text.Should().Contain(t => t == "v2");
    }

    // ============================================================ Code block

    [Fact]
    public void CodeBlockCard_renders_language_and_code()
    {
        var att = AdaptiveCardBuilder.BuildCodeBlockCard("python", "print('hi')");
        var text = AllText(att);
        text.Should().Contain(t => t.Contains("python"));
        text.Should().Contain(t => t.Contains("print('hi')"));
    }

    // ============================================================ Cross-cutting

    [Fact]
    public void All_cards_use_the_AdaptiveCard_content_type()
    {
        var att1 = AdaptiveCardBuilder.BuildApprovalCard("x", "y", "{}", "appr", "conv");
        var att2 = AdaptiveCardBuilder.BuildCancelCard("conv", "resp");
        var att3 = AdaptiveCardBuilder.BuildToolCallCard("n", "", "{}", null);
        var att4 = AdaptiveCardBuilder.BuildUsageCard(1, 1, 1, TimeSpan.Zero);
        var att5 = AdaptiveCardBuilder.BuildHelpCard(Array.Empty<(string, string)>());
        var att6 = AdaptiveCardBuilder.BuildInfoCard("t", null, Array.Empty<(string, string)>());
        var att7 = AdaptiveCardBuilder.BuildConnectedAgentCard("n", null);
        var att8 = AdaptiveCardBuilder.BuildCodeBlockCard("py", "");

        foreach (var att in new[] { att1, att2, att3, att4, att5, att6, att7, att8 })
        {
            att.ContentType.Should().Be(AdaptiveCard.ContentType);
            att.Content.Should().NotBeNull();
            (CardJson(att))["type"]!.ToString().Should().Be("AdaptiveCard");

            // Regression: the outgoing activity is serialized by the M365
            // Agents SDK via System.Text.Json. If Content is a Newtonsoft
            // JObject/JToken, STJ emits its type shape (HasValues, Count, …)
            // instead of the card JSON and Bot Service replies 400.
            att.Content.Should().BeAssignableTo<System.Text.Json.Nodes.JsonNode>();
            var stj = System.Text.Json.JsonSerializer.Serialize(att.Content);
            stj.Should().Contain("\"type\":\"AdaptiveCard\"");
            stj.Should().NotContain("HasValues");
        }
    }

    // ============================================================ Reasoning

    [Fact]
    public void ReasoningCard_renders_subtitle_with_step_count()
    {
        var att = AdaptiveCardBuilder.BuildReasoningCard(new List<ThinkingStep>
        {
            new("Function", "get_weather", null, "{\"city\":\"oslo\"}", "sunny", false),
            new("MCP",      "search",      "microsoft_learn", "{\"q\":\"foundry\"}", "3 results", false)
        });
        AllText(att).Should().Contain("Reasoning");
        AllText(att).Should().Contain(t => t.Contains("2 steps"));
        AllText(att).Should().Contain(t => t.Contains("get_weather"));
        AllText(att).Should().Contain(t => t.Contains("search"));
    }

    [Fact]
    public void ReasoningCard_uses_singular_when_only_one_step()
    {
        var att = AdaptiveCardBuilder.BuildReasoningCard(new List<ThinkingStep>
        {
            new("Function", "f", null, "{}", "ok", false)
        });
        AllText(att).Should().Contain(t => t.Contains("1 step") && !t.Contains("1 steps"));
    }

    [Fact]
    public void ReasoningCard_details_container_starts_hidden_and_secondary_action_bar_starts_hidden()
    {
        var att     = AdaptiveCardBuilder.BuildReasoningCard(new List<ThinkingStep>
        {
            new("MCP", "x", "srv", "{}", "y", false)
        });
        var root    = CardJson(att);
        var details = FindById(root, "reasoningDetails");
        details.Should().NotBeNull();
        details!["isVisible"]!.Value<bool>().Should().BeFalse();

        var hideBar = FindById(root, "hideStepsBar");
        hideBar.Should().NotBeNull();
        hideBar!["isVisible"]!.Value<bool>().Should().BeFalse();

        var showBar = FindById(root, "showStepsBar");
        showBar.Should().NotBeNull();
        // Default isVisible = true when not specified.
        (showBar!["isVisible"]?.Value<bool>() ?? true).Should().BeTrue();
    }

    [Fact]
    public void ReasoningCard_show_action_targets_swap_visibility_of_details_and_buttons()
    {
        var att     = AdaptiveCardBuilder.BuildReasoningCard(new List<ThinkingStep>
        {
            new("MCP", "x", "srv", "{}", "y", false)
        });
        var showBar = FindById(CardJson(att), "showStepsBar")!;
        var act     = (JObject)((JArray)showBar["actions"]!)[0];
        act["type"]!.ToString().Should().Be("Action.ToggleVisibility");
        var targets = ((JArray)act["targetElements"]!).Cast<JObject>().ToList();

        targets.Single(t => t["elementId"]!.ToString() == "reasoningDetails")["isVisible"]!.Value<bool>().Should().BeTrue();
        targets.Single(t => t["elementId"]!.ToString() == "showStepsBar")["isVisible"]!.Value<bool>().Should().BeFalse();
        targets.Single(t => t["elementId"]!.ToString() == "hideStepsBar")["isVisible"]!.Value<bool>().Should().BeTrue();
    }

    [Fact]
    public void ReasoningCard_truncates_long_arguments_and_output_with_ellipsis()
    {
        var bigArgs   = new string('a', 5000);
        var bigOutput = new string('b', 5000);
        var att = AdaptiveCardBuilder.BuildReasoningCard(new List<ThinkingStep>
        {
            new("Function", "blob", null, bigArgs, bigOutput, false)
        });
        var texts = AllText(att);
        // Arguments cap is 200 chars in BuildReasoningStep.
        texts.Should().Contain(t => t.StartsWith("aaaa") && t.Length <= 240);
        // Output cap is 400 chars.
        texts.Should().Contain(t => t.StartsWith("bbbb") && t.Length <= 440);
        // Neither field renders the raw 5000-char input.
        texts.Should().NotContain(t => t.Length >= 5000);
    }

    [Fact]
    public void ReasoningCard_caps_at_20_visible_steps_and_notes_overflow()
    {
        var steps = Enumerable.Range(0, 25)
            .Select(i => new ThinkingStep("MCP", $"tool_{i}", "srv", "{}", "ok", false))
            .ToList();
        var att = AdaptiveCardBuilder.BuildReasoningCard(steps);
        var texts = AllText(att);
        texts.Should().Contain(t => t.Contains("tool_0"));
        texts.Should().Contain(t => t.Contains("tool_19"));
        texts.Should().NotContain(t => t.Contains("tool_20"));
        texts.Should().Contain(t => t.Contains("5") && t.Contains("more"));
    }

    [Fact]
    public void ReasoningCard_error_step_uses_warning_icon_and_error_label()
    {
        var att = AdaptiveCardBuilder.BuildReasoningCard(new List<ThinkingStep>
        {
            new("MCP", "broken_tool", "srv", "{}", "boom", IsError: true)
        });
        var texts = AllText(att);
        texts.Should().Contain(t => t.Contains("⚠️") && t.Contains("broken_tool"));
        texts.Should().Contain(t => t == "Error");
        texts.Should().NotContain(t => t == "Output");
    }

    [Fact]
    public void ReasoningCard_throws_on_empty_step_list()
    {
        Action act = () => AdaptiveCardBuilder.BuildReasoningCard(new List<ThinkingStep>());
        act.Should().Throw<ArgumentException>().WithParameterName("steps");
    }

    [Fact]
    public void ReasoningCard_uses_default_style_for_neutral_header()
    {
        var att = AdaptiveCardBuilder.BuildReasoningCard(new List<ThinkingStep>
        {
            new("MCP", "x", "srv", "{}", "ok", false)
        });
        StylesIn((JToken)CardJson(att)).Should().Contain("default");
    }

    private static JObject? FindById(JObject root, string id)
    {
        JObject? hit = null;
        Walk(root);
        return hit;

        void Walk(JToken n)
        {
            if (hit is not null) return;
            switch (n)
            {
                case JObject obj when obj["id"]?.ToString() == id:
                    hit = obj;
                    return;
                case JObject obj:
                    foreach (var p in obj.Properties()) Walk(p.Value);
                    break;
                case JArray arr:
                    foreach (var c in arr) Walk(c);
                    break;
            }
        }
    }

    // ============================================================ helpers

    /// <summary>Recursively collects every visible text string from a card.</summary>
    /// <summary>
    /// Re-parses the outgoing card content (a <c>System.Text.Json.Nodes.JsonNode</c>)
    /// through <c>Newtonsoft.Json</c> so existing tests can keep using the
    /// familiar <c>JObject</c>/<c>JArray</c>/<c>JToken</c> API.
    /// </summary>
    private static JObject CardJson(Attachment att)
        => JObject.Parse(((System.Text.Json.Nodes.JsonNode)att.Content!).ToJsonString());

    private static List<string> AllText(Attachment att)
    {
        var results = new List<string>();
        Walk((JToken)CardJson(att), results);
        return results;

        static void Walk(JToken node, List<string> sink)
        {
            switch (node)
            {
                case JObject obj:
                    if (obj["type"]?.ToString() == "TextBlock" && obj["text"] is { } txt)
                        sink.Add(txt.ToString());
                    foreach (var p in obj.Properties()) Walk(p.Value, sink);
                    break;
                case JArray arr:
                    foreach (var c in arr) Walk(c, sink);
                    break;
            }
        }
    }

    /// <summary>Finds the first element of the given AdaptiveCard type.</summary>
    private static JObject? FindFirst(Attachment att, string adaptiveType)
    {
        JObject? hit = null;
        Walk((JToken)CardJson(att));
        return hit;

        void Walk(JToken node)
        {
            if (hit is not null) return;
            switch (node)
            {
                case JObject obj when obj["type"]?.ToString() == adaptiveType:
                    hit = obj;
                    return;
                case JObject obj:
                    foreach (var p in obj.Properties()) Walk(p.Value);
                    break;
                case JArray arr:
                    foreach (var c in arr) Walk(c);
                    break;
            }
        }
    }

    /// <summary>Collects every "style" string on every Container in the card.</summary>
    private static List<string> StylesIn(JToken node)
    {
        var sink = new List<string>();
        Walk(node);
        return sink;

        void Walk(JToken n)
        {
            switch (n)
            {
                case JObject obj:
                    if (obj["type"]?.ToString() == "Container" && obj["style"] is { } s)
                        sink.Add(s.ToString());
                    foreach (var p in obj.Properties()) Walk(p.Value);
                    break;
                case JArray arr:
                    foreach (var c in arr) Walk(c);
                    break;
            }
        }
    }
}
