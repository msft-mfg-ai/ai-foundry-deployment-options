using AgentChat.Services;
using FluentAssertions;
using Microsoft.Agents.AI;
using System.Net;
using Xunit;

namespace AgentChat.Tests;

public class DirectHostedAgentTests
{
    [Theory]
    [InlineData("Authentication failed when connecting to the MCP server: 401 Unauthorized")]
    [InlineData("Toolbox request failed: invalid_token")]
    [InlineData("The MCP bearer token is expired")]
    public void Mcp_authentication_failures_are_retriable(string message)
        => DirectHostedAgent.IsMcpAuthenticationFailure(
                new InvalidOperationException(message))
            .Should().BeTrue();

    [Fact]
    public void Unrelated_authentication_failure_is_not_retriable()
        => DirectHostedAgent.IsMcpAuthenticationFailure(
                new InvalidOperationException("Foundry model request returned 401"))
            .Should().BeFalse();

    [Theory]
    [InlineData("User identity authentication for this tool is not supported for this caller.")]
    [InlineData("ARA OBO token request failed with status BadRequest.")]
    [InlineData("Audience for incoming token is incorrect.")]
    [InlineData("Failed to fetch access token.")]
    public void Delegated_user_tool_authentication_failures_are_isolated(
        string message)
        => DirectHostedAgent.IsDelegatedUserToolAuthenticationFailure(
                new InvalidOperationException(message))
            .Should().BeTrue();

    [Theory]
    [InlineData(
        "OAuth consent required. Please visit: https://login.example.test/authorize?state=abc",
        "https://login.example.test/authorize?state=abc")]
    [InlineData(
        "tools/list failed {\"errors\":[{\"name\":\"whoami\",\"error\":{\"code\":\"CONSENT_REQUIRED\",\"message\":\"https://login.example.test/authorize?state=abc\"}}]}",
        "https://login.example.test/authorize?state=abc")]
    public void OAuth_consent_url_is_extracted(
        string message,
        string expected)
        => OAuthConsentParser.TryParse(
                new InvalidOperationException(message),
                "teams-user-tools")!
            .ConsentUrl.Should().Be(expected);

    [Fact]
    public void Unrelated_failure_is_not_treated_as_oauth_consent()
        => OAuthConsentParser.TryParse(
                new InvalidOperationException("Toolbox returned 500."),
                "teams-user-tools")
            .Should().BeNull();

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.TooManyRequests)]
    [InlineData(HttpStatusCode.InternalServerError)]
    [InlineData(HttpStatusCode.BadGateway)]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    public void Transient_and_authentication_statuses_are_retried(HttpStatusCode statusCode)
        => DirectHostedAgent.IsRetryableToolboxStatus(statusCode).Should().BeTrue();

    [Fact]
    public void Bad_request_is_not_retried()
        => DirectHostedAgent.IsRetryableToolboxStatus(HttpStatusCode.BadRequest)
            .Should().BeFalse();

    [Fact]
    public void Initialization_authentication_failure_is_retryable()
        => DirectHostedAgent.IsRetryableToolboxInitializationFailure(
                new InvalidOperationException(
                    "MCP toolbox returned 401 unauthorized."))
            .Should().BeTrue();

    [Fact]
    public void Initialization_bad_request_is_not_retryable()
        => DirectHostedAgent.IsRetryableToolboxInitializationFailure(
                new HttpRequestException(
                    "Bad request.",
                    inner: null,
                    HttpStatusCode.BadRequest))
            .Should().BeFalse();

    [Fact]
    public void PowerPoint_artifact_requires_a_zip_signature()
    {
        var file = DirectHostedAgent.ValidateGeneratedFile(
            "container",
            "file",
            "briefing.pptx",
            [0x50, 0x4B, 0x03, 0x04, 0x00]);

        file.Name.Should().Be("briefing.pptx");
        file.MediaType.Should().Be(
            "application/vnd.openxmlformats-officedocument.presentationml.presentation");
    }

    [Fact]
    public void Artifact_rejects_path_traversal()
    {
        var act = () => DirectHostedAgent.ValidateGeneratedFile(
            "container",
            "file",
            "../briefing.pptx",
            [0x50, 0x4B, 0x03, 0x04]);

        act.Should().Throw<InvalidDataException>();
    }

    [Fact]
    public void Artifact_rejects_extension_signature_mismatch()
    {
        var act = () => DirectHostedAgent.ValidateGeneratedFile(
            "container",
            "file",
            "briefing.pptx",
            "%PDF-1.7"u8.ToArray());

        act.Should().Throw<InvalidDataException>();
    }

    [Theory]
    [InlineData("deck.pptx", true)]
    [InlineData("report.pdf", true)]
    [InlineData("chart.PNG", true)]
    [InlineData("photo.jpeg", true)]
    [InlineData("template.pptx", true)]
    [InlineData("notes.txt", false)]
    [InlineData("archive.zip", false)]
    public void Generated_artifact_filter_accepts_supported_files(
        string filename,
        bool expected)
        => DirectHostedAgent.IsSupportedGeneratedArtifact(filename)
            .Should().Be(expected);

    [Fact]
    public void Code_interpreter_container_survives_session_serialization()
    {
        var session = new TestAgentSession();
        DirectHostedAgent.PersistContainerId(
            session,
            "user-1",
            "container-1");

        var restoredState = AgentSessionStateBag.Deserialize(
            session.StateBag.Serialize());
        var restored = new TestAgentSession(restoredState);

        DirectHostedAgent.GetPersistedContainerId(restored, "user-1")
            .Should().Be("container-1");
    }

    [Fact]
    public void Code_interpreter_container_rejects_another_user()
    {
        var session = new TestAgentSession();
        DirectHostedAgent.PersistContainerId(
            session,
            "user-1",
            "container-1");

        var act = () =>
            DirectHostedAgent.GetPersistedContainerId(session, "user-2");

        act.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void Clearing_code_interpreter_container_removes_owner_and_id()
    {
        var session = new TestAgentSession();
        DirectHostedAgent.PersistContainerId(
            session,
            "user-1",
            "container-1");

        DirectHostedAgent.ClearPersistedContainerId(session);

        DirectHostedAgent.GetPersistedContainerId(session, "user-2")
            .Should().BeNull();
    }

    [Theory]
    [InlineData("Piotr Karpala", "Piotr")]
    [InlineData("  Anne-Marie Example  ", "Anne-Marie")]
    [InlineData("O'Connor Example", "O'Connor")]
    [InlineData("", null)]
    [InlineData("12345", null)]
    public void Teams_display_name_is_reduced_to_a_safe_first_name(
        string displayName,
        string? expected)
        => DirectHostedAgent.NormalizeFirstName(displayName)
            .Should().Be(expected);

    private sealed class TestAgentSession : AgentSession
    {
        public TestAgentSession()
        {
        }

        public TestAgentSession(AgentSessionStateBag stateBag)
            : base(stateBag)
        {
        }
    }
}
