using System.Text.RegularExpressions;

namespace AgentChat.Bots;

/// <summary>
/// Builds short, human-friendly informative-update strings for tool calls so
/// users can see what the agent is doing in real time (Teams 1:1 streaming
/// "informative" slot — the blue progress bar). Capped well below the 1 KB
/// Teams limit and stable across runs (no jitter / no timestamps).
///
/// Each category exposes a small pool of playful phrases; the caller picks
/// one via <see cref="Pick"/> using an integer index that the heartbeat loop
/// increments over time. This gives the user a sense of "activity happening"
/// even while a single tool call is in flight for many seconds.
/// </summary>
internal static class ThinkingStatus
{
    private const int MaxLen = 240;

    // ---- Rotating phrase pools ---------------------------------------------
    // Each pool has 15 entries so a full 60-second wait at the 4-second
    // heartbeat cadence never repeats a phrase. Ordering matters — the
    // rotation is deterministic (index++ % pool.Length), so we frontload
    // the friendliest / most on-topic phrases first.

    /// <summary>Generic "waiting on the model" phrases used when no tool is active.</summary>
    public static readonly string[] Generic =
    {
        "🧠 Thinking…",
        "💭 Working on it…",
        "🔄 Still thinking…",
        "⏳ Hang tight…",
        "🧩 Putting the pieces together…",
        "🚀 Almost there…",
        "🤔 Mulling it over…",
        "📝 Drafting a response…",
        "🎯 Zeroing in on an answer…",
        "🧠 Warming up the neurons…",
        "🔍 Reviewing what you asked…",
        "✨ Cooking up something good…",
        "🛠️ Assembling the response…",
        "📚 Consulting my training…",
        "🧭 Charting the best path…",
    };

    /// <summary>Model-side reasoning (chain-of-thought) is in progress.</summary>
    public static readonly string[] Reasoning =
    {
        "🧠 Reasoning through this…",
        "🤔 Connecting the dots…",
        "🧩 Piecing it together…",
        "⚖️ Weighing the options…",
        "🔎 Examining the details…",
        "🧠 Following the logic…",
        "💡 Considering alternatives…",
        "🗺️ Mapping out the answer…",
        "🎯 Narrowing things down…",
        "📐 Checking my work…",
        "🧮 Working through the math…",
        "🧠 Reading between the lines…",
        "🔄 Second-guessing myself…",
        "📊 Comparing possibilities…",
        "🧠 Sanity-checking the logic…",
    };

    /// <summary>Web search / Bing grounding tool is running.</summary>
    public static readonly string[] WebSearch =
    {
        "🔍 Scouring the web…",
        "🌐 Chasing down sources…",
        "🔎 Following breadcrumbs online…",
        "🕵️ Investigating the internet…",
        "📡 Pulling fresh results…",
        "🌍 Casting a wide net…",
        "🔗 Reading web pages…",
        "📰 Checking recent articles…",
        "🧭 Navigating the search results…",
        "🗞️ Skimming the headlines…",
        "🔍 Cross-referencing sources…",
        "🌐 Looking that up online…",
        "📚 Pulling context from the web…",
        "🕸️ Crawling for details…",
        "🔎 Digging deeper on the web…",
    };

    /// <summary>File search / RAG lookup is running.</summary>
    public static readonly string[] FileSearch =
    {
        "📄 Digging through documents…",
        "📚 Skimming the archives…",
        "🔍 Searching your files…",
        "📑 Cross-referencing sources…",
        "🗂️ Sifting through folders…",
        "📖 Reading the relevant chapters…",
        "🔎 Locating the right passage…",
        "📄 Comparing document sections…",
        "🧾 Checking the details…",
        "📚 Consulting the knowledge base…",
        "📝 Pulling supporting evidence…",
        "🗄️ Rummaging through the index…",
        "📄 Retrieving matches…",
        "🔍 Verifying quotes…",
        "📑 Assembling citations…",
    };

    /// <summary>Code interpreter is running.</summary>
    public static readonly string[] CodeInterpreter =
    {
        "💻 Running the numbers…",
        "🐍 Executing Python…",
        "🧮 Crunching data…",
        "⚙️ Working through the code…",
        "📊 Computing results…",
        "🧪 Testing the hypothesis…",
        "🔢 Doing the math…",
        "💻 Compiling the logic…",
        "🖥️ Simulating the outcome…",
        "🐍 Iterating on the script…",
        "📈 Plotting the trend…",
        "🔍 Inspecting the data…",
        "⌨️ Writing a quick script…",
        "💾 Wrangling the dataset…",
        "🧰 Trying a different approach…",
    };

    /// <summary>Image generation is in progress.</summary>
    public static readonly string[] ImageGeneration =
    {
        "🎨 Painting pixels…",
        "🖼️ Rendering image…",
        "✨ Composing something visual…",
        "🖌️ Adding brushstrokes…",
        "🎨 Mixing the palette…",
        "📐 Sketching the layout…",
        "🖼️ Refining the details…",
        "🌈 Choosing the colors…",
        "✏️ Roughing out the shapes…",
        "🎭 Setting the mood…",
        "🔆 Adjusting the lighting…",
        "🖼️ Composing the frame…",
        "🎨 Adding the finishing touches…",
        "✨ Polishing the result…",
        "🖌️ Almost ready to reveal…",
    };

