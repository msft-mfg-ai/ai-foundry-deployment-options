using Microsoft.AspNetCore.Http;
using Yarp.ReverseProxy.Forwarder;

namespace AgentChat.Passthrough;

/// <summary>
/// Rewrites an inbound request targeting
/// <c>/api/passthrough/{foundry}/{project}/{agent}</c> into the matching
/// Foundry Activity Protocol URL:
/// <c>https://{foundry}.services.ai.azure.com/api/projects/{project}/agents/{agent}/endpoint/protocols/activityprotocol</c>
/// while preserving the original query string (notably <c>api-version</c>),
/// request body, and <c>Authorization</c> header. This is a pure passthrough:
/// the JWT minted by Bot Service for the Foundry agent SP is forwarded
/// untouched so Foundry can validate it normally.
/// </summary>
internal sealed class ActivityProtocolTransformer : HttpTransformer
{
    private readonly string _project;
    private readonly string _agent;

    public ActivityProtocolTransformer(string project, string agent)
    {
        _project = project;
        _agent = agent;
    }

    public override async ValueTask TransformRequestAsync(
        HttpContext httpContext,
        HttpRequestMessage proxyRequest,
        string destinationPrefix,
        CancellationToken cancellationToken)
    {
        // Base copies the body and most headers (incl. Authorization) and
        // drops hop-by-hop headers.
        await base.TransformRequestAsync(httpContext, proxyRequest, destinationPrefix, cancellationToken);

        var encodedProject = Uri.EscapeDataString(_project);
        var encodedAgent = Uri.EscapeDataString(_agent);
        var path = $"/api/projects/{encodedProject}/agents/{encodedAgent}/endpoint/protocols/activityprotocol";
        var query = httpContext.Request.QueryString.ToUriComponent();

        proxyRequest.RequestUri = new Uri(destinationPrefix + path + query);

        // Force HttpClient to derive the Host header from the new RequestUri
        // rather than echoing the inbound proxy host (which would be the
        // container app FQDN and confuse Foundry's TLS / authority checks).
        proxyRequest.Headers.Host = null;
    }
}
