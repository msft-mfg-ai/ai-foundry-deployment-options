using System.ComponentModel;
using System.Text;
using Azure.AI.Projects;
using Azure.AI.Projects.Agents;
using Azure.Identity;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry;
using Microsoft.Extensions.AI;
using OpenAI.Responses;

// Load .env file from the parent directory (agents_v2_maf_csharp/)
var envPath = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".env");
if (File.Exists(envPath))
    DotNetEnv.Env.Load(envPath);
else
    DotNetEnv.Env.Load(); // fallback to current directory

// ============================================================
// Testing Agents with Microsoft Agent Framework (C#)
// ============================================================
// This console app creates and runs agents using the
// Microsoft Agent Framework with Azure AI Foundry integration.
//
// Uses the same .env variables as the other samples:
//   - AZURE_AI_FOUNDRY_CONNECTION_STRING (project endpoint)
//   - AZURE_OPENAI_CHAT_DEPLOYMENT_NAME (model)
// ============================================================

var endpoint = Environment.GetEnvironmentVariable("AZURE_AI_FOUNDRY_CONNECTION_STRING")
    ?? throw new InvalidOperationException("AZURE_AI_FOUNDRY_CONNECTION_STRING environment variable is not set.");
var deploymentName = Environment.GetEnvironmentVariable("AZURE_OPENAI_CHAT_DEPLOYMENT_NAME") ?? "gpt-4.1-mini";

Console.WriteLine("🚀 Initializing Microsoft Agent Framework Testing (C#)...");
Console.WriteLine(new string('=', 60));
Console.WriteLine($"\n📋 Configuration:");
Console.WriteLine($"   📍 Endpoint: {(endpoint.Length > 50 ? endpoint[..50] + "..." : endpoint)}");
Console.WriteLine($"   🤖 Deployment: {deploymentName}");

Console.WriteLine("\n🔐 Setting up authentication...");
var credential = new DefaultAzureCredential();
Console.WriteLine("   ✅ Using Default Azure Credential");

Console.WriteLine("\n🔧 Initializing AIProjectClient...");
var aiProjectClient = new AIProjectClient(new Uri(endpoint), credential);
Console.WriteLine("   ✅ AIProjectClient ready (Microsoft Agent Framework)");

// Discover connections like the notebook flow.
Console.WriteLine("\n" + new string('=', 60));
Console.WriteLine("🔗 AVAILABLE CONNECTIONS");
Console.WriteLine(new string('=', 60));

string? modelGatewayConnectionStatic = null;
string? modelGatewayConnectionDynamic = null;
string? aiGatewayConnectionStatic = null;
string? aiGatewayConnectionDynamic = null;

var allConnections = aiProjectClient.Connections
    .GetConnections(connectionType: null, defaultConnection: null, cancellationToken: default)
    .ToList();
foreach (var connection in allConnections)
{
    var typeText = connection.Type.ToString();
    var icon = typeText.Contains("ModelGateway", StringComparison.OrdinalIgnoreCase)
        ? "🌐"
        : typeText.Contains("ApiManagement", StringComparison.OrdinalIgnoreCase)
            ? "🔌"
            : "📡";

    var defaultBadge = connection.IsDefault ? " ⭐ DEFAULT" : string.Empty;
    Console.WriteLine($"\n{icon} {connection.Name}{defaultBadge}");
    Console.WriteLine($"   Type: {connection.Type}");
    Console.WriteLine($"   ID: {(connection.Id.Length > 50 ? connection.Id[..50] + "..." : connection.Id)}");

    if (typeText.Contains("ModelGateway", StringComparison.OrdinalIgnoreCase) && connection.Name.Contains("static", StringComparison.OrdinalIgnoreCase))
    {
        modelGatewayConnectionStatic = connection.Name;
        Console.WriteLine("   📌 -> Assigned to: model_gateway_connection_static");
    }
    else if (typeText.Contains("ModelGateway", StringComparison.OrdinalIgnoreCase))
    {
        modelGatewayConnectionDynamic = connection.Name;
        Console.WriteLine("   📌 -> Assigned to: model_gateway_connection_dynamic");
    }

    if (typeText.Contains("ApiManagement", StringComparison.OrdinalIgnoreCase) && connection.Name.Contains("static", StringComparison.OrdinalIgnoreCase))
    {
        aiGatewayConnectionStatic = connection.Name;
        Console.WriteLine("   📌 -> Assigned to: ai_gateway_connection_static");
    }
    else if (typeText.Contains("ApiManagement", StringComparison.OrdinalIgnoreCase))
    {
        aiGatewayConnectionDynamic = connection.Name;
        Console.WriteLine("   📌 -> Assigned to: ai_gateway_connection_dynamic");
    }
}

