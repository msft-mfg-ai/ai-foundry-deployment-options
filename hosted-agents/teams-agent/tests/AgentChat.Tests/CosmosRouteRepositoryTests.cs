using AgentChat.Services;
using FluentAssertions;
using Microsoft.Agents.Storage;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace AgentChat.Tests;

public class CosmosRouteRepositoryTests
{
    [Fact]
    public async Task LoadAsync_seeds_from_config_when_storage_is_empty()
    {
        var storage = new MemoryStorage();
        var repo = new CosmosRouteRepository(storage, NullLogger<CosmosRouteRepository>.Instance);

        await repo.LoadAsync(new[]
        {
            new BotRoute("agent-a", "aaaaaaaa-0000-0000-0000-000000000001"),
            new BotRoute("agent-b", "aaaaaaaa-0000-0000-0000-000000000002"),
        });

        repo.GetAll().Should().HaveCount(2);
        repo.TryGet("agent-a").Should().NotBeNull();
        repo.TryGet("agent-b")!.ProxyAppId.Should().Be("aaaaaaaa-0000-0000-0000-000000000002");
    }

    [Fact]
    public async Task LoadAsync_prefers_persisted_routes_over_seed()
    {
        var storage = new MemoryStorage();
        var repo1 = new CosmosRouteRepository(storage, NullLogger<CosmosRouteRepository>.Instance);
        await repo1.LoadAsync(new[] { new BotRoute("original", "aaaaaaaa-0000-0000-0000-000000000001") });

        // second instance sharing the same storage with a *different* seed
        var repo2 = new CosmosRouteRepository(storage, NullLogger<CosmosRouteRepository>.Instance);
        await repo2.LoadAsync(new[] { new BotRoute("newer-seed", "bbbbbbbb-0000-0000-0000-000000000002") });

        repo2.TryGet("original").Should().NotBeNull("persisted seed must win over startup seed");
        repo2.TryGet("newer-seed").Should().BeNull();
    }

    [Fact]
    public async Task UpsertAsync_persists_and_survives_reload()
    {
        var storage = new MemoryStorage();
        var repo = new CosmosRouteRepository(storage, NullLogger<CosmosRouteRepository>.Instance);
        await repo.LoadAsync(Array.Empty<BotRoute>());

        await repo.UpsertAsync(new BotRoute(
            "runtime-add",
            "cccccccc-0000-0000-0000-000000000003",
            DirectAppId: "dddddddd-0000-0000-0000-000000000004",
            FoundryHost: "aif-test",
            ProjectName: "proj-test"));

        repo.TryGet("runtime-add").Should().NotBeNull();

        var repo2 = new CosmosRouteRepository(storage, NullLogger<CosmosRouteRepository>.Instance);
        await repo2.LoadAsync(Array.Empty<BotRoute>());

        var loaded = repo2.TryGet("runtime-add");
        loaded.Should().NotBeNull();
        loaded!.DirectAppId.Should().Be("dddddddd-0000-0000-0000-000000000004");
        loaded.FoundryHost.Should().Be("aif-test");
        loaded.ProjectName.Should().Be("proj-test");
    }

    [Fact]
    public async Task UpsertAsync_replaces_existing_route_with_same_name_case_insensitive()
    {
        var storage = new MemoryStorage();
        var repo = new CosmosRouteRepository(storage, NullLogger<CosmosRouteRepository>.Instance);
        await repo.LoadAsync(new[] { new BotRoute("agent-x", "aaaaaaaa-0000-0000-0000-000000000001") });

        await repo.UpsertAsync(new BotRoute("Agent-X", "eeeeeeee-0000-0000-0000-000000000005"));

        repo.GetAll().Should().HaveCount(1);
        repo.TryGet("agent-x")!.ProxyAppId.Should().Be("eeeeeeee-0000-0000-0000-000000000005");
    }

    [Fact]
    public async Task UpsertAsync_rejects_missing_required_fields()
    {
        var repo = new CosmosRouteRepository(new MemoryStorage(), NullLogger<CosmosRouteRepository>.Instance);
        await repo.LoadAsync(Array.Empty<BotRoute>());

        await FluentActions.Invoking(() => repo.UpsertAsync(new BotRoute("", "aaa")))
            .Should().ThrowAsync<ArgumentException>();
        await FluentActions.Invoking(() => repo.UpsertAsync(new BotRoute("agent", "")))
            .Should().ThrowAsync<ArgumentException>();
    }

    [Fact]
    public async Task LoadAsync_with_no_seed_and_empty_storage_yields_empty_registry()
    {
        var repo = new CosmosRouteRepository(new MemoryStorage(), NullLogger<CosmosRouteRepository>.Instance);
        await repo.LoadAsync(Array.Empty<BotRoute>());

        repo.GetAll().Should().BeEmpty();
    }
}
