using System.Net;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using AgentChat.Auth;
using AgentChat.Controllers;
using AgentChat.Foundry;
using AgentChat.Services;
using FluentAssertions;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Identity.Web;
using Moq;
using Xunit;

namespace AgentChat.Tests;

public class ChatTestControllerTests
{
    [Fact]
    public async Task CreateConversation_with_foundry_scope_looks_up_agent_in_composed_project_endpoint()
    {
        var handler = new CatalogHandler();
        var controller = MakeController(handler);

        var result = await controller.CreateConversation(
            new ChatTestController.CreateConvRequest("missing", "host-b", "proj-b"),
            CancellationToken.None);

        result.Should().BeOfType<NotFoundObjectResult>();
        handler.RequestedProjects.Should().ContainSingle()
            .Which.Should().Be("https://host-b.services.ai.azure.com/api/projects/proj-b");
    }

    [Fact]
    public async Task CreateConversation_without_foundry_scope_uses_default_project_endpoint()
    {
        var handler = new CatalogHandler();
        var controller = MakeController(handler);

        var result = await controller.CreateConversation(
            new ChatTestController.CreateConvRequest("missing"),
            CancellationToken.None);

        result.Should().BeOfType<NotFoundObjectResult>();
        handler.RequestedProjects.Should().ContainSingle()
            .Which.Should().Be("https://default-host.services.ai.azure.com/api/projects/default-project");
    }

    [Fact]
    public async Task DeleteConversation_with_foundry_scope_looks_up_agent_in_composed_project_endpoint()
    {
        var handler = new CatalogHandler();
        var controller = MakeController(handler);

        var result = await controller.DeleteConversation("conv-1", "missing", "host-c", "proj-c", CancellationToken.None);

        result.Should().BeOfType<NotFoundObjectResult>();
        handler.RequestedProjects.Should().ContainSingle()
            .Which.Should().Be("https://host-c.services.ai.azure.com/api/projects/proj-c");
    }

    [Fact]
    public async Task StreamMessage_with_foundry_scope_looks_up_agent_in_composed_project_endpoint()
    {
        var handler = new CatalogHandler();
        var controller = MakeController(handler, withHttpContext: true);

        await controller.StreamMessage(
            new ChatTestController.MessageRequest("missing", "conv-1", "hello", "host-d", "proj-d"),
            CancellationToken.None);

        handler.RequestedProjects.Should().ContainSingle()
            .Which.Should().Be("https://host-d.services.ai.azure.com/api/projects/proj-d");
        controller.Response.Body.Position = 0;
        using var reader = new StreamReader(controller.Response.Body, Encoding.UTF8);
        (await reader.ReadToEndAsync()).Should().Contain("agent 'missing' not found");
    }

    [Fact]
    public async Task CreateConversation_rejects_partial_foundry_scope()
    {
        var handler = new CatalogHandler();
        var controller = MakeController(handler);

        var result = await controller.CreateConversation(
            new ChatTestController.CreateConvRequest("missing", "host-only", null),
            CancellationToken.None);

        result.Should().BeOfType<BadRequestObjectResult>();
        handler.RequestedProjects.Should().BeEmpty();
    }

