FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
WORKDIR /app
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Build context is set to `..` in azure.yaml so the shared folder is included.
COPY support-agent-shared/ ./support-agent-shared/
COPY support-agent-hosted/ ./support-agent-hosted/
WORKDIR /src/support-agent-hosted
RUN dotnet restore
RUN dotnet publish -c Release -o /app/publish

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "support-agent-hosted.dll"]