Console.WriteLine($"\n📊 Total connections found: {allConnections.Count}");

static string BuildModelName(string deployment, string? connectionName)
    => string.IsNullOrWhiteSpace(connectionName) ? deployment : $"{connectionName}/{deployment}";

var staticConnectionForRoute = aiGatewayConnectionStatic ?? modelGatewayConnectionStatic;
var dynamicConnectionForRoute = aiGatewayConnectionDynamic ?? modelGatewayConnectionDynamic;
var hasDynamicConnection = !string.IsNullOrWhiteSpace(dynamicConnectionForRoute);

var staticGatewayModel = BuildModelName(deploymentName, staticConnectionForRoute);
var dynamicGatewayModel = BuildModelName(deploymentName, dynamicConnectionForRoute);

Console.WriteLine("\n" + new string('=', 60));
Console.WriteLine("✅ SETUP COMPLETE - Connection Summary");
Console.WriteLine(new string('=', 60));
Console.WriteLine($"   🌐 Model Gateway (Static):  {(modelGatewayConnectionStatic is null ? "❌ Not found" : "✅ " + modelGatewayConnectionStatic)}");
Console.WriteLine($"   🌐 Model Gateway (Dynamic): {(modelGatewayConnectionDynamic is null ? "❌ Not found" : "✅ " + modelGatewayConnectionDynamic)}");
Console.WriteLine($"   🔌 AI Gateway (Static):     {(aiGatewayConnectionStatic is null ? "❌ Not found" : "✅ " + aiGatewayConnectionStatic)}");
Console.WriteLine($"   🔌 AI Gateway (Dynamic):    {(aiGatewayConnectionDynamic is null ? "❌ Not found" : "✅ " + aiGatewayConnectionDynamic)}");

if (!hasDynamicConnection)
{
    throw new InvalidOperationException(
        "Dynamic gateway connection not found. Configure an ApiManagement or ModelGateway connection with a dynamic name before running this test suite.");
}

Console.WriteLine("\n🎉 Setup complete!");

// ============================================================
// Test 1: Agent via static APIM gateway
// ============================================================
Console.WriteLine($"\n\n🤖 AGENT WITH STATIC GATEWAY");
Console.WriteLine(new string('=', 60));
Console.WriteLine($"   🔗 Connection: {(aiGatewayConnectionStatic ?? modelGatewayConnectionStatic ?? "Not found (fallback: direct deployment)")}");
Console.WriteLine($"   🤖 Model route: {staticGatewayModel}");

AIAgent basicAgent = aiProjectClient.AsAIAgent(
    model: staticGatewayModel,
    name: "MAF-StaticGatewayAgent",
    instructions: "You are a helpful assistant that answers general questions.");
Console.WriteLine($"📝 Agent created: {basicAgent.Name}");

Console.WriteLine("\n⏳ Running agent...");
var basicResponse = await basicAgent.RunAsync("What is the size of Poland in square miles?");

Console.WriteLine("\n💬 Response:");
Console.WriteLine(new string('─', 40));
Console.WriteLine(basicResponse.Text);
Console.WriteLine(new string('─', 40));

