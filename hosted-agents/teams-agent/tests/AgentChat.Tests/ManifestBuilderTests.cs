using AgentChat.Bots;
using FluentAssertions;
using Newtonsoft.Json.Linq;
using Xunit;

namespace AgentChat.Tests;

public class ManifestBuilderTests
{
    private const string BotId = "12345678-1234-1234-1234-123456789012";

    [Fact]
    public void Build_throws_when_agent_name_missing()
    {
        var act = () => ManifestBuilder.Build("", "desc", BotId);
        act.Should().Throw<ArgumentException>().WithMessage("*agentName*");
    }

    [Fact]
    public void Build_throws_when_bot_id_missing()
    {
        var act = () => ManifestBuilder.Build("Agent", "desc", "  ");
        act.Should().Throw<ArgumentException>().WithMessage("*botId*");
    }

    [Fact]
    public void Build_produces_v1_17_manifest()
    {
        var m = ManifestBuilder.Build("Agent", "Description", BotId);
        m["$schema"]!.ToString().Should().Contain("v1.17");
        m["manifestVersion"]!.ToString().Should().Be("1.17");
        m["version"]!.ToString().Should().Be("1.0.0");
    }

    [Fact]
    public void Build_includes_botId_in_bots_array()
    {
        var m = ManifestBuilder.Build("Agent", "Desc", BotId);
        var bots = (JArray)m["bots"]!;
        bots.Should().HaveCount(1);
        bots[0]["botId"]!.ToString().Should().Be(BotId);
    }

    [Fact]
    public void Build_includes_all_three_scopes()
    {
        var m = ManifestBuilder.Build("Agent", "Desc", BotId);
        var scopes = ((JArray)m["bots"]![0]!["scopes"]!).Select(s => s.ToString()).ToArray();
        scopes.Should().BeEquivalentTo(new[] { "personal", "team", "groupChat" });
    }

    [Fact]
    public void Build_truncates_long_descriptions()
    {
        var longDesc = new string('x', 200);
        var m = ManifestBuilder.Build("Agent", longDesc, BotId);

        var shortDesc = m["description"]!["short"]!.ToString();
        shortDesc.Length.Should().BeLessOrEqualTo(ManifestBuilder.MaxShortDescChars);
        shortDesc.Should().EndWith("...");
    }

    [Fact]
    public void Build_truncates_long_full_description()
    {
        var longDesc = new string('y', 5000);
        var m = ManifestBuilder.Build("Agent", longDesc, BotId);

        var fullDesc = m["description"]!["full"]!.ToString();
        fullDesc.Length.Should().Be(ManifestBuilder.MaxFullDescChars);
    }

    [Fact]
    public void Build_truncates_long_short_name()
    {
        var longName = new string('A', 50);
        var m = ManifestBuilder.Build(longName, "Desc", BotId);

        m["name"]!["short"]!.ToString().Length.Should().Be(ManifestBuilder.MaxShortNameChars);
    }

    [Fact]
    public void Build_uses_default_short_desc_when_agent_description_empty()
    {
        var m = ManifestBuilder.Build("MyAgent", "", BotId);
        m["description"]!["short"]!.ToString().Should().Contain("MyAgent");
    }

    [Fact]
    public void Build_uses_provided_manifest_id_when_given()
    {
        var id = Guid.NewGuid();
        var m = ManifestBuilder.Build("Agent", "Desc", BotId, manifestId: id);
        m["id"]!.ToString().Should().Be(id.ToString());
    }

    [Fact]
    public void Build_generates_unique_random_id_when_not_provided()
    {
        var m1 = ManifestBuilder.Build("Agent", "Desc", BotId);
        var m2 = ManifestBuilder.Build("Agent", "Desc", BotId);
        m1["id"]!.ToString().Should().NotBe(m2["id"]!.ToString());
        Guid.TryParse(m1["id"]!.ToString(), out _).Should().BeTrue();
    }

