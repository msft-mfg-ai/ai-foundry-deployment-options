using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace AgentChat.Auth;

public sealed class AdminChatAuthFilter(AdminChatAuthOptions options) : IAsyncAuthorizationFilter
{
    public Task OnAuthorizationAsync(AuthorizationFilterContext context)
    {
        if (!options.Enabled || context.HttpContext.User?.Identity?.IsAuthenticated == true)
            return Task.CompletedTask;

        context.Result = new ChallengeResult(OpenIdConnectDefaults.AuthenticationScheme);
        return Task.CompletedTask;
    }
}
