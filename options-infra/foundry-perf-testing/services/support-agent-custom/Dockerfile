FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
WORKDIR /app
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
# Build context is `..` (see azure.yaml docker.context) so both folders are visible.
COPY support-agent-shared/ ./support-agent-shared/
COPY support-agent-custom/ ./support-agent-custom/
WORKDIR /src/support-agent-custom
RUN dotnet restore
RUN dotnet publish -c Release -o /app/publish

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "support-agent-custom.dll"]
