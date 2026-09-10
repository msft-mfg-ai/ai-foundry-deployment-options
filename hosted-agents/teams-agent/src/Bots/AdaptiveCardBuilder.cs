using System.Text.Json.Nodes;
using AdaptiveCards;
using Microsoft.Agents.Core.Models;

namespace AgentChat.Bots;

public static class AdaptiveCardBuilder
{
    private static readonly AdaptiveSchemaVersion Schema = new(1, 5);

    public static Attachment BuildWelcomeCard(string agentName)
    {
        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                Header($"Hello from {agentName}"),
                new AdaptiveTextBlock
                {
                    Text = "I'm your Foundry-hosted assistant in Teams. I can:",
                    Wrap = true,
                },
                new AdaptiveContainer
                {
                    Items =
                    {
                        Row("Answer", "Help with questions and everyday tasks", monospaceLabel: false),
                        Row("Use tools", "Search the web and call configured MCP tools", monospaceLabel: false),
                        Row("Remember", "Keep context within this Teams conversation", monospaceLabel: false),
                        Row("Diagnose", "Show hosted runtime details and redacted diagnostics", monospaceLabel: false),
                    },
                },
                new AdaptiveTextBlock
                {
                    Text = "Send me a message to get started, or use `/help` to see commands.",
                    Wrap = true,
                    Spacing = AdaptiveSpacing.Medium,
                },
            },
        };
        return AsAttachment(card);
    }

    public static Attachment BuildHelpCard(
        IEnumerable<(string command, string description)> commands)
    {
        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                Header("Available commands"),
                new AdaptiveContainer
                {
                    Items = commands
                        .Select(command => Row(
                            command.command,
                            command.description,
                            monospaceLabel: true))
                        .Cast<AdaptiveElement>()
                        .ToList(),
                },
            },
        };
        return AsAttachment(card);
    }

    public static Attachment BuildInfoCard(
        string title,
        string? icon,
        IEnumerable<(string label, string value)> facts)
    {
        var body = new List<AdaptiveElement>
        {
            Header(string.IsNullOrWhiteSpace(icon) ? title : $"{icon} {title}"),
        };
        AdaptiveContainer? section = null;

        foreach (var (label, value) in facts)
        {
            if (label.StartsWith("---", StringComparison.Ordinal))
            {
                if (section is not null)
                {
                    body.Add(section);
                }
                section = new AdaptiveContainer { Spacing = AdaptiveSpacing.Medium };
                section.Items.Add(new AdaptiveTextBlock
                {
                    Text = label.TrimStart('-', ' '),
                    Size = AdaptiveTextSize.Small,
                    IsSubtle = true,
                    Weight = AdaptiveTextWeight.Bolder,
                    Separator = true,
                });
                continue;
            }

            section ??= new AdaptiveContainer();
            section.Items.Add(Row(label, value, monospaceLabel: false));
        }

        if (section is not null)
        {
            body.Add(section);
        }

        return AsAttachment(new AdaptiveCard(Schema) { Body = body });
    }

    public static Attachment BuildOAuthConsentCard(
        string toolboxName,
        string consentUrl)
    {
        var card = new AdaptiveCard(Schema)
        {
            Body =
            {
                Header("Sign-in required"),
                new AdaptiveTextBlock
                {
                    Text =
                        $"Foundry needs your permission before `{toolboxName}` can be used. Open the sign-in page, complete authentication, then return here.",
                    Wrap = true,
                },
            },
            Actions =
            {
                new AdaptiveOpenUrlAction
                {
                    Title = "Open sign-in page",
                    Url = new Uri(consentUrl),
                },
                new AdaptiveSubmitAction
                {
                    Title = "I've signed in",
                    Data = new { action = "oauth_consent_continue" },
                    Style = "positive",
                },
                new AdaptiveSubmitAction
                {
                    Title = "Cancel",
                    Data = new { action = "oauth_consent_cancel" },
                },
            },
        };

        return AsAttachment(card);
    }

    private static AdaptiveTextBlock Header(string text) => new()
    {
        Text = text,
        Weight = AdaptiveTextWeight.Bolder,
        Size = AdaptiveTextSize.Medium,
        Wrap = true,
    };

    private static AdaptiveColumnSet Row(
        string label,
        string value,
        bool monospaceLabel)
    {
        var labelBlock = new AdaptiveTextBlock
        {
            Text = label,
            Weight = AdaptiveTextWeight.Bolder,
            Size = AdaptiveTextSize.Small,
            Wrap = true,
            FontType = monospaceLabel ? AdaptiveFontType.Monospace : AdaptiveFontType.Default,
        };

        return new AdaptiveColumnSet
        {
            Spacing = AdaptiveSpacing.Small,
            Columns =
            {
                new AdaptiveColumn
                {
                    Width = "120px",
                    Items = { labelBlock },
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
                            Wrap = true,
                        },
                    },
                },
            },
        };
    }

    private static Attachment AsAttachment(AdaptiveCard card) => new()
    {
        ContentType = AdaptiveCard.ContentType,
        Content = JsonNode.Parse(card.ToJson()),
    };
}