    [Fact]
    public async Task Approval_resume_chains_with_previous_response_id_and_continues_to_final_output()
    {
        var catalog = new CatalogHandler("agent-a");
        var service = TestServices.AgentService(catalog);
        var foundry = new RecordingFoundryHandler();
        foundry.EnqueueSse(
            ResponseCreated("resp_approval"),
            "{\"type\":\"response.mcp_approval_requested\",\"approval_request_id\":\"mcpr_1\",\"server_label\":\"srv\",\"tool_name\":\"lookup\",\"tool_arguments\":\"{}\"}",
            ResponseCompleted("resp_approval"));
        foundry.EnqueueSse(
            ResponseCreated("resp_tool_result"),
            WebSearchDone("ws_1", "dog breeds and characteristics"),
            McpToolDone("mcp_1", "lookup", "srv", "tool says ok"),
            CodeInterpreterDone("ci_1", "print('created dogs.pptx')", "created dogs.pptx"),
            TextDelta("tool says ok"),
            ResponseCompleted("resp_tool_result"));
        var controller = MakeController(catalog, withHttpContext: true, clientCache: foundry.ToClientCache(service), service: service);

        await controller.StreamMessage(new ChatTestController.MessageRequest("agent-a", "conv-approval", "needs tool"), CancellationToken.None);
        var first = await ReadResponseAsync(controller);
        first.Should().Contain("event: approval");

        controller = MakeController(catalog, withHttpContext: true, clientCache: foundry.ToClientCache(service), service: service);
        await controller.StreamMessage(new ChatTestController.MessageRequest(
            "agent-a",
            "conv-approval",
            null,
            Approval: new ChatTestController.ApprovalRequest("mcpr_1", true)), CancellationToken.None);
        var second = await ReadResponseAsync(controller);

        second.Should().Contain("tool says ok");
        var toolEvents = SseEventData(second, "tool")
            .Select(data => JsonSerializer.Deserialize<Dictionary<string, string?>>(data)!)
            .ToList();
        toolEvents.Should().Contain(tool =>
            tool["kind"] == "web_search" &&
            tool["args"] == "dog breeds and characteristics");
        toolEvents.Should().Contain(tool =>
            tool["kind"] == "code_interpreter" &&
            tool["args"] == "print('created dogs.pptx')" &&
            tool["output"]!.Contains("created dogs.pptx"));
        var responseRequests = foundry.Requests.Where(r => r.Method == "POST" && r.Url.Contains("/responses")).ToList();
        responseRequests.Should().HaveCount(2);
        responseRequests[0].Body.Should().Contain("conversation");
        responseRequests[0].Body.Should().Contain("needs tool");
        responseRequests[1].Body.Should().Contain("previous_response_id");
        responseRequests[1].Body.Should().Contain("resp_approval");
        responseRequests[1].Body.Should().Contain("mcp_approval_response");
        responseRequests[1].Body.Should().Contain("\"input\"");
    }

    [Fact]
    public async Task StreamMessage_emits_sse_error_when_foundry_stream_throws()
    {
        var catalog = new CatalogHandler("agent-a");
        var service = TestServices.AgentService(catalog);
        var foundry = new RecordingFoundryHandler();
        foundry.EnqueueJson(HttpStatusCode.BadRequest, "{\"error\":{\"message\":\"bad foundry request\"}}");
        var controller = MakeController(catalog, withHttpContext: true, clientCache: foundry.ToClientCache(service), service: service);

        await controller.StreamMessage(new ChatTestController.MessageRequest("agent-a", "conv-error", "boom"), CancellationToken.None);

        var sse = await ReadResponseAsync(controller);
        sse.Should().Contain("event: error");
        sse.Should().Contain("bad foundry request");
    }

    [Fact]
    public async Task Admin_chat_auth_filter_allows_anonymous_when_disabled()
    {
        var context = MakeAuthorizationContext(new ClaimsPrincipal(new ClaimsIdentity()));
        var filter = new AdminChatAuthFilter(new AdminChatAuthOptions { Enabled = false });

        await filter.OnAuthorizationAsync(context);

        context.Result.Should().BeNull();
    }

    [Fact]
    public async Task Admin_chat_auth_filter_challenges_anonymous_when_enabled()
    {
        var context = MakeAuthorizationContext(new ClaimsPrincipal(new ClaimsIdentity()));
        var filter = new AdminChatAuthFilter(new AdminChatAuthOptions { Enabled = true });

        await filter.OnAuthorizationAsync(context);

        var challenge = context.Result.Should().BeOfType<ChallengeResult>().Subject;
        challenge.AuthenticationSchemes.Should().Contain(OpenIdConnectDefaults.AuthenticationScheme);
    }