// ============================================================
// Test 2: Agent via dynamic APIM gateway
// ============================================================
Console.WriteLine($"\n\n🤖 AGENT WITH DYNAMIC GATEWAY");
Console.WriteLine(new string('=', 60));
Console.WriteLine($"   🔗 Connection: {dynamicConnectionForRoute}");
Console.WriteLine($"   🤖 Model route: {dynamicGatewayModel}");

AIAgent dynamicAgent = aiProjectClient.AsAIAgent(
    model: dynamicGatewayModel,
    name: "MAF-DynamicGatewayAgent",
    instructions: "You are a helpful assistant.");
Console.WriteLine($"📝 Agent: {dynamicAgent.Name}");

Console.WriteLine("\n⏳ Running agent...");
var dynamicResponse = await dynamicAgent.RunAsync("What is the history of Warsaw? Keep it brief.");

Console.WriteLine("\n💬 Response:");
Console.WriteLine(new string('─', 40));
Console.WriteLine(dynamicResponse.Text);
Console.WriteLine(new string('─', 40));

// ============================================================
// Test 3: Streaming Response
// ============================================================
Console.WriteLine($"\n\n🌊 STREAMING RESPONSE TEST");
Console.WriteLine(new string('=', 60));
Console.WriteLine("Testing real-time streaming of agent responses");

AIAgent streamAgent = aiProjectClient.AsAIAgent(
    model: dynamicGatewayModel,
    name: "MAF-StreamingAgent",
    instructions: "You are a helpful assistant.");
Console.WriteLine($"📝 Agent: {streamAgent.Name}");

Console.WriteLine("\n🌊 Streaming response:");
Console.WriteLine(new string('─', 40));

await foreach (var update in streamAgent.RunStreamingAsync("Tell me hi in 10 random languages."))
{
    Console.Write(update.Text);
}

Console.WriteLine("\n" + new string('─', 40));
Console.WriteLine("✅ Stream completed!");

// ============================================================
// Test 4: Function Tools
// ============================================================
Console.WriteLine($"\n\n🔧 FUNCTION TOOL CALLS");
Console.WriteLine(new string('=', 60));
Console.WriteLine("Testing agent with custom function tools");

Console.WriteLine("\n🔌 Function tools configured:");
Console.WriteLine("   • GetWeather(location)");
Console.WriteLine("   • GetTime(timezone)");

Console.WriteLine("\n📝 Creating agent with function tools...");
AIAgent funcAgent = aiProjectClient.AsAIAgent(
    model: dynamicGatewayModel,
    name: "MAF-FunctionToolAgent",
    instructions: "You are a helpful agent. Use the provided tools to answer questions about weather and time.",
    tools: [AIFunctionFactory.Create(GetWeather), AIFunctionFactory.Create(GetTime)]);
Console.WriteLine($"   ✅ Agent: {funcAgent.Name}");

Console.WriteLine("\n⏳ Running agent (auto function calls)...");
var funcResponse = await funcAgent.RunAsync("What's the weather in Seattle and what time is it in US/Eastern?");

Console.WriteLine("\n💬 Response:");
Console.WriteLine(new string('─', 40));
Console.WriteLine(funcResponse.Text);
Console.WriteLine(new string('─', 40));

// ============================================================
// Test 5: Streaming with Function Tools
// ============================================================
Console.WriteLine($"\n\n🌊 STREAMING WITH FUNCTION TOOLS");
Console.WriteLine(new string('=', 60));
Console.WriteLine("Testing streaming + auto function call execution");

AIAgent streamFuncAgent = aiProjectClient.AsAIAgent(
    model: dynamicGatewayModel,
    name: "MAF-StreamFuncAgent",
    instructions: "You are a helpful agent. Use the provided tools to answer questions.",
    tools: [AIFunctionFactory.Create(GetWeather), AIFunctionFactory.Create(GetTime)]);
