using AdaptiveCards;
using AgentChat.Services;
using Microsoft.Agents.Core.Models;
using Newtonsoft.Json.Linq;
using System.Text.Json.Nodes;

namespace AgentChat.Bots;

/// <summary>
/// Adaptive Cards used by the bot. All cards follow the same visual language:
///
///   ┌─────────────────────────────────────────┐
///   │  ICON   Title                  [accent] │  Header bar (Container, color by intent)
///   │         Subtle subtitle                 │
///   ├─────────────────────────────────────────┤
///   │  Body content                           │
///   ├─────────────────────────────────────────┤
///   │   [primary]   [neutral]   [destructive] │  Actions (styled)
///   └─────────────────────────────────────────┘
///
/// Container styles (theme-aware in both Teams light and dark):
///   - Attention  → security-sensitive (approvals)
///   - Accent     → informational (agent picker, tool calls)
///   - Warning    → cancel / interrupt
///   - Default    → help / generic info / tokens / usage
/// </summary>
public static class AdaptiveCardBuilder
{
    private const int MaxToolOutputInCard = 800;
    private static readonly AdaptiveSchemaVersion Schema = new(1, 4);

    // -------------------------------------------------------------------- approval

    public static Attachment BuildApprovalCard(
        string toolName, string serverLabel, string arguments,
        string approvalRequestId, string conversationId)
    {
        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                HeaderBar("🔐", "Approve tool call", $"on `{serverLabel}`", AdaptiveContainerStyle.Attention),
                KvSection(new[]
                {
                    ("Tool",   toolName),
                    ("Server", serverLabel)
                }),
                SubtleLabel("Arguments"),
                CodeBlock(PrettyJson(arguments))
            },
            Actions =
            {
                new AdaptiveSubmitAction
                {
                    Title = "✅ Approve", Style = "positive",
                    Data  = JObject.FromObject(new { action = "mcp_approval", approve = true, approval_request_id = approvalRequestId, conversationId })
                },
                new AdaptiveSubmitAction
                {
                    Title = "❌ Deny", Style = "destructive",
                    Data  = JObject.FromObject(new { action = "mcp_approval", approve = false, approval_request_id = approvalRequestId, conversationId })
                }
            }
        };
        return AsAttachment(card);
    }

    // -------------------------------------------------------------------- tool call

    public static Attachment BuildToolCallCard(
        string toolName, string serverLabel, string arguments, string? output, string toolKind = "MCP")
    {
        var (icon, kindLabel) = toolKind switch
        {
            "Function"        => ("🛠️", "Function"),
            "CodeInterpreter" => ("🐍", "Code Interpreter"),
            _                 => ("🔧", "MCP tool")
        };

        var subtitle = string.IsNullOrEmpty(serverLabel)
            ? kindLabel
            : $"{kindLabel} on `{serverLabel}`";

        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                HeaderBar(icon, toolName, subtitle, AdaptiveContainerStyle.Accent),
            }
        };

        if (!string.IsNullOrEmpty(arguments))
        {
            card.Body.Add(SubtleLabel("Arguments"));
            card.Body.Add(CodeBlock(PrettyJson(arguments)));
        }
        if (!string.IsNullOrEmpty(output))
        {
            var truncated = output!.Length > MaxToolOutputInCard;
            card.Body.Add(SubtleLabel(truncated ? "Output (truncated)" : "Output"));
            card.Body.Add(CodeBlock(Truncate(output, MaxToolOutputInCard)));
        }
        return AsAttachment(card);
    }

    // -------------------------------------------------------------------- agent picker

    public static Attachment BuildAgentPickerCard(IEnumerable<AgentService.AgentDescriptor> descriptors, string? currentKey)
    {
        var list = descriptors.ToList();
        var choices = new AdaptiveChoiceSetInput
        {
            Id    = "agentKey",
            Style = AdaptiveChoiceInputStyle.Expanded,   // radio buttons feel nicer than the compact picker
            Value = currentKey ?? list.FirstOrDefault()?.Key
        };
        foreach (var d in list)
        {
            choices.Choices.Add(new AdaptiveChoice
            {
                Title = $"{d.Name} — {d.Description}",
                Value = d.Key
            });
        }

        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                HeaderBar("🤖", "Pick an agent", "Choose who answers your next questions", AdaptiveContainerStyle.Accent),
                choices
            },
            Actions =
            {
                new AdaptiveSubmitAction
                {
                    Title = "Use this agent",
                    Style = "positive",
                    Data  = JObject.FromObject(new { action = "select_agent" })
                }
            }
        };
        return AsAttachment(card);
    }

    // -------------------------------------------------------------------- code block

    public static Attachment BuildCodeBlockCard(string language, string code)
    {
        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                HeaderBar("🐍", "Code Interpreter", language, AdaptiveContainerStyle.Accent),
                CodeBlock(code)
            }
        };
        return AsAttachment(card);
    }

    // -------------------------------------------------------------------- usage footer

    public static Attachment BuildUsageCard(int? promptTokens, int? completionTokens, int? totalTokens, TimeSpan elapsed)
    {
        // Usage is a compact footer strip — no header bar, just 4 stats in a row.
        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                new AdaptiveContainer
                {
                    Style = AdaptiveContainerStyle.Emphasis,
                    Bleed = true,
                    Items =
                    {
                        new AdaptiveColumnSet
                        {
                            Columns =
                            {
                                StatColumn("Prompt",     promptTokens?.ToString("N0")     ?? "?"),
                                StatColumn("Completion", completionTokens?.ToString("N0") ?? "?"),
                                StatColumn("Total",      totalTokens?.ToString("N0")      ?? "?"),
                                StatColumn("Elapsed",    $"{elapsed.TotalSeconds:F1}s")
                            }
                        }
                    }
                }
            }
        };
        return AsAttachment(card);
    }

    // -------------------------------------------------------------------- oauth consent

    /// <summary>
    /// Surfaced when an MCP tool uses OAuth identity passthrough and Foundry
    /// has no cached credential for the current user. The consent link points
    /// to Foundry's hosted consent page; the user signs in there, then clicks
    /// "I've signed in" in chat to resume the turn.
    /// </summary>
    public static Attachment BuildConsentCard(
        string serverLabel, string consentLink, string conversationId)
    {
        var linkBlock = !string.IsNullOrWhiteSpace(consentLink)
            ? new AdaptiveTextBlock
            {
                Text = $"[🔗 Open consent link]({consentLink})",
                Wrap = true
            }
            : new AdaptiveTextBlock
            {
                Text = "(no consent link returned)",
                Wrap = true,
                Size = AdaptiveTextSize.Small
            };

        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                HeaderBar("🔑", "Sign-in required", $"on MCP server `{serverLabel}`", AdaptiveContainerStyle.Warning),
                new AdaptiveTextBlock
                {
                    Text     = "Foundry needs you to sign in to this tool's MCP server before it can be used in this chat. " +
                               "Open the consent link, complete the sign-in, then click **I've signed in**.",
                    Wrap     = true,
                    Size     = AdaptiveTextSize.Small
                },
                linkBlock
            },
            Actions =
            {
                new AdaptiveSubmitAction
                {
                    Title = "✅ I've signed in",
                    Style = "positive",
                    Data  = JObject.FromObject(new { action = "consent_continue", conversationId, serverLabel })
                },
                new AdaptiveSubmitAction
                {
                    Title = "❌ Cancel",
                    Style = "destructive",
                    Data  = JObject.FromObject(new { action = "consent_cancel", conversationId, serverLabel })
                }
            }
        };
        return AsAttachment(card);
    }

    // -------------------------------------------------------------------- cancel

    public static Attachment BuildCancelCard(string conversationId, string responseId)
    {
        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                HeaderBar("⏳", "Agent is running…", "You can stop it any time.", AdaptiveContainerStyle.Warning),
            },
            Actions =
            {
                new AdaptiveSubmitAction
                {
                    Title = "🛑 Cancel",
                    Style = "destructive",
                    Data  = JObject.FromObject(new { action = "cancel", responseId, conversationId })
                }
            }
        };
        return AsAttachment(card);
    }

    // -------------------------------------------------------------------- connected agent (kept for back-compat)

    public static Attachment BuildConnectedAgentCard(string subAgentName, string? message)
    {
        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                HeaderBar("🔗", "Handoff", subAgentName, AdaptiveContainerStyle.Accent)
            }
        };
        if (!string.IsNullOrEmpty(message))
        {
            card.Body.Add(SubtleLabel("Message"));
            card.Body.Add(CodeBlock(message!));
        }
        return AsAttachment(card);
    }

    // -------------------------------------------------------------------- reasoning

    private const int MaxArgsInReasoningStep   = 200;
    private const int MaxOutputInReasoningStep = 400;
    private const int MaxStepsInReasoningCard  = 20;

    /// <summary>
    /// Collapsible "Reasoning" summary card attached to the FINAL streaming
    /// message of a turn. Lists each tool/function call the agent made, with
    /// truncated arguments and output. Hidden by default — user clicks
    /// "Show steps" to expand.
    ///
    /// Sized conservatively: per-step caps + a hard cap of 20 steps keep the
    /// payload well under Bot Connector's ~28 KB activity limit even on long
    /// multi-tool turns.
    /// </summary>
    public static Attachment BuildReasoningCard(IList<ThinkingStep> steps)
    {
        ArgumentNullException.ThrowIfNull(steps);
        if (steps.Count == 0)
            throw new ArgumentException("At least one step is required.", nameof(steps));

        var detailsId = "reasoningDetails";

        var details = new AdaptiveContainer
        {
            Id        = detailsId,
            IsVisible = false,
            Spacing   = AdaptiveSpacing.Medium
        };

        var shown = steps.Take(MaxStepsInReasoningCard).ToList();
        for (int i = 0; i < shown.Count; i++)
        {
            details.Items.Add(BuildReasoningStep(i + 1, shown[i]));
        }

        if (steps.Count > MaxStepsInReasoningCard)
        {
            details.Items.Add(new AdaptiveTextBlock
            {
                Text     = $"… {steps.Count - MaxStepsInReasoningCard} more step(s) omitted.",
                Size     = AdaptiveTextSize.Small,
                IsSubtle = true,
                Wrap     = true,
                Spacing  = AdaptiveSpacing.Medium
            });
        }

        var subtitle = steps.Count == 1 ? "1 step" : $"{steps.Count} steps";

        var showActionSet = new AdaptiveActionSet
        {
            Id = "showStepsBar",
            Actions =
            {
                new AdaptiveToggleVisibilityAction
                {
                    Title = "Show steps",
                    TargetElements =
                    {
                        new AdaptiveTargetElement(detailsId,      isVisible: true),
                        new AdaptiveTargetElement("showStepsBar", isVisible: false),
                        new AdaptiveTargetElement("hideStepsBar", isVisible: true)
                    }
                }
            }
        };

        var hideActionSet = new AdaptiveActionSet
        {
            Id        = "hideStepsBar",
            IsVisible = false,
            Actions =
            {
                new AdaptiveToggleVisibilityAction
                {
                    Title = "Hide steps",
                    TargetElements =
                    {
                        new AdaptiveTargetElement(detailsId,      isVisible: false),
                        new AdaptiveTargetElement("showStepsBar", isVisible: true),
                        new AdaptiveTargetElement("hideStepsBar", isVisible: false)
                    }
                }
            }
        };

        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                HeaderBar("💭", "Reasoning", subtitle, AdaptiveContainerStyle.Default),
                showActionSet,
                hideActionSet,
                details
            }
        };

        return AsAttachment(card);
    }

    private static AdaptiveContainer BuildReasoningStep(int index, ThinkingStep step)
    {
        var (icon, kindLabel) = step.Kind switch
        {
            "Function"        => ("🛠️", "Function"),
            "CodeInterpreter" => ("🐍", "Code Interpreter"),
            _                 => ("🔧", "MCP")
        };
        if (step.IsError) icon = "⚠️";

        var subtitle = string.IsNullOrEmpty(step.ServerLabel)
            ? kindLabel
            : $"{kindLabel} on `{step.ServerLabel}`";

        var header = new AdaptiveTextBlock
        {
            Text   = $"{icon} **{index}. {step.ToolName}**",
            Wrap   = true,
            Size   = AdaptiveTextSize.Small,
            Weight = AdaptiveTextWeight.Default
        };

        var sub = new AdaptiveTextBlock
        {
            Text     = subtitle,
            Wrap     = true,
            Size     = AdaptiveTextSize.Small,
            IsSubtle = true,
            Spacing  = AdaptiveSpacing.None
        };

        var container = new AdaptiveContainer
        {
            Separator = index > 1,
            Spacing   = AdaptiveSpacing.Small,
            Items     = { header, sub }
        };

        if (!string.IsNullOrWhiteSpace(step.Arguments) && step.Arguments != "{}")
        {
            container.Items.Add(SubtleLabel("Arguments"));
            container.Items.Add(CodeBlock(Truncate(step.Arguments, MaxArgsInReasoningStep)));
        }

        if (!string.IsNullOrWhiteSpace(step.Output))
        {
            container.Items.Add(SubtleLabel(step.IsError ? "Error" : "Output"));
            container.Items.Add(CodeBlock(Truncate(step.Output, MaxOutputInReasoningStep)));
        }

        return container;
    }

    // -------------------------------------------------------------------- help

    public static Attachment BuildHelpCard(IEnumerable<(string cmd, string description)> commands)
    {
        var rows = commands
            .Select(c => Row(c.cmd, c.description, codeLeft: true))
            .ToList<AdaptiveElement>();

        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                HeaderBar("💬", "Available commands", "Type one of these in chat", AdaptiveContainerStyle.Default),
                new AdaptiveContainer { Items = rows }
            }
        };
        return AsAttachment(card);
    }

    // -------------------------------------------------------------------- info (agent / tokens)

    /// <summary>
    /// Two-column info card. Supply <paramref name="facts"/> as a sequence of
    /// (label, value) pairs. A label that starts with "---" renders as a
    /// section divider with the rest of the label as the section title.
    /// </summary>
    public static Attachment BuildInfoCard(string title, string? icon, IEnumerable<(string label, string value)> facts)
    {
        var body = new List<AdaptiveElement>
        {
            HeaderBar(icon ?? "ℹ️", title, null, AdaptiveContainerStyle.Default)
        };

        AdaptiveContainer? section = null;

        foreach (var (label, value) in facts)
        {
            if (label.StartsWith("---"))
            {
                if (section is not null) body.Add(section);
                section = new AdaptiveContainer { Spacing = AdaptiveSpacing.Medium };
                section.Items.Add(new AdaptiveTextBlock
                {
                    Text     = label.TrimStart('-', ' '),
                    Size     = AdaptiveTextSize.Small,
                    IsSubtle = true,
                    Weight   = AdaptiveTextWeight.Bolder,
                    Separator = true
                });
            }
            else
            {
                section ??= new AdaptiveContainer();
                section.Items.Add(Row(label, value, codeLeft: false));
            }
        }
        if (section is not null) body.Add(section);

        var card = new AdaptiveCard(Schema) { Body = body };
        return AsAttachment(card);
    }

    // ==================================================================== building blocks

    /// <summary>
    /// Coloured header bar at the top of every card. Combines emoji + bold
    /// title + optional subtle subtitle inside a single bleeding Container.
    /// </summary>
    private static AdaptiveContainer HeaderBar(string icon, string title, string? subtitle, AdaptiveContainerStyle style)
    {
        var titleStack = new AdaptiveContainer();
        titleStack.Items.Add(new AdaptiveTextBlock
        {
            Text   = title,
            Weight = AdaptiveTextWeight.Bolder,
            Size   = AdaptiveTextSize.Medium,
            Wrap   = true
        });
        if (!string.IsNullOrEmpty(subtitle))
        {
            titleStack.Items.Add(new AdaptiveTextBlock
            {
                Text     = subtitle,
                Size     = AdaptiveTextSize.Small,
                IsSubtle = true,
                Wrap     = true,
                Spacing  = AdaptiveSpacing.None
            });
        }

        return new AdaptiveContainer
        {
            Style = style,
            Bleed = true,
            Items =
            {
                new AdaptiveColumnSet
                {
                    Columns =
                    {
                        new AdaptiveColumn
                        {
                            Width      = "auto",
                            VerticalContentAlignment = AdaptiveVerticalContentAlignment.Center,
                            Items =
                            {
                                new AdaptiveTextBlock
                                {
                                    Text = icon,
                                    Size = AdaptiveTextSize.ExtraLarge
                                }
                            }
                        },
                        new AdaptiveColumn
                        {
                            Width = "stretch",
                            Spacing = AdaptiveSpacing.Medium,
                            VerticalContentAlignment = AdaptiveVerticalContentAlignment.Center,
                            Items = { titleStack }
                        }
                    }
                }
            }
        };
    }

    /// <summary>Compact key/value pair (bold label left, value right).</summary>
    private static AdaptiveColumnSet Row(string label, string value, bool codeLeft)
    {
        var labelBlock = new AdaptiveTextBlock
        {
            Text   = label,
            Weight = AdaptiveTextWeight.Bolder,
            Size   = AdaptiveTextSize.Small,
            Wrap   = true
        };
        if (codeLeft) labelBlock.FontType = AdaptiveFontType.Monospace;

        return new AdaptiveColumnSet
        {
            Spacing = AdaptiveSpacing.Small,
            Columns =
            {
                new AdaptiveColumn
                {
                    Width = "120px",
                    Items = { labelBlock }
                },
                new AdaptiveColumn
                {
                    Width = "stretch",
                    Items =
                    {
                        new AdaptiveTextBlock
                        {
                            Text = value,
                            Size = AdaptiveTextSize.Small,
                            Wrap = true
                        }
                    }
                }
            }
        };
    }

    private static AdaptiveContainer KvSection(IEnumerable<(string label, string value)> rows)
    {
        var c = new AdaptiveContainer { Spacing = AdaptiveSpacing.Medium };
        foreach (var (l, v) in rows) c.Items.Add(Row(l, v, codeLeft: false));
        return c;
    }

    private static AdaptiveColumn StatColumn(string label, string value)
        => new AdaptiveColumn
        {
            Width = "stretch",
            Items =
            {
                new AdaptiveTextBlock
                {
                    Text                = label,
                    Size                = AdaptiveTextSize.Small,
                    IsSubtle            = true,
                    HorizontalAlignment = AdaptiveHorizontalAlignment.Center,
                    Wrap                = true
                },
                new AdaptiveTextBlock
                {
                    Text                = value,
                    Weight              = AdaptiveTextWeight.Bolder,
                    HorizontalAlignment = AdaptiveHorizontalAlignment.Center,
                    Spacing             = AdaptiveSpacing.None,
                    Wrap                = true
                }
            }
        };

    /// <summary>Monospace code/JSON block inside an emphasized container.</summary>
    private static AdaptiveContainer CodeBlock(string text)
        => new AdaptiveContainer
        {
            Style = AdaptiveContainerStyle.Emphasis,
            Items =
            {
                new AdaptiveTextBlock
                {
                    Text     = text,
                    Wrap     = true,
                    FontType = AdaptiveFontType.Monospace,
                    Size     = AdaptiveTextSize.Small
                }
            }
        };

    private static AdaptiveTextBlock SubtleLabel(string text)
        => new()
        {
            Text     = text,
            Wrap     = true,
            Size     = AdaptiveTextSize.Small,
            IsSubtle = true,
            Weight   = AdaptiveTextWeight.Bolder,
            Spacing  = AdaptiveSpacing.Medium
        };

    private static Attachment AsAttachment(AdaptiveCard card)
        => new() { ContentType = AdaptiveCard.ContentType, Content = JsonNode.Parse(card.ToJson()) };

    private static string PrettyJson(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "(no arguments)";
        try { return JObject.Parse(raw).ToString(Newtonsoft.Json.Formatting.Indented); }
        catch { return raw; }
    }

    private static string Truncate(string text, int max)
        => text.Length > max ? text.Substring(0, max) + "\n…(truncated)" : text;
}