    /// <summary>MCP tool catalog discovery.</summary>
    public static readonly string[] McpListTools =
    {
        "🧰 Discovering available tools…",
        "🔧 Loading tool catalog…",
        "📋 Enumerating capabilities…",
        "🧰 Checking what I can do…",
        "🔍 Inspecting the toolset…",
        "🗂️ Cataloging the tools…",
        "🧭 Mapping the tool surface…",
        "🔌 Connecting to tool server…",
        "📦 Unpacking tool definitions…",
        "🛠️ Reviewing the toolbox…",
        "🧰 Refreshing the catalog…",
        "🔧 Loading tool schemas…",
        "📋 Reading tool descriptions…",
        "🧰 Getting the lay of the land…",
        "🔍 Confirming what's available…",
    };

    // ---- Live "starting" phrases (single string, not rotating) --------------

    /// <summary>Status to show as a function tool is about to be dispatched.</summary>
    public static string ForFunctionCall(string toolName)
        => Trim($"{Emoji(toolName)} {Humanize(toolName)}…");

    /// <summary>Status to show after an MCP tool has completed server-side.</summary>
    public static string ForMcpCallCompleted(string toolName, string? serverLabel)
    {
        var server = string.IsNullOrWhiteSpace(serverLabel) ? "" : $" ({serverLabel})";
        return Trim($"{Emoji(toolName)} {Humanize(toolName)}{server} ✓");
    }

    /// <summary>Status to show as an MCP tool is about to be dispatched by Foundry.</summary>
    public static string ForMcpCallInProgress(string? toolName, string? serverLabel)
    {
        var name = string.IsNullOrWhiteSpace(toolName) ? "MCP tool" : Humanize(toolName!);
        var server = string.IsNullOrWhiteSpace(serverLabel) ? "" : $" ({serverLabel})";
        return Trim($"{Emoji(toolName ?? "mcp")} Calling {name}{server}…");
    }

    /// <summary>Status to show when several function calls are queued.</summary>
    public static string ForBatch(int count)
        => Trim($"🔧 Calling {count} tools…");

    /// <summary>
    /// Deterministically pick a phrase from a rotating pool. The heartbeat
    /// loop supplies a monotonically-increasing index so the visible text
    /// changes every tick without repeating too tightly.
    /// </summary>
    public static string Pick(string[] pool, int index)
    {
        if (pool.Length == 0) return "";
        var i = ((index % pool.Length) + pool.Length) % pool.Length;
        return pool[i];
    }

    /// <summary>
    /// Pick a representative emoji for common tool name patterns. Falls back
    /// to a generic wrench. Pattern matching is intentionally cheap; we lean
    /// on substring matches rather than a hardcoded list.
    /// </summary>
    internal static string Emoji(string toolName)
    {
        if (string.IsNullOrEmpty(toolName)) return "🔧";
        var n = toolName.ToLowerInvariant();
        if (Contains(n, "search", "bing", "google", "web"))                      return "🔍";
        if (Contains(n, "calendar", "meeting", "event", "schedule"))             return "📅";
        if (Contains(n, "mail", "email", "outlook", "send_message", "sendmsg")) return "📧";
        if (Contains(n, "file", "doc", "drive", "sharepoint", "onedrive"))       return "📄";
        if (Contains(n, "code", "exec", "run", "shell", "bash", "python"))       return "💻";
        if (Contains(n, "db", "sql", "kusto", "cosmos", "postgres"))             return "🗄️";
        if (Contains(n, "weather", "forecast"))                                  return "🌤️";
        if (Contains(n, "image", "photo", "render", "generate"))                 return "🎨";
        if (Contains(n, "translate", "language"))                                return "🌐";
        if (Contains(n, "math", "calc", "compute"))                              return "🧮";
        if (Contains(n, "user", "people", "contact", "directory"))               return "👤";
        if (Contains(n, "github", "git", "repo", "pr", "issue"))                 return "🐙";
        if (Contains(n, "mcp"))                                                   return "🧰";
        return "🔧";
    }

    /// <summary>
    /// Convert a snake_case / camelCase / kebab-case tool name into a
    /// reader-friendly phrase, e.g. <c>get_weather</c> → <c>Get weather</c>,
    /// <c>searchDocuments</c> → <c>Search documents</c>.
    /// </summary>
    internal static string Humanize(string toolName)
    {
        if (string.IsNullOrEmpty(toolName)) return "Running tool";

        // Split camelCase/PascalCase boundaries.
        var spaced = Regex.Replace(toolName, "(?<=[a-z0-9])([A-Z])", " $1");
        // Replace underscores / hyphens / dots with spaces.
        spaced = spaced.Replace('_', ' ').Replace('-', ' ').Replace('.', ' ');
        // Collapse whitespace and trim.
        spaced = Regex.Replace(spaced, "\\s+", " ").Trim();
        if (spaced.Length == 0) return "Running tool";
        return char.ToUpperInvariant(spaced[0]) + spaced.Substring(1).ToLowerInvariant();
    }

    private static bool Contains(string s, params string[] needles)
    {
        foreach (var n in needles)
            if (s.Contains(n)) return true;
        return false;
    }

    private static string Trim(string s) => s.Length <= MaxLen ? s : s.Substring(0, MaxLen - 1) + "…";
}