Console.WriteLine($"📝 Agent: {streamFuncAgent.Name}");

Console.WriteLine("\n🌊 Streaming response (with auto tool calls):");
Console.WriteLine(new string('─', 40));

await foreach (var update in streamFuncAgent.RunStreamingAsync("What's the weather like in Paris and Tokyo?"))
{
    Console.Write(update.Text);
}

Console.WriteLine("\n" + new string('─', 40));
Console.WriteLine("✅ Stream completed!");

// ============================================================
// Test 6: Hosted MCP Tool
// ============================================================
Console.WriteLine($"\n\n🔧 HOSTED MCP TOOL CALLS");
Console.WriteLine(new string('=', 60));
Console.WriteLine("Testing agent with hosted MCP tool");

var mcpTool = ResponseTool.CreateMcpTool(
    serverLabel: "weather",
    serverUri: new Uri("https://aca-mcp-qczp34j2qg7pk.ashyocean-7ea49412.westus.azurecontainerapps.io/mcp/mcp"),
    toolCallApprovalPolicy: new McpToolCallApprovalPolicy(GlobalMcpToolCallApprovalPolicy.NeverRequireApproval));
Console.WriteLine("🔌 MCP Tool configured:");
Console.WriteLine("   Name: weather");

Console.WriteLine("\n📝 Creating Foundry agent with MCP tool...");
var mcpAgentVersion = await aiProjectClient.AgentAdministrationClient.CreateAgentVersionAsync(
    "MAF-MCPAgent",
    new ProjectsAgentVersionCreationOptions(
        new DeclarativeAgentDefinition(dynamicGatewayModel)
        {
            Instructions = "You are a helpful agent that can use MCP tools to assist users. Use the available MCP tools to answer questions.",
            Tools = { mcpTool }
        }));

AIAgent mcpAgent = aiProjectClient.AsAIAgent(mcpAgentVersion);
Console.WriteLine($"   ✅ Agent: {mcpAgent.Name}");

Console.WriteLine("\n⏳ Running agent...");
AgentSession mcpSession = await mcpAgent.CreateSessionAsync();
var mcpResponse = await mcpAgent.RunAsync("What's the forecast for Seattle?", mcpSession);

Console.WriteLine("\n💬 Response:");
Console.WriteLine(new string('─', 40));
Console.WriteLine(mcpResponse.Text);
Console.WriteLine(new string('─', 40));

// Cleanup MCP agent
await aiProjectClient.AgentAdministrationClient.DeleteAgentAsync(mcpAgent.Name);
Console.WriteLine("🗑️ MCP Agent deleted");

// ============================================================
// Test 7: Agent Loop Test
// ============================================================
Console.WriteLine($"\n\n🔧 AGENT LOOP TEST");
Console.WriteLine(new string('=', 60));
Console.WriteLine("Running multiple agent iterations to capture errors and success rates");

AIAgent loopAgent = aiProjectClient.AsAIAgent(
    model: dynamicGatewayModel,
    name: "MAF-LoopTestAgent",
    instructions: "You are a helpful assistant that answers general questions concisely.");
Console.WriteLine($"   ✅ Agent: {loopAgent.Name}");

const int numIterations = 10;
var results = new List<(int Iteration, string Result, string Output)>();

Console.WriteLine($"\n⚙️ Test Configuration:");
Console.WriteLine($"   • Iterations: {numIterations}");
Console.WriteLine($"   • Model route: {dynamicGatewayModel}");