    [Fact]
    public void Build_includes_command_list_with_help_and_new()
    {
        var m = ManifestBuilder.Build("Agent", "Desc", BotId);
        var commands = (JArray)m["bots"]![0]!["commandLists"]![0]!["commands"]!;
        var titles = commands.Select(c => c["title"]!.ToString()).ToArray();
        titles.Should().Contain("/help");
        titles.Should().Contain("/new");
        titles.Should().Contain("/agents");
        titles.Should().Contain("/agent");
        titles.Should().Contain("/debug");
        titles.Should().Contain("/tokens");
    }

    [Fact]
    public void Build_command_list_respects_Teams_10_command_cap()
    {
        // Teams manifest schema caps bots[].commandLists[].commands at 10.
        // Uploading a manifest with more than 10 fails validation with
        // "bot can only have 10 commands".
        var m = ManifestBuilder.Build("Agent", "Desc", BotId);
        var commands = (JArray)m["bots"]![0]!["commandLists"]![0]!["commands"]!;
        commands.Count.Should().BeLessOrEqualTo(10);
    }

    [Fact]
    public void Build_command_list_only_contains_implemented_commands()
    {
        // Every entry in the compose-box command menu must map to a real
        // handler in FoundryBot.HandleCommandAsync — otherwise Teams users
        // see "Unknown command /foo".
        var handlerSource = System.IO.File.ReadAllText(
            System.IO.Path.Combine(RepoRoot(), "src", "Bots", "FoundryBot.cs"));
        var m = ManifestBuilder.Build("Agent", "Desc", BotId);
        var commands = (JArray)m["bots"]![0]!["commandLists"]![0]!["commands"]!;
        foreach (var c in commands)
        {
            var title = c["title"]!.ToString();
            handlerSource.Should().Contain($"case \"{title}\":",
                because: $"'{title}' is in the manifest command list but has no case in FoundryBot.HandleCommandAsync");
        }
    }

    private static string RepoRoot()
    {
        var d = new System.IO.DirectoryInfo(AppContext.BaseDirectory);
        while (d is not null && !System.IO.Directory.Exists(System.IO.Path.Combine(d.FullName, "src")))
            d = d.Parent;
        return d?.FullName ?? throw new System.IO.DirectoryNotFoundException("repo root");
    }

    [Fact]
    public void Build_has_developer_block_with_required_urls()
    {
        var m = ManifestBuilder.Build("Agent", "Desc", BotId);
        var dev = m["developer"]!;
        dev["name"].Should().NotBeNull();
        dev["websiteUrl"].Should().NotBeNull();
        dev["privacyUrl"].Should().NotBeNull();
        dev["termsOfUseUrl"].Should().NotBeNull();
    }

    [Fact]
    public void Build_does_not_emit_webApplicationInfo_by_default()
    {
        var m = ManifestBuilder.Build("Agent", "Desc", BotId);
        m["webApplicationInfo"].Should().BeNull();
    }

    [Fact]
    public void Build_emits_webApplicationInfo_when_sso_app_id_provided()
    {
        var m = ManifestBuilder.Build("Agent", "Desc", BotId,
            ssoAadAppId: "00000000-0000-0000-0000-deadbeef0001",
            ssoResource: "api://my-bot-app/access_as_user");
        var wai = m["webApplicationInfo"]!;
        wai["id"]!.ToString().Should().Be("00000000-0000-0000-0000-deadbeef0001");
        wai["resource"]!.ToString().Should().Be("api://my-bot-app/access_as_user");
    }

    [Fact]
    public void Build_omits_webApplicationInfo_resource_when_only_app_id_given()
    {
        var m = ManifestBuilder.Build("Agent", "Desc", BotId, ssoAadAppId: "00000000-0000-0000-0000-deadbeef0001");
        var wai = m["webApplicationInfo"]!;
        wai["id"].Should().NotBeNull();
        wai["resource"].Should().BeNull();
    }

    [Fact]
    public void Build_emits_validDomains_when_sso_app_id_provided()
    {
        var m = ManifestBuilder.Build("Agent", "Desc", BotId, ssoAadAppId: "00000000-0000-0000-0000-deadbeef0001");
        var validDomains = ((JArray)m["validDomains"]!).Select(d => d.ToString()).ToArray();
        validDomains.Should().BeEquivalentTo(new[] { "token.botframework.com", "*.botframework.com" });
    }

