using System.Text.RegularExpressions;

namespace AgentChat.Bots;

public static partial class GeneratedFileLinkParser
{
    private static readonly HashSet<string> FileExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".pptx", ".pdf", ".docx", ".xlsx", ".csv", ".zip",
        ".png", ".jpg", ".jpeg", ".gif", ".txt"
    };

    public static IReadOnlyList<GeneratedFileLink> Extract(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return [];

        var files = new List<GeneratedFileLink>();
        foreach (Match match in MarkdownLink().Matches(text))
        {
            var label = match.Groups["label"].Value.Trim();
            var rawUrl = match.Groups["url"].Value.Trim();
            if (!Uri.TryCreate(rawUrl, UriKind.Absolute, out var uri)) continue;

            var extension = Path.GetExtension(uri.AbsolutePath);
            var looksLikeDownload = label.Contains("download", StringComparison.OrdinalIgnoreCase);
            if (!FileExtensions.Contains(extension) && !looksLikeDownload) continue;

            var name = Path.GetFileName(Uri.UnescapeDataString(uri.AbsolutePath));
            if (string.IsNullOrWhiteSpace(name) || !FileExtensions.Contains(Path.GetExtension(name)))
            {
                name = InferName(label);
            }

            if (files.Any(file => string.Equals(file.Url, uri.AbsoluteUri, StringComparison.Ordinal)))
            {
                continue;
            }
            files.Add(new GeneratedFileLink(name, uri.AbsoluteUri));
        }

        return files;
    }

    private static string InferName(string label)
    {
        if (label.Contains("powerpoint", StringComparison.OrdinalIgnoreCase)
            || label.Contains("presentation", StringComparison.OrdinalIgnoreCase))
        {
            return "presentation.pptx";
        }
        if (label.Contains("spreadsheet", StringComparison.OrdinalIgnoreCase)
            || label.Contains("excel", StringComparison.OrdinalIgnoreCase))
        {
            return "spreadsheet.xlsx";
        }
        if (label.Contains("document", StringComparison.OrdinalIgnoreCase)
            || label.Contains("word", StringComparison.OrdinalIgnoreCase))
        {
            return "document.docx";
        }
        if (label.Contains("pdf", StringComparison.OrdinalIgnoreCase))
        {
            return "document.pdf";
        }
        return "generated-file.bin";
    }

    [GeneratedRegex(@"\[(?<label>[^\]]+)\]\((?<url>https://[^)\s]+)\)", RegexOptions.IgnoreCase)]
    private static partial Regex MarkdownLink();
}

public sealed record GeneratedFileLink(string Name, string Url);
