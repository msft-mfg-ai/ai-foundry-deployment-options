using AgentChat.Controllers;
using AgentChat.Services;
using FluentAssertions;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace AgentChat.Tests;

public class RegisterControllerTests
{
    private const string ProxyId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    private const string DirectId = "11111111-2222-3333-4444-555555555555";

    [Fact]
    public void Form_lists_currently_registered_agents()
    {
        var repo = new InMemoryRouteRepository();
        repo.AddSync(new BotRoute("existing-bot", ProxyId, DirectId, "aif-abc", "proj-abc"));
        var c = MakeController(repo);

        var r = (ContentResult)c.Form();

        r.StatusCode.Should().Be(200);
        r.Content.Should().Contain("existing-bot");
        r.Content.Should().Contain(ProxyId);
        r.Content.Should().Contain("form method=\"post\" action=\"/admin/register/preview\"");
    }

    [Fact]
    public void Form_shows_empty_state_when_no_routes()
    {
        var c = MakeController(new InMemoryRouteRepository());

        var r = (ContentResult)c.Form();

        r.Content.Should().Contain("No agents registered yet");
    }

    [Fact]
    public void Preview_renders_checklist_but_does_not_persist()
    {
        var repo = new InMemoryRouteRepository();
        var c = MakeController(repo);

        var r = (ContentResult)c.Preview(new RegisterController.RegisterForm
        {
            AgentName = "weather",
            ProxyAppId = ProxyId,
            FoundryHost = "aif-test",
            ProjectName = "proj-test",
        });

        r.StatusCode.Should().Be(200);
        r.Content.Should().Contain("Federated Identity Credential");
        r.Content.Should().Contain("az bot update");
        r.Content.Should().Contain("Azure AI User");
        r.Content.Should().Contain("/api/messages/aif-test/proj-test/weather");
        r.Content.Should().Contain("form method=\"post\" action=\"/admin/register/confirm\"");
        repo.GetAll().Should().BeEmpty("preview must not persist");
    }

    [Fact]
    public void Preview_rejects_invalid_agent_name()
    {
        var c = MakeController(new InMemoryRouteRepository());

        var r = (ContentResult)c.Preview(new RegisterController.RegisterForm
        {
            AgentName = "bad name with spaces",
            ProxyAppId = ProxyId,
        });

        r.StatusCode.Should().Be(400);
        r.Content.Should().Contain("agentName");
    }

    [Fact]
    public void Preview_rejects_non_guid_proxy_app_id()
    {
        var c = MakeController(new InMemoryRouteRepository());

        var r = (ContentResult)c.Preview(new RegisterController.RegisterForm
        {
            AgentName = "weather",
            ProxyAppId = "not-a-guid",
        });

        r.StatusCode.Should().Be(400);
        r.Content.Should().Contain("proxyAppId");
    }

    [Fact]
    public async Task Confirm_upserts_route_and_returns_success_page()
    {
        var repo = new InMemoryRouteRepository();
        var c = MakeController(repo);

        var r = (ContentResult)await c.Confirm(new RegisterController.RegisterForm
        {
            AgentName = "weather",
            ProxyAppId = ProxyId,
            DirectAppId = DirectId,
            FoundryHost = "aif-test",
            ProjectName = "proj-test",
        }, CancellationToken.None);

        r.StatusCode.Should().Be(200);
        r.Content.Should().Contain("Registered");
        r.Content.Should().Contain("weather");

        var route = repo.TryGet("weather");
        route.Should().NotBeNull();
        route!.ProxyAppId.Should().Be(ProxyId);
        route.DirectAppId.Should().Be(DirectId);
        route.FoundryHost.Should().Be("aif-test");
        route.ProjectName.Should().Be("proj-test");
    }

    [Fact]
    public async Task Confirm_rejects_invalid_input()
    {
        var repo = new InMemoryRouteRepository();
        var c = MakeController(repo);

        var r = (ContentResult)await c.Confirm(new RegisterController.RegisterForm
        {
            AgentName = "",
            ProxyAppId = ProxyId,
        }, CancellationToken.None);

        r.StatusCode.Should().Be(400);
        repo.GetAll().Should().BeEmpty();
    }

    [Fact]
    public void Form_falls_back_to_default_project_when_route_metadata_missing()
    {
        var repo = new InMemoryRouteRepository();
        // Legacy row seeded before FoundryHost/ProjectName were captured.
        repo.AddSync(new BotRoute("legacy-bot", ProxyId));
        var c = MakeController(repo, defaultEndpoint: "https://aif-abc.services.ai.azure.com/api/projects/proj-abc");

        var r = (ContentResult)c.Form();

        r.Content.Should().Contain("aif-abc");
        r.Content.Should().Contain("proj-abc");
        r.Content.Should().Contain("defaulted from Foundry:ProjectEndpoint");
    }

    private static RegisterController MakeController(IRouteRepository repo, string? defaultEndpoint = null)
    {
        var cfg = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["MicrosoftAppTenantId"] = "tenant-guid",
            ["AZURE_CLIENT_ID"] = "uami-guid",
            ["Foundry:ProjectEndpoint"] = defaultEndpoint,
        }).Build();
        var c = new RegisterController(repo, cfg, NullLogger<RegisterController>.Instance);
        c.ControllerContext = new ControllerContext { HttpContext = new DefaultHttpContext() };
        c.HttpContext.Request.Host = new HostString("test-host");
        return c;
    }
}
