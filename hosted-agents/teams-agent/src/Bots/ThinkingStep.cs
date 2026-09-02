namespace AgentChat.Bots;

/// <summary>
/// One unit of work performed by the agent during a turn — a function call,
/// MCP tool invocation, or similar. Captured into a per-turn list and
/// rendered as a collapsible "Reasoning" Adaptive Card attached to the
/// final streaming message when <c>ConversationState.ShowThinking</c> is on.
///
/// Arguments and output are stored already-truncated; the recorder caps
/// each field so the final card stays comfortably under Bot Connector's
/// ~28 KB activity limit even with many steps.
/// </summary>
public sealed record ThinkingStep(
    string Kind,           // "Function" | "MCP" | "CodeInterpreter"
    string ToolName,
    string? ServerLabel,   // MCP server label, null for function tools
    string Arguments,      // truncated JSON or "{}"
    string Output,         // truncated output, "(no output)" sentinel, or error preview
    bool IsError);