    [Fact]
    public void Build_emits_permissions_when_sso_app_id_provided()
    {
        var m = ManifestBuilder.Build("Agent", "Desc", BotId, ssoAadAppId: "00000000-0000-0000-0000-deadbeef0001");
        var permissions = ((JArray)m["permissions"]!).Select(p => p.ToString()).ToArray();
        permissions.Should().BeEquivalentTo(new[] { "identity", "messageTeamMembers" });
    }

    [Fact]
    public void Build_leaves_validDomains_empty_and_permissions_absent_when_sso_disabled()
    {
        var m = ManifestBuilder.Build("Agent", "Desc", BotId);
        ((JArray)m["validDomains"]!).Should().BeEmpty();
        m["permissions"].Should().BeNull();
    }

    [Fact]
    public void Build_emits_personal_static_tab_and_adds_its_host_to_valid_domains()
    {
        var m = ManifestBuilder.Build(
            "Agent",
            "Desc",
            BotId,
            ssoAadAppId: "00000000-0000-0000-0000-deadbeef0001",
            ssoResource: "api://backend",
            tabContentUrl: "https://proxy.example.com/chat/host/project/Agent/ui");

        var tab = ((JArray)m["staticTabs"]!).Should().ContainSingle().Subject;
        tab["entityId"]!.ToString().Should().Be("foundry-agent-chat");
        tab["name"]!.ToString().Should().Be("Chat");
        tab["contentUrl"]!.ToString().Should().Be("https://proxy.example.com/chat/host/project/Agent/ui");
        ((JArray)tab["scopes"]!).Select(scope => scope.ToString()).Should().Equal("personal");
        ((JArray)m["validDomains"]!).Select(domain => domain.ToString())
            .Should().Contain("proxy.example.com");
    }

    [Fact]
    public void Build_rejects_non_https_tab_url()
    {
        var act = () => ManifestBuilder.Build(
            "Agent",
            "Desc",
            BotId,
            tabContentUrl: "http://proxy.example.com/chat/host/project/Agent/ui");

        act.Should().Throw<ArgumentException>().WithMessage("*HTTPS*");
    }

    [Fact]
    public void BuildTab_emits_tab_only_manifest_with_shared_sso_app()
    {
        var m = ManifestBuilder.BuildTab(
            "Agent",
            "Desc",
            "https://proxy.example.com/chat/host/project/Agent/ui",
            "00000000-0000-0000-0000-deadbeef0001",
            "api://shared-backend");

        m["bots"].Should().BeNull();
        ((JArray)m["staticTabs"]!).Should().ContainSingle();
        m["webApplicationInfo"]!["id"]!.ToString()
            .Should().Be("00000000-0000-0000-0000-deadbeef0001");
        m["webApplicationInfo"]!["resource"]!.ToString().Should().Be("api://shared-backend");
        ((JArray)m["validDomains"]!).Select(domain => domain.ToString())
            .Should().Equal("proxy.example.com");
    }

    [Fact]
    public void Build_does_not_emit_botEndpointPath_when_omitted_or_default()
    {
        // x-foundryBotEndpointPath was removed entirely — Teams' manifest
        // schema validator rejects unknown properties under bots[].
        var m = ManifestBuilder.Build("Agent", "Desc", BotId);
        m["bots"]![0]!["x-foundryBotEndpointPath"].Should().BeNull();
    }

    [Theory]
    [InlineData("Docs Assistant",       "Docs_Assistant")]
    [InlineData("MCP Learn Agent POC",  "MCP_Learn_Agent_POC")]
    [InlineData("agent/with/slashes",   "agent_with_slashes")]
    [InlineData("___leading___",        "leading")]
    [InlineData("",                     "agent")]
    [InlineData("___",                  "agent")]
    [InlineData("hello!@#$%^&*()",      "hello")]
    [InlineData("foo-bar_baz",          "foo-bar_baz")]
    public void SanitizeForFilename_strips_unsafe_characters(string input, string expected)
    {
        ManifestBuilder.SanitizeForFilename(input).Should().Be(expected);
    }
}
