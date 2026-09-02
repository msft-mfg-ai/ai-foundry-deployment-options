using System.Text;
using Microsoft.Agents.Core.Models;
using OpenAI.Responses;

namespace AgentChat.Bots;

/// <summary>
/// Render Foundry Responses-API message annotations (url_citation,
/// file_citation, container_file_citation, file_path) into markdown-friendly
/// text + helpers for sending attachments to Bot Framework channels.
/// </summary>
public static class AgentMessageRenderer
{
    /// <summary>
    /// Rewrite annotations in place using their character index ranges.
    /// Walk replacements in descending start order so earlier replacements
    /// don't invalidate later indices. File-path annotations are appended
    /// as footnotes since they have no inline range.
    /// </summary>
    public static string ApplyAnnotations(string text, IEnumerable<ResponseMessageAnnotation> annotations)
    {
        if (string.IsNullOrEmpty(text) || annotations is null) return text;

        var ranged    = new List<(int Start, int End, string Replacement)>();
        var footnotes = new List<string>();

        foreach (var ann in annotations)
        {
            switch (ann)
            {
                case UriCitationMessageAnnotation url:
                    var title = string.IsNullOrEmpty(url.Title) ? "source" : url.Title;
                    ranged.Add((url.StartIndex, url.EndIndex, $" [[{title}]]({url.Uri})"));
                    break;
                case ContainerFileCitationMessageAnnotation cf:
                    ranged.Add((cf.StartIndex, cf.EndIndex, $" *(file: {cf.Filename ?? cf.FileId})*"));
                    break;
                case FileCitationMessageAnnotation fc:
                    ranged.Add((fc.Index, fc.Index, $" *(cf. {fc.Filename ?? fc.FileId})*"));
                    break;
                case FilePathMessageAnnotation fp:
                    footnotes.Add($"file: {fp.FileId}");
                    break;
            }
        }

        foreach (var (start, end, repl) in ranged.OrderByDescending(r => r.Start))
        {
            if (start < 0 || end > text.Length || start > end) continue;
            text = text.Substring(0, start) + repl + text.Substring(end);
        }

        if (footnotes.Count > 0)
        {
            var sb = new StringBuilder(text);
            sb.AppendLine();
            sb.AppendLine();
            foreach (var fn in footnotes) sb.AppendLine("• " + fn);
            text = sb.ToString();
        }

        return text;
    }

    /// <summary>Build a text-file attachment from a string (used for long tool outputs).</summary>
    public static Attachment TextAsFile(string filename, string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        return new Attachment
        {
            Name        = filename,
            ContentType = "text/plain",
            ContentUrl  = $"data:text/plain;base64,{Convert.ToBase64String(bytes)}"
        };
    }
}