for (int i = 0; i < numIterations; i++)
{
    Console.WriteLine($"\n{new string('─', 60)}");
    Console.WriteLine($"🔄 Iteration {i + 1}/{numIterations}");
    Console.WriteLine(new string('─', 60));

    try
    {
        Console.WriteLine("   ⏳ Running agent...");
        var a = i * 7 + 3;
        var b = i * 11 + 5;
        var response = await loopAgent.RunAsync($"What is {a} + {b}? Reply with just the number.");
        var output = response.Text ?? "No output";

        results.Add((i + 1, "SUCCESS", output.Length > 100 ? output[..100] : output));
        Console.WriteLine("   ✅ SUCCESS");
        Console.WriteLine($"      Output: {(output.Length > 100 ? output[..100] : output)}");
    }
    catch (Exception ex)
    {
        var errorMsg = ex.Message.Length > 200 ? ex.Message[..200] : ex.Message;
        results.Add((i + 1, "ERROR", errorMsg));
        Console.WriteLine($"   ❌ ERROR: {errorMsg}");
    }
}

// Results summary
Console.WriteLine("\n" + new string('=', 60));
Console.WriteLine("📊 RESULTS TABLE");
Console.WriteLine(new string('=', 60));
Console.WriteLine($"{"Iteration",-12}{"Result",-10}{"Output/Error"}");
Console.WriteLine(new string('-', 60));
foreach (var r in results)
    Console.WriteLine($"{r.Iteration,-12}{r.Result,-10}{r.Output}");

// Save to CSV
var csvFile = "maf_agent_test_results.csv";
var csvLines = new List<string> { "Iteration,Result,Output/Error" };
csvLines.AddRange(results.Select(r => $"{r.Iteration},{r.Result},\"{r.Output.Replace("\"", "\"\"")}\""));
await File.WriteAllLinesAsync(csvFile, csvLines);
Console.WriteLine($"\n💾 Results saved to: {csvFile}");

var successes = results.Count(r => r.Result == "SUCCESS");
var errors = results.Count(r => r.Result == "ERROR");
var successRate = (double)successes / results.Count * 100;

Console.WriteLine("\n" + new string('=', 60));
Console.WriteLine("📈 SUMMARY");
Console.WriteLine(new string('=', 60));
Console.WriteLine($"   ✅ Successes: {successes}");
Console.WriteLine($"   ❌ Errors: {errors}");
Console.WriteLine($"   🎯 Success Rate: {successRate:F1}%");

if (successRate == 100)
    Console.WriteLine("\n🎉 All tests passed!");
else if (successRate >= 50)
    Console.WriteLine("\n⚠️ Some tests failed - check the results above");
else
    Console.WriteLine("\n❌ Most tests failed - investigate connection issues");

// ============================================================
// Test 8: MCP Agent Loop Test
// ============================================================
Console.WriteLine($"\n\n🔧 MCP AGENT LOOP TEST");
Console.WriteLine(new string('=', 60));
Console.WriteLine("Running MCP tools with agent - 10 iterations");

var loopMcpTool = ResponseTool.CreateMcpTool(
    serverLabel: "sample",
    serverUri: new Uri("https://sample-mcp-qczp34j2qg7pk.ashyocean-7ea49412.westus.azurecontainerapps.io/mcp"),
    toolCallApprovalPolicy: new McpToolCallApprovalPolicy(GlobalMcpToolCallApprovalPolicy.NeverRequireApproval));
Console.WriteLine("🔌 MCP Tool: sample");

Console.WriteLine("\n📝 Creating agent...");
var loopMcpAgentVersion = await aiProjectClient.AgentAdministrationClient.CreateAgentVersionAsync(
    "MAF-MCPLoopAgent",
    new ProjectsAgentVersionCreationOptions(
        new DeclarativeAgentDefinition(dynamicGatewayModel)
        {
            Instructions = "You are a helpful agent that can use MCP tools to assist users. Use the available MCP tools to answer questions and perform tasks.",
            Tools = { loopMcpTool }
        }));

AIAgent loopMcpAgent = aiProjectClient.AsAIAgent(loopMcpAgentVersion);
Console.WriteLine($"   ✅ Agent: {loopMcpAgent.Name}");

var mcpResults = new List<(int Iteration, string Result, string Output)>();

