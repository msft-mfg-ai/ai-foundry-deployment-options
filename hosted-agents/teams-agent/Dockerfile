FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY src/AgentChat.csproj src/
RUN dotnet restore src/AgentChat.csproj

COPY src/ src/
RUN dotnet publish src/AgentChat.csproj \
    --configuration Release \
    --output /app/publish \
    --no-restore \
    -p:SkipTeamsTabBuild=true

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app/publish .

ENV ASPNETCORE_URLS=http://0.0.0.0:8080
ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "AgentChat.dll"]
