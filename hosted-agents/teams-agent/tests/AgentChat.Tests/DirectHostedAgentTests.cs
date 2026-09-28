using AgentChat.Services;
using FluentAssertions;
using Microsoft.Agents.AI;
using System.IO.Compression;
using System.Text;
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
    public void PowerPoint_artifact_requires_a_valid_package()
    {
        var file = DirectHostedAgent.ValidateGeneratedFile(
            "container",
            "file",
            "briefing.pptx",
            CreatePowerPointPackage());

        file.Name.Should().Be("briefing.pptx");
        file.MediaType.Should().Be(
            "application/vnd.openxmlformats-officedocument.presentationml.presentation");
    }

    [Fact]
    public void PowerPoint_artifact_rejects_orphaned_slide_relationships()
    {
        var act = () => DirectHostedAgent.ValidateGeneratedFile(
            "container",
            "file",
            "briefing.pptx",
            CreatePowerPointPackage(includeOrphanedRelationship: true));

        act.Should().Throw<InvalidDataException>()
            .WithMessage("*orphaned slide relationships*");
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

    private static byte[] CreatePowerPointPackage(
        bool includeOrphanedRelationship = false)
    {
        using var output = new MemoryStream();
        using (var archive = new ZipArchive(
            output,
            ZipArchiveMode.Create,
            leaveOpen: true))
        {
            WriteEntry(
                archive,
                "ppt/presentation.xml",
                """
                <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                  <p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst>
                </p:presentation>
                """);
            WriteEntry(
                archive,
                "ppt/_rels/presentation.xml.rels",
                $$"""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId1"
                    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
                    Target="slides/slide1.xml"/>
                  {{(includeOrphanedRelationship
                      ? """
                        <Relationship Id="rId2"
                          Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
                          Target="slides/slide1.xml"/>
                        """
                      : string.Empty)}}
                </Relationships>
                """);
            WriteEntry(
                archive,
                "ppt/slides/slide1.xml",
                """
                <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>
                """);
        }
        return output.ToArray();
    }

    private static void WriteEntry(
        ZipArchive archive,
        string name,
        string content)
    {
        using var stream = archive.CreateEntry(name).Open();
        stream.Write(Encoding.UTF8.GetBytes(content));
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
    public void Agent_can_select_only_the_final_generated_file()
    {
        var context = new DirectHostedAgent.CodeExecutionContext(
            CancellationToken.None,
            "call-1",
            "user-1",
            "container-1");
        context.GeneratedFiles.Add(
            "draft-id",
            new DirectHostedAgent.ContainerFileReference(
                "container-1",
                "draft-id",
                "deck-draft.pptx"));
        context.GeneratedFiles.Add(
            "final-id",
            new DirectHostedAgent.ContainerFileReference(
                "container-1",
                "final-id",
                "deck.pptx"));

        var result = DirectHostedAgent.SelectFileForReturn(
            "deck.pptx",
            context);

        result.Should().Contain("deck.pptx");
        context.SelectedFileIds.Should().Equal("final-id");
    }

    [Fact]
    public void Only_agent_selected_deliverables_are_returned()
    {
        DirectHostedAgent.ContainerFileReference[] generatedFiles =
        [
            new("container-1", "image-id", "background.png"),
            new("container-1", "draft-id", "deck-draft.pptx"),
            new("container-1", "final-id", "deck.pptx"),
        ];

        var selected = DirectHostedAgent.SelectFilesForReturn(
            generatedFiles,
            new HashSet<string>(StringComparer.Ordinal)
            {
                "final-id",
            });

        selected.Should().ContainSingle()
            .Which.Filename.Should().Be("deck.pptx");
    }

    [Fact]
    public void Working_artifacts_do_not_count_against_selected_deliverable_limit()
    {
        var generatedFiles = Enumerable.Range(1, 6)
            .Select(index => new DirectHostedAgent.ContainerFileReference(
                "container-1",
                $"file-{index}",
                index == 6 ? "deck.pptx" : $"working-{index}.png"))
            .ToArray();

        var selected = DirectHostedAgent.SelectResponseFiles(
            generatedFiles,
            new HashSet<string>(StringComparer.Ordinal)
            {
                "file-6",
            });

        selected.Should().ContainSingle()
            .Which.Filename.Should().Be("deck.pptx");
    }

    [Fact]
    public void Unselected_generated_files_still_respect_response_limit()
    {
        var generatedFiles = Enumerable.Range(1, 6)
            .Select(index => new DirectHostedAgent.ContainerFileReference(
                "container-1",
                $"file-{index}",
                $"deliverable-{index}.png"))
            .ToArray();

        var act = () => DirectHostedAgent.SelectResponseFiles(
            generatedFiles,
            new HashSet<string>(StringComparer.Ordinal));

        act.Should().Throw<InvalidDataException>()
            .WithMessage("*selected 6 files*maximum per request is 5*");
    }

    [Fact]
    public void Missing_selected_deliverable_is_rejected()
    {
        var act = () => DirectHostedAgent.SelectFilesForReturn(
            Array.Empty<DirectHostedAgent.ContainerFileReference>(),
            new HashSet<string>(StringComparer.Ordinal)
            {
                "missing-id",
            });

        act.Should().Throw<InvalidDataException>();
    }

    [Theory]
    [InlineData("../deck.pptx")]
    [InlineData("/mnt/data/deck.pptx")]
    [InlineData("notes.txt")]
    public void Final_file_selection_rejects_paths_and_unsupported_files(
        string filename)
    {
        var context = new DirectHostedAgent.CodeExecutionContext(
            CancellationToken.None,
            "call-1",
            "user-1",
            "container-1");

        var act = () => DirectHostedAgent.SelectFileForReturn(
            filename,
            context);

        act.Should().Throw<InvalidDataException>();
    }

    [Fact]
    public void Final_file_selection_requires_an_existing_generated_file()
    {
        var context = new DirectHostedAgent.CodeExecutionContext(
            CancellationToken.None,
            "call-1",
            "user-1",
            "container-1");

        var act = () => DirectHostedAgent.SelectFileForReturn(
            "missing.pptx",
            context);

        act.Should().Throw<FileNotFoundException>();
    }

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
    [InlineData(400, "Container is expired.", true)]
    [InlineData(400, "invalid_request_error: CONTAINER IS EXPIRED", true)]
    [InlineData(404, "Resource not found.", true)]
    [InlineData(400, "The Python code is invalid.", false)]
    [InlineData(500, "Container is expired.", false)]
    public void Expired_code_interpreter_container_is_detected(
        int status,
        string message,
        bool expected)
        => DirectHostedAgent.IsExpiredContainerError(status, message)
            .Should().Be(expected);

    [Fact]
    public async Task Generated_image_uses_powerpoint_working_container()
    {
        var session = new TestAgentSession();
        var context = new DirectHostedAgent.CodeExecutionContext(
            CancellationToken.None,
            "call-1",
            "user-1",
            null);
        var files = new RecordingContainerFiles();
        var image = new GeneratedImage(
            "png"u8.ToArray(),
            "hero-12345678.png",
            "image/png",
            1024,
            768);

        var result = await DirectHostedAgent.StageGeneratedImageAsync(
            session,
            context,
            files,
            "pptx"u8.ToArray(),
            image,
            CancellationToken.None);

        result.Path.Should().Be("/mnt/data/hero-12345678.png");
        context.ContainerId.Should().Be("container-1");
        DirectHostedAgent.GetPersistedContainerId(session, "user-1")
            .Should().Be("container-1");
        context.GeneratedFiles.Values.Should().ContainSingle()
            .Which.Should().Be(
                new DirectHostedAgent.ContainerFileReference(
                    "container-1",
                    "file-2",
                    "hero-12345678.png"));
        files.Uploads.Should().Equal(
            ("container-1", "template.pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
            ("container-1", "hero-12345678.png", "image/png"));
    }

    [Fact]
    public void Uploaded_container_file_id_is_read_from_response()
        => DirectHostedAgent.GetUploadedContainerFileId(
                BinaryData.FromString(
                    """{"id":"file-123","object":"container.file"}"""))
            .Should().Be("file-123");

    [Fact]
    public void Uploaded_container_file_requires_an_id()
    {
        var act = () => DirectHostedAgent.GetUploadedContainerFileId(
            BinaryData.FromString("""{"object":"container.file"}"""));

        act.Should().Throw<InvalidDataException>();
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

    private sealed class RecordingContainerFiles
        : DirectHostedAgent.IContainerFileOperations
    {
        public List<(string ContainerId, string Filename, string MediaType)>
            Uploads { get; } = [];

        private int _fileCount;

        public Task<string> CreateAsync(CancellationToken cancellationToken) =>
            Task.FromResult("container-1");

        public Task<string> UploadAsync(
            string containerId,
            string filename,
            string mediaType,
            byte[] data,
            CancellationToken cancellationToken)
        {
            Uploads.Add((containerId, filename, mediaType));
            _fileCount++;
            return Task.FromResult($"file-{_fileCount}");
        }
    }
}