Console.WriteLine($"\n⚙️ Test Configuration:");
Console.WriteLine($"   • Iterations: {numIterations}");
Console.WriteLine($"   • Model route: {dynamicGatewayModel}");

for (int i = 0; i < numIterations; i++)
{
    Console.WriteLine($"\n{new string('─', 60)}");
    Console.WriteLine($"🔄 Iteration {i + 1}/{numIterations}");
    Console.WriteLine(new string('─', 60));

    try
    {
        Console.WriteLine("   ⏳ Running agent...");
        AgentSession session = await loopMcpAgent.CreateSessionAsync();
        var response = await loopMcpAgent.RunAsync(
            "Say hello using a random name with MCP tool.", session);
        var output = response.Text ?? "No output";

        mcpResults.Add((i + 1, "SUCCESS", output.Length > 500 ? output[..500] : output));
        Console.WriteLine("   ✅ SUCCESS");
        Console.WriteLine($"      Output: {(output.Length > 500 ? output[..500] : output)}");
    }
    catch (Exception ex)
    {
        var errorMsg = ex.Message.Length > 200 ? ex.Message[..200] : ex.Message;
        mcpResults.Add((i + 1, "ERROR", errorMsg));
        Console.WriteLine($"   ❌ ERROR: {errorMsg}");
    }
}

// Results summary
Console.WriteLine("\n" + new string('=', 60));
Console.WriteLine("📊 RESULTS TABLE");
Console.WriteLine(new string('=', 60));
Console.WriteLine($"{"Iteration",-12}{"Result",-10}{"Output/Error"}");
Console.WriteLine(new string('-', 60));
foreach (var r in mcpResults)
    Console.WriteLine($"{r.Iteration,-12}{r.Result,-10}{r.Output}");

// Save to CSV
var mcpCsvFile = "maf_mcp_agent_test_results.csv";
var mcpCsvLines = new List<string> { "Iteration,Result,Output/Error" };
mcpCsvLines.AddRange(mcpResults.Select(r => $"{r.Iteration},{r.Result},\"{r.Output.Replace("\"", "\"\"")}\""));
await File.WriteAllLinesAsync(mcpCsvFile, mcpCsvLines);
Console.WriteLine($"\n💾 Results saved to: {mcpCsvFile}");

var mcpSuccesses = mcpResults.Count(r => r.Result == "SUCCESS");
var mcpErrors = mcpResults.Count(r => r.Result == "ERROR");
var mcpSuccessRate = (double)mcpSuccesses / mcpResults.Count * 100;

Console.WriteLine("\n" + new string('=', 60));
Console.WriteLine("📈 SUMMARY");
Console.WriteLine(new string('=', 60));
Console.WriteLine($"   ✅ Successes: {mcpSuccesses}");
Console.WriteLine($"   ❌ Errors: {mcpErrors}");
Console.WriteLine($"   🎯 Success Rate: {mcpSuccessRate:F1}%");

if (mcpSuccessRate == 100)
    Console.WriteLine("\n🎉 All tests passed!");
else if (mcpSuccessRate >= 50)
    Console.WriteLine("\n⚠️ Some tests failed - check the results above");
else
    Console.WriteLine("\n❌ Most tests failed - investigate connection issues");

// Cleanup MCP loop agent
await aiProjectClient.AgentAdministrationClient.DeleteAgentAsync(loopMcpAgent.Name);
Console.WriteLine("\n🗑️ MCP Loop Agent deleted");

Console.WriteLine("\n\n🎉 All tests completed!");


// ============================================================
// Function Tool Definitions
// ============================================================

[Description("Get the weather for a given location.")]
static string GetWeather([Description("The city name to get weather for.")] string location)
    => $"The weather in {location} is 72°F and sunny.";

[Description("Get the current time in a given timezone.")]
static string GetTime([Description("The timezone name (e.g., 'US/Eastern').")] string timezone)
    => $"The current time in {timezone} is {DateTime.Now:HH:mm:ss}.";
