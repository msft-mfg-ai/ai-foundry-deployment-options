using System.Net;
using System.Text;
using Azure.Core;
using System.ClientModel.Primitives;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using AgentChat.Foundry;
using AgentChat.Services;

namespace AgentChat.Tests;

internal sealed class StaticTokenCredential : TokenCredential
{
    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        => new("test-token", DateTimeOffset.UtcNow.AddHours(1));

    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
        => new(GetToken(requestContext, cancellationToken));
}

internal sealed class HandlerHttpClientFactory(HttpMessageHandler handler) : IHttpClientFactory
{
    public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
}

internal static class TestServices
{
    public static AgentService AgentService(HttpMessageHandler handler, string defaultProjectEndpoint = "https://default-host.services.ai.azure.com/api/projects/default-project")
    {
        var cfg = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Foundry:ProjectEndpoint"] = defaultProjectEndpoint,
            ["Foundry:CatalogCacheSeconds"] = "0"
        }).Build();

        return new AgentService(
            NullLogger<AgentService>.Instance,
            cfg,
            new HandlerHttpClientFactory(handler),
            new StaticTokenCredential());
    }

    public static IConfiguration Config(params KeyValuePair<string, string?>[] values)
        => new ConfigurationBuilder().AddInMemoryCollection(values).Build();

    public static string WebRootPath()
    {
        var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "src", "AgentChat", "wwwroot")))
            dir = dir.Parent;
        return dir is null
            ? Path.GetFullPath("src/AgentChat/wwwroot")
            : Path.Combine(dir.FullName, "src", "AgentChat", "wwwroot");
    }
}

internal sealed class RecordingFoundryHandler : HttpMessageHandler
{
    private readonly Queue<Func<HttpRequestMessage, HttpResponseMessage>> _responders = new();
    public List<(string Method, string Url, string Body)> Requests { get; } = new();
    public List<string?> ObservedUserAuthScopes { get; } = new();
    public List<string?> AuthorizationHeaders { get; } = new();
    public List<string?> UserIdentityHeaders { get; } = new();

    public void EnqueueJson(HttpStatusCode status, string json)
        => _responders.Enqueue(_ => new HttpResponseMessage(status)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        });

    public void EnqueueSse(params string[] eventJsonPayloads)
        => _responders.Enqueue(_ =>
        {
            var sb = new StringBuilder();
            foreach (var payload in eventJsonPayloads)
            {
                sb.Append("data: ").Append(payload).Append("\n\n");
            }
            sb.Append("data: [DONE]\n\n");
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(sb.ToString(), Encoding.UTF8, "text/event-stream")
            };
        });

    public AgentClientCache ToClientCache(AgentService agents)
        => new(agents, endpoint => new FoundryClient(
            endpoint,
            agents.Credential,
            transport: new HttpClientPipelineTransport(new HttpClient(this, disposeHandler: false))));

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
        Requests.Add((request.Method.Method, request.RequestUri!.ToString(), body));
        ObservedUserAuthScopes.Add(FoundryUserAuthScope.Current);
        AuthorizationHeaders.Add(request.Headers.Authorization?.ToString());
        UserIdentityHeaders.Add(request.Headers.TryGetValues("x-ms-user-identity", out var vals)
            ? string.Join(",", vals)
            : null);
        if (_responders.Count == 0)
        {
            return new HttpResponseMessage(HttpStatusCode.NotFound)
            {
                Content = new StringContent($"No fake Foundry response queued for {request.Method} {request.RequestUri}")
            };
        }
        return _responders.Dequeue()(request);
    }
}

internal sealed class CatalogHandler : HttpMessageHandler
{
    private readonly IReadOnlyList<string> _agentNames;
    public List<string> RequestedProjects { get; } = new();
    public List<string?> ObservedUserAuthScopes { get; } = new();

    public CatalogHandler(params string[] agentNames)
    {
        _agentNames = agentNames.Length == 0 ? Array.Empty<string>() : agentNames;
    }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var url = request.RequestUri!.ToString();
        var marker = "/agents?";
        var idx = url.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        RequestedProjects.Add(idx < 0 ? url : url[..idx]);
        ObservedUserAuthScopes.Add(FoundryUserAuthScope.Current);

        var data = string.Join(",", _agentNames.Select(name => $$"""
        {
          "name": "{{name}}",
          "versions": {
            "latest": {
              "version": "1",
              "description": "Description for {{name}}",
              "status": "active",
              "definition": { "model": "gpt-4o" }
            }
          }
        }
        """));

        return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK)
        {
            Content = new StringContent($"{{\"data\":[{data}]}}")
        });
    }
}
