using AgentChat.Services;
using FluentAssertions;
using Xunit;

namespace AgentChat.Tests;

public class TeamsSsoToolContextTests
{
    [Fact]
    public async Task InspectAsync_UsesCurrentTurnHandler()
    {
        var context = new TeamsSsoToolContext();

        using (context.Push(_ => Task.FromResult("claims")))
        {
            var result = await context.InspectAsync(
                CancellationToken.None);

            result.Should().Be("claims");
        }
    }

    [Fact]
    public async Task InspectAsync_AfterScope_RejectsOutOfTurnUse()
    {
        var context = new TeamsSsoToolContext();
        using (context.Push(_ => Task.FromResult("claims")))
        {
        }

        var action = () => context.InspectAsync(
            CancellationToken.None);

        await action.Should()
            .ThrowAsync<InvalidOperationException>()
            .WithMessage("*Teams turn*");
    }
}