    [Fact]
    public async Task CreateConversation_with_admin_chat_auth_uses_user_foundry_token()
    {
        var catalog = new CatalogHandler("agent-a");
        var service = TestServices.AgentService(catalog);
        var foundry = new RecordingFoundryHandler();
        foundry.EnqueueJson(HttpStatusCode.OK, "{\"id\":\"conv-user\"}");
        var tokenAcquisition = MockTokenAcquisition("user-foundry-token");
        var controller = MakeController(
            catalog,
            withHttpContext: true,
            clientCache: foundry.ToClientCache(service),
            service: service,
            adminChatAuth: new AdminChatAuthOptions { Enabled = true },
            tokenAcquisition: tokenAcquisition.Object);
        controller.HttpContext.User = TestUser();

        var result = await controller.CreateConversation(new ChatTestController.CreateConvRequest("agent-a"), CancellationToken.None);

        result.Should().BeOfType<OkObjectResult>();
        VerifyUserTokenAcquired(tokenAcquisition);
        foundry.AuthorizationHeaders.Should().Contain("Bearer user-foundry-token");
        FoundryUserAuthScope.Current.Should().BeNull();
    }

    [Fact]
    public async Task StreamMessage_with_admin_chat_auth_uses_user_foundry_token()
    {
        var catalog = new CatalogHandler("agent-a");
        var service = TestServices.AgentService(catalog);
        var foundry = new RecordingFoundryHandler();
        foundry.EnqueueSse(ResponseCreated("resp_user"), TextDelta("hello user"), ResponseCompleted("resp_user"));
        var tokenAcquisition = MockTokenAcquisition("stream-user-token");
        var controller = MakeController(
            catalog,
            withHttpContext: true,
            clientCache: foundry.ToClientCache(service),
            service: service,
            adminChatAuth: new AdminChatAuthOptions { Enabled = true },
            tokenAcquisition: tokenAcquisition.Object);
        controller.HttpContext.User = TestUser();

        await controller.StreamMessage(new ChatTestController.MessageRequest("agent-a", "conv-user", "hi"), CancellationToken.None);

        VerifyUserTokenAcquired(tokenAcquisition);
        foundry.AuthorizationHeaders.Should().Contain("Bearer stream-user-token");
        (await ReadResponseAsync(controller)).Should().Contain("hello user");
        FoundryUserAuthScope.Current.Should().BeNull();
    }

    [Fact]
    public void Admin_chat_auth_filter_protects_admin_controllers()
    {
        // Both ChatTestController and ManifestController are reachable under
        // /admin and call Foundry via OBO, so both carry the filter — this
        // is what lets us drop "Azure AI User" RBAC from the container UAMI.
        typeof(ChatTestController).GetCustomAttributes(typeof(ServiceFilterAttribute), inherit: true)
            .Should().Contain(a => ((ServiceFilterAttribute)a).ServiceType == typeof(AdminChatAuthFilter));
        typeof(ManifestController).GetCustomAttributes(typeof(ServiceFilterAttribute), inherit: true)
            .Should().Contain(a => ((ServiceFilterAttribute)a).ServiceType == typeof(AdminChatAuthFilter));
    }

    private static ChatTestController MakeController(
        CatalogHandler handler,
        bool withHttpContext = false,
        AgentClientCache? clientCache = null,
        AgentService? service = null,
        AdminChatAuthOptions? adminChatAuth = null,
        ITokenAcquisition? tokenAcquisition = null)
    {
        service ??= TestServices.AgentService(handler);
        var env = new Mock<IWebHostEnvironment>();
        env.SetupGet(e => e.WebRootPath).Returns(TestServices.WebRootPath());
        var controller = new ChatTestController(
            service,
            clientCache ?? new AgentClientCache(service),
            env.Object,
            NullLogger<ChatTestController>.Instance,
            adminChatAuth ?? new AdminChatAuthOptions { Enabled = true },
            tokenAcquisition ?? MockTokenAcquisition("catalog-user-token").Object);

        controller.ControllerContext = new ControllerContext { HttpContext = new DefaultHttpContext() };
        controller.Response.Body = new MemoryStream();
        controller.HttpContext.User = TestUser();

        return controller;
    }

