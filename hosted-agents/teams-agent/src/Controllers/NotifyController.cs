using AgentChat.Bots;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Core.Models;
using Microsoft.Agents.Hosting.AspNetCore;

namespace AgentChat.Controllers;

/// <summary>
/// Proactive messaging endpoint. POST a JSON body { conversationId, text } and
/// the bot pushes the text to the recorded conversation using
/// <c>ChannelAdapter.ContinueConversationAsync</c>.
///
/// Requires that the bot has seen at least one activity from that conversation
/// (so we've stored its ConversationReference).
/// </summary>
[ApiController]
[Route("api/notify")]
public class NotifyController : ControllerBase
{
    private readonly ConversationStore _store;
    private readonly IChannelAdapter _adapter;
    private readonly IConfiguration _config;
    private readonly ILogger<NotifyController> _logger;

    public NotifyController(
        ConversationStore store,
        IChannelAdapter adapter,
        IConfiguration config,
        ILogger<NotifyController> logger)
    {
        _store    = store;
        _adapter  = adapter;
        _config   = config;
        _logger   = logger;
    }

    public record NotifyRequest(string ConversationId, string Text);

    [HttpPost]
    public async Task<IActionResult> Notify([FromBody] NotifyRequest req, CancellationToken ct)
    {
        var state = await _store.TryGetAsync(req.ConversationId, ct);
        if (state?.ConversationReference is null)
            return NotFound("Conversation unknown — no message has been received yet.");

        var botAppId = _config["MicrosoftAppId"] ?? "";

        // TODO: The string-appId overload is [Obsolete] in the M365 Agents
        // SDK in favor of a ClaimsIdentity-based overload. Migrating requires
        // persisting the bot's appId (per-route EffectiveProxyAppId) alongside
        // the ConversationReference in ConversationState so we can synthesize
        // the right ClaimsIdentity at notify time — today NotifyController
        // reads a single MicrosoftAppId that predates the multi-bot design
        // and is effectively broken for multi-bot deployments. Tracked for
        // follow-up after Slice 5 soak; suppressing the warning locally.
#pragma warning disable CS0618 // Type or member is obsolete
        await _adapter.ContinueConversationAsync(
            botAppId,
            state.ConversationReference,
            async (turnContext, innerCt) =>
            {
                await turnContext.SendActivityAsync(MessageFactory.Text(req.Text), innerCt);
            },
            ct);
#pragma warning restore CS0618

        return Ok(new { sent = true });
    }

    [HttpGet]
    public IActionResult List()
    {
        // Enumeration would require a Cosmos query; not exposed via IStorage.
        return Ok(new { note = "Pass a conversationId from Bot Framework logs / App Insights to POST." });
    }
}

