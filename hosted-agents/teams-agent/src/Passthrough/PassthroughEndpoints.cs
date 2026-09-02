using System.Net;
using System.Net.Security;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Yarp.ReverseProxy.Forwarder;

namespace AgentChat.Passthrough;

/// <summary>
/// Wires the transparent reverse-proxy route
/// <c>POST /api/passthrough/{foundry}/{project}/{agent}</c> →
/// Foundry's Activity Protocol endpoint.
///
/// Bot Service is configured with msaAppId = Foundry agent SP and its
/// endpoint pointed at this URL. The JWT signed by Bot Service for the
/// Foundry agent SP is forwarded untouched; Foundry validates it the same
/// way it would for a direct (proxy-less) bot. The proxy contributes
/// nothing but a network hop and a path rewrite — useful when Foundry
/// public network access is disabled and Bot Service must reach Foundry
/// through a VNet-attached relay.
/// </summary>
public static class PassthroughEndpoints
{
    private const string RoutePattern = "/api/passthrough/{foundry}/{project}/{agent}";

    public static IServiceCollection AddActivityProtocolPassthrough(this IServiceCollection services)
    {
        services.AddHttpForwarder();

        // Single shared invoker — YARP's recommended pattern. No proxy, no
        // redirects, no decompression (forward bytes as-is), no cookies.
        services.AddSingleton(_ =>
        {
            var handler = new SocketsHttpHandler
            {
                UseProxy = false,
                AllowAutoRedirect = false,
                AutomaticDecompression = DecompressionMethods.None,
                UseCookies = false,
                ConnectTimeout = TimeSpan.FromSeconds(15),
                EnableMultipleHttp2Connections = true,
                ActivityHeadersPropagator = new ReverseProxyPropagator(System.Diagnostics.DistributedContextPropagator.Current),
            };
            return new HttpMessageInvoker(handler);
        });

        return services;
    }

    public static IEndpointRouteBuilder MapActivityProtocolPassthrough(this IEndpointRouteBuilder endpoints)
    {
        // Foundry streams Activity Protocol responses; allow long idle gaps
        // (model thinking time, tool execution) without YARP cancelling.
        var forwarderConfig = new ForwarderRequestConfig
        {
            ActivityTimeout = TimeSpan.FromMinutes(5),
        };

        endpoints.MapPost(RoutePattern, async (
            HttpContext ctx,
            IHttpForwarder forwarder,
            HttpMessageInvoker invoker,
            ILoggerFactory loggerFactory,
            string foundry,
            string project,
            string agent) =>
        {
            var logger = loggerFactory.CreateLogger("PassthroughEndpoints");

            // Basic shape guard. Foundry account names are alphanumeric +
            // dashes; reject anything that could form a different host.
            if (!IsSafeHostSegment(foundry))
            {
                logger.LogWarning("Passthrough rejected: invalid foundry segment {Foundry}", foundry);
                ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
                return;
            }

            var prefix = $"https://{foundry}.services.ai.azure.com";
            var transformer = new ActivityProtocolTransformer(project, agent);

            var error = await forwarder.SendAsync(ctx, prefix, invoker, forwarderConfig, transformer);

            if (error != ForwarderError.None)
            {
                var feature = ctx.Features.Get<IForwarderErrorFeature>();
                logger.LogError(feature?.Exception,
                    "Passthrough forward failed: error={Error} foundry={Foundry} project={Project} agent={Agent}",
                    error, foundry, project, agent);
            }
        });

        return endpoints;
    }

    internal static bool IsSafeHostSegment(string value)
    {
        if (string.IsNullOrEmpty(value) || value.Length > 63) return false;
        foreach (var c in value)
        {
            if (!(char.IsLetterOrDigit(c) || c == '-')) return false;
        }
        return true;
    }
}
