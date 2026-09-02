using AgentChat.Bots;
using FluentAssertions;
using Microsoft.Agents.Builder;
using Microsoft.Agents.Hosting.AspNetCore;
using Microsoft.Agents.Storage;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Xunit;

namespace AgentChat.Tests;

public class StartupRegistrationTests
{
    [Fact]
    public void Program_does_not_register_background_agent_catalog_refresh()
    {
        var root = FindRepoRoot();
        var program = File.ReadAllText(Path.Combine(root, "src", "Program.cs"));

        program.Should().NotContain("AddHostedService");
        program.Should().NotContain("BackgroundService");
    }

    [Fact]
    public void Direct_agent_is_registered_for_both_invocations_and_responses()
    {
        var root = FindRepoRoot();
        var program = File.ReadAllText(Path.Combine(root, "src", "Program.cs"));
        var manifest = File.ReadAllText(
            Path.GetFullPath(Path.Combine(root, "..", "..", "options-infra", "foundry-teams-hosted", "azure.yaml")));

        program.Should().Contain("AddInvocationsServer");
        program.Should().Contain("AddFoundryResponses");
        program.Should().Contain("MapInvocationsServer");
        program.Should().Contain("MapFoundryResponses");
        program.Should().Contain("GetRequiredService<DirectHostedAgent>()");
        manifest.Should().Contain("- protocol: invocations");
        manifest.Should().Contain("- protocol: responses");
    }

    // Regression: v0.12.0-rc.1 shipped with a missing AdapterOptions
    // registration, which crashed every incoming request with
    // "Unable to resolve service for type 'AdapterOptions' while attempting
    // to activate 'AdapterWithErrorHandler'". Mirror Program.cs's adapter
    // subgraph and assert CloudAdapter is resolvable from DI.
    [Fact]
    public void CloudAdapter_can_be_resolved_from_DI()
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddHttpClient();
        services.AddSingleton<IConfiguration>(new ConfigurationBuilder().Build());
        services.AddSingleton<IStorage, MemoryStorage>();

        // Same registrations Program.cs performs for the adapter subgraph.
        services.AddAgentCore<CloudAdapter>();
        services.AddSingleton(new AdapterOptions());
        services.AddSingleton<CloudAdapter, AdapterWithErrorHandler>();

        using var sp = services.BuildServiceProvider();

        var adapter = sp.GetRequiredService<CloudAdapter>();
        adapter.Should().BeOfType<AdapterWithErrorHandler>();
    }

    private static string FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "src", "AgentChat.csproj")))
                return dir.FullName;
            dir = dir.Parent;
        }
        throw new DirectoryNotFoundException("Could not locate repository root.");
    }
}