    private static AuthorizationFilterContext MakeAuthorizationContext(ClaimsPrincipal user)
    {
        var httpContext = new DefaultHttpContext { User = user };
        return new AuthorizationFilterContext(
            new ActionContext(httpContext, new RouteData(), new ControllerActionDescriptor()),
            new List<IFilterMetadata>());
    }

    private static ClaimsPrincipal TestUser()
        => new(new ClaimsIdentity(new[]
        {
            new Claim(ClaimTypes.Name, "Tester"),
            new Claim("oid", "user-oid-1")
        }, "Test"));

    private static Mock<ITokenAcquisition> MockTokenAcquisition(string token)
    {
        var mock = new Mock<ITokenAcquisition>();
        mock.Setup(t => t.GetAccessTokenForUserAsync(
                It.IsAny<IEnumerable<string>>(),
                It.IsAny<string?>(),
                It.IsAny<string?>(),
                It.IsAny<ClaimsPrincipal?>(),
                It.IsAny<TokenAcquisitionOptions?>()))
            .ReturnsAsync(token);
        return mock;
    }

    private static void VerifyUserTokenAcquired(Mock<ITokenAcquisition> tokenAcquisition)
    {
        tokenAcquisition.Verify(t => t.GetAccessTokenForUserAsync(
            It.Is<IEnumerable<string>>(s => s.SequenceEqual(new[] { AdminChatAuthOptions.FoundryScope })),
            null,
            null,
            It.IsAny<ClaimsPrincipal>(),
            null), Times.Once);
    }

    private static async Task<string> ReadResponseAsync(ChatTestController controller)
    {
        controller.Response.Body.Position = 0;
        using var reader = new StreamReader(controller.Response.Body, Encoding.UTF8);
        return await reader.ReadToEndAsync();
    }

    private static IEnumerable<string> SseEventData(string response, string eventName)
    {
        foreach (var block in response.Split("\n\n", StringSplitOptions.RemoveEmptyEntries))
        {
            var lines = block.Split('\n');
            if (!lines.Contains($"event: {eventName}")) continue;
            yield return string.Join('\n', lines
                .Where(line => line.StartsWith("data: ", StringComparison.Ordinal))
                .Select(line => line[6..]));
        }
    }

    private static string ResponseCreated(string id)
        => $"{{\"type\":\"response.created\",\"response\":{{\"id\":\"{id}\",\"object\":\"response\",\"created_at\":0,\"status\":\"in_progress\",\"output\":[]}}}}";

    private static string TextDelta(string text)
        => $"{{\"type\":\"response.output_text.delta\",\"delta\":\"{text}\",\"output_index\":0,\"content_index\":0,\"item_id\":\"msg_1\"}}";

    private static string McpToolDone(string id, string tool, string server, string output)
        => $"{{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{{\"id\":\"{id}\",\"type\":\"mcp_call\",\"name\":\"{tool}\",\"server_label\":\"{server}\",\"arguments\":\"{{}}\",\"output\":\"{output}\"}}}}";

    private static string WebSearchDone(string id, string query)
        => $"{{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{{\"id\":\"{id}\",\"type\":\"web_search_call\",\"status\":\"completed\",\"action\":{{\"type\":\"search\",\"query\":\"{query}\"}}}}}}";

    private static string CodeInterpreterDone(string id, string code, string output)
        => $"{{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{{\"id\":\"{id}\",\"type\":\"code_interpreter_call\",\"status\":\"completed\",\"container_id\":\"cntr_1\",\"code\":\"{code.Replace("'", "\\u0027")}\",\"outputs\":[{{\"type\":\"logs\",\"logs\":\"{output}\"}}]}}}}";

    private static string ResponseCompleted(string id)
        => $"{{\"type\":\"response.completed\",\"response\":{{\"id\":\"{id}\",\"object\":\"response\",\"created_at\":0,\"status\":\"completed\",\"output\":[],\"usage\":{{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}}}}";
}
