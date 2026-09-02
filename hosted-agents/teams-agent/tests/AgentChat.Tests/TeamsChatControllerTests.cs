using AgentChat.Auth;
using AgentChat.Controllers;
using AgentChat.Services;
using FluentAssertions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Xunit;

namespace AgentChat.Tests;

public class TeamsChatControllerTests
{
    [Fact]
    public void Page_serves_bundled_teams_tab_for_valid_fixed_agent_route()
    {
        var controller = MakeController();

        var result = controller.Page("host-a", "project-a", "Agent One");

        var file = result.Should().BeOfType<PhysicalFileResult>().Subject;
        file.FileName.Should().EndWith(Path.Combine("teams-chat", "index.html"));
    }

    [Fact]
    public void Page_rejects_unsafe_foundry_host()
    {
        var controller = MakeController();

        var result = controller.Page("https%3A%2F%2Fevil.example", "project-a", "Agent");

        result.Should().BeOfType<BadRequestObjectResult>();
    }

    [Fact]
    public void Auth_config_returns_public_client_values_without_secret()
    {
        var controller = MakeController();

        var result = controller.AuthConfig();

        var ok = result.Should().BeOfType<OkObjectResult>().Subject;
        var json = System.Text.Json.JsonSerializer.Serialize(ok.Value);
        json.Should().Contain("client-id");
        json.Should().Contain("api://client-id/access_as_user");
        json.Should().NotContain("client-secret");
    }

    [Fact]
    public void Chat_api_actions_require_teams_tab_policy()
    {
        var methods = typeof(TeamsChatController).GetMethods()
            .Where(method => method.Name is "Context" or "CreateConversation" or "StreamMessage" or "DeleteConversation");

        methods.Should().OnlyContain(method =>
            method.GetCustomAttributes(typeof(AuthorizeAttribute), inherit: true)
                .Cast<AuthorizeAttribute>()
                .Any(attribute => attribute.Policy == TeamsTabAuthOptions.Policy));
    }

    private static TeamsChatController MakeController()
    {
        var catalog = new CatalogHandler();
        var agents = TestServices.AgentService(catalog);
        var chat = new ChatSessionService(
            agents,
            new AgentClientCache(agents),
            NullLogger<ChatSessionService>.Instance);
        var options = new TeamsTabAuthOptions
        {
            Enabled = true,
            TenantId = "tenant-id",
            ClientId = "client-id",
            ClientSecret = "client-secret",
            IdentifierUri = "api://client-id",
            PublicOrigin = "https://proxy.example.com"
        };
        var environment = new Mock<IWebHostEnvironment>();
        environment.SetupGet(value => value.WebRootPath).Returns(TestServices.WebRootPath());
        var controller = new TeamsChatController(
            chat,
            options,
            environment.Object,
            new TeamsTabTokenService(options));
        controller.ControllerContext = new ControllerContext { HttpContext = new DefaultHttpContext() };
        return controller;
    }
}
