# Teams Hosted Agent Capability Plan

## Status

This document records future work for the self-contained Microsoft Teams
hosted agent deployed from:

```text
options-infra/foundry-teams-hosted
```

The work is intentionally split into independent phases. Do not implement all
phases in one change.

The deployed architecture remains:

```text
Teams
  -> Azure Bot
  -> APIM
  -> Foundry hosted-agent Invocations 2.0 endpoint
  -> self-contained C# Teams agent
```

The Teams agent must continue to expose Invocations 2.0 and Responses 2.0. It
must not enable the separate Foundry Activity protocol.

## Goal

Extend the self-contained OTIS Teams agent with:

- Teams SSO and user identity context;
- delegated token exchange for downstream APIs;
- Foundry Toolbox tools using Entra passthrough and Foundry consent;
- PowerPoint generation through Code Interpreter;
- the existing OTIS PowerPoint template and a packaged PowerPoint skill;
- image generation through an explicit custom tool;
- native Teams File Consent and OneDrive delivery for generated files;
- strict separation of sessions, consent state, and credentials between users.

The agent should own both Teams transport and model/tool orchestration. It
should not proxy requests to the Medline `Alice` prompt agent.

## Existing building blocks

### OTIS

- Hosted agent:
  `hosted-agents/teams-agent`
- Deployment:
  `options-infra/foundry-teams-hosted`
- PowerPoint template:
  `hosted-agents/copilot-canary/assets/template.pptx`
- PowerPoint generation reference:
  `hosted-agents/copilot-canary/main.py`
- Current Toolbox:
  `teams-tools`
- Current public MCP connection:
  `teams-public-mcp`
- Current agent implementation:
  `hosted-agents/teams-agent/src/Services/DirectHostedAgent.cs`

The canary image includes `python-pptx`, Pillow, LibreOffice Impress, and the
PowerPoint template. These are useful references, but the Teams agent should
use Foundry Code Interpreter rather than embedding a second autonomous Python
agent.

### Medline reference implementation

Use the following repository as a source of focused Teams capabilities:

```text
/home/pkarpala/projects/medline/foundry-teams-bot-service-proxy
```

Relevant components include:

- `Services/TeamsSsoService.cs`
- `Services/AgentFileService.cs`
- `Services/TeamsFileService.cs`
- SSO invoke handling in `Bots/FoundryBot.cs`
- File Consent handling in `Bots/FoundryBot.cs`
- generated Code Interpreter file handling in `Bots/FoundryBot.cs`

Adapt these components to the smaller OTIS agent. Do not copy the complete
proxy, agent catalog, browser UI, multi-agent routing, or `Alice` continuation
logic.

## Non-goals

- Reintroducing the Medline proxy architecture.
- Calling the separate Medline `Alice` agent.
- Enabling Foundry Activity protocol.
- Persisting bearer tokens in Cosmos or hosted-agent sessions.
- Passing bearer tokens to the model as prompt content.
- Sending generated files as base64 `data:` attachments.
- Sharing a Toolbox client or authenticated state across users.
- Implementing all capabilities in one pull request.

## Phase 1: Hosted user context and session multiplexing

### Objective

Establish the Foundry protocol 2.0 user boundary, then multiplex Teams users
through a bounded pool of shared hosted-agent sessions.

### APIM session multiplexing

Do not create one hosted-agent session per Teams user. APIM is the middle tier
described by the Foundry session-multiplexing guidance: it maps many users onto
shared hosted sessions and identifies the acted-for user on every invocation.

The initial implementation may continue to use one session per agent version:

```text
teams-hosted-session:{agent}:{version}
```

If concurrency later requires a pool, add a stable pool slot:

```text
teams-hosted-session:{agent}:{version}:{pool-slot}
```

For every Bot Framework Activity, APIM must:

- parse `from.aadObjectId`;
- reject the delegated-tool path when the Entra object ID is absent;
- send the Entra object ID to Foundry as `x-ms-user-identity`;
- continue authenticating to Foundry with APIM's managed identity;
- never manufacture or forward `x-agent-user-id` or
  `x-agent-foundry-call-id` itself.

Foundry validates the delegation and injects trusted protocol 2.0 context into
the hosted container:

```text
x-agent-user-id
x-agent-foundry-call-id
```

The first value is the opaque, global user partition key for container-owned
state. The second is the per-request identifier that must be forwarded to
Foundry services such as Toolbox.

### APIM delegation role

Sending `x-ms-user-identity` requires APIM's managed identity to have a custom
role containing:

```text
Microsoft.CognitiveServices/accounts/AIServices/agents/endpoints/UserIdentityImpersonation/action
```

This action is not included in the existing Foundry User or Foundry Agent
Consumer roles.

Create the custom role in Bicep and assign it to the APIM managed identity at
the narrowest supported Foundry scope. Prefer a reusable module under
`options-infra/modules/iam/`; keep the role definition deterministic and make
the assignment idempotent.

### Invocations context validation

Protocol 2.0 supplies user and call context to both Responses and Invocations.
Before processing a Teams Activity, `ActivityInvocationHandler` must inspect:

```csharp
context.PlatformContext.UserIdKey
context.PlatformContext.CallId
FoundryAgentRequestContext.Current.UserId
FoundryAgentRequestContext.Current.CallId
```

Roll this out in stages:

1. expose the values in `/agent` and `/debug`;
2. add APIM `x-ms-user-identity` delegation;
3. verify both explicit and ambient contexts are populated and agree;
4. fail closed when either user ID or call ID is missing in the deployed
   protocol 2.0 path.

Local runs may omit this context and should require an explicit development
override rather than silently using a shared production partition.

### Runtime and Toolbox isolation

The `_agent` and `_toolboxClient` may remain shared across users. Toolbox
authentication is connection-owned, and Foundry resolves the current user from
the per-request call ID. `FoundryCallIdHandler` must remain on every outbound
Foundry/Toolbox HTTP pipeline so it forwards the ambient call ID and never the
user ID.

Container-owned state is not isolated automatically. Use:

```text
(Foundry user ID, Teams conversation ID)
```

for serialized `AgentSession` and Cosmos conversation state. Use:

```text
(hosted session ID, Foundry user ID, Teams conversation ID, artifact ID)
```

for generated files and other user-owned session artifacts.

### Persistence rules

Cosmos may store:

- user and conversation identifiers;
- serialized model conversation state;
- pending SSO message metadata;
- generated-file metadata;
- consent workflow state without credentials.

Cosmos must not store:

- Teams SSO tokens;
- Foundry tokens;
- MCP bearer tokens;
- OAuth authorization codes;
- OneDrive upload URLs;
- APIM subscription keys.

### Acceptance criteria

- Two users can share one APIM hosted-session ID.
- The hosted container receives different Foundry user IDs for the two users.
- Every invocation receives a non-empty Foundry call ID.
- The explicit Invocations platform context matches
  `FoundryAgentRequestContext.Current`.
- APIM has the custom user-identity delegation role.
- `FoundryCallIdHandler` forwards the current call ID to Toolbox.
- Two users in one group chat receive different Cosmos/model state.
- `/new` clears only the current user and conversation.
- `/signout` cannot affect another user.
- Logs and persisted state contain no bearer tokens.

## Phase 2: Teams SSO and delegated token exchange

### Objective

Authenticate the Teams user, make trusted identity attributes available to the
agent, and enable allowlisted downstream delegated-token acquisition.

This phase is deferred until after the initial Toolbox, skill, Code
Interpreter, image, and generated-file capability proof. It is not required
for Toolbox OAuth/OBO: Toolbox receives the Foundry call ID and owns its
connection-specific consent and token lifecycle.

### Application changes

Adapt the Medline `TeamsSsoService` and SSO flow:

- attempt silent token retrieval for each turn;
- display an OAuth card when silent SSO is unavailable;
- handle `signin/tokenExchange`;
- handle `signin/verifyState`;
- preserve and replay the pending user message after authentication;
- deduplicate repeated token-exchange invokes;
- implement `/signout`.

Expected OTIS changes:

- add `Services/TeamsSsoService.cs`;
- add a scoped user-execution context type;
- extend `Bots/ConversationState.cs` with pending SSO state;
- extend `Bots/FoundryBot.cs` with token-exchange invoke handling;
- register services in `src/Program.cs`.

### Infrastructure changes

Extend the runtime deployment to configure:

- a Bot Service OAuth connection;
- the required Entra application permissions and redirect configuration;
- Teams `webApplicationInfo`;
- `access_as_user`;
- pre-authorized Teams client applications;
- downstream delegated scopes.

Prefer federated identity credentials or managed workload identity over a
stored client secret.

### Trusted user context

Build user context from verified token claims and Bot Framework identity:

```json
{
  "teamsUser": {
    "displayName": "Example User",
    "email": "user@example.com",
    "tenantId": "tenant-guid",
    "aadObjectId": "object-guid"
  }
}
```

Inject this as trusted agent context, not as editable user text. The raw token
must never appear in the prompt.

Use verified claims for email when available. Treat `preferred_username`,
`upn`, or `email` as display attributes, not authorization decisions.

### Downstream token exchange

Add a service that:

- accepts only configured downstream resource scopes;
- obtains or exchanges a token for the current authenticated user;
- returns it directly to trusted tool code;
- never returns it to the model;
- refreshes tokens through the Bot token service;
- emits redacted diagnostics.

### Acceptance criteria

- A first-time user receives the expected Teams sign-in experience.
- Subsequent messages use silent SSO.
- The model receives the correct trusted name and email.
- `/signout` removes the user's authenticated runtime state.
- Downstream token acquisition is restricted to configured scopes.
- No raw token is visible in traces, cards, prompts, or Cosmos.

## Phase 3: Entra-passthrough Toolbox connection

### Objective

Use Foundry Toolbox for a downstream MCP server that requires user consent.

### Provisioning

Create an OTIS project connection for `cloud-helper` or its replacement. Do
not reference the Medline project's connection by ID.

Extend `teams-tools` to include:

- Microsoft Learn MCP;
- the Entra-passthrough MCP connection.

Foundry consent should remain the authority for the Toolbox connection. Teams
SSO authenticates the user to the Teams bot; Foundry Toolbox consent
authorizes the downstream MCP resource. These are separate workflows.
The initial capability proof may use the trusted Teams `aadObjectId` delegated
by APIM before the broader Teams SSO user experience is implemented.

### Runtime behavior

The shared Toolbox client authenticates to Foundry with the hosted agent
identity. `FoundryCallIdHandler` propagates the current protocol call ID on
every request, and Toolbox resolves the user and performs OAuth/OBO from the
project connection.

Do not add a user-token cache or pass a user bearer token into
`DirectHostedAgent`.

Handle:

- consent-required responses;
- consent continuation;
- expired or revoked Toolbox credentials;
- safe Toolbox initialization failure;
- normal error reporting after a tool execution has started.

### Tool replay safety

Remove the generic retry behavior from `DirectHostedAgent`:

- do not retry the complete agent run because no text update was emitted;
- do not retry arbitrary MCP HTTP `POST` requests;
- never automatically replay `tools/call`;
- retry only connection initialization and tool discovery operations that are
  known not to execute a tool;
- after `RunStreamingAsync` starts, surface failures without replaying the
  user's request;
- mark a failed shared Toolbox generation stale and rebuild it before the next
  user-initiated request;
- do not dispose a stale agent or MCP client while another multiplexed request
  is using it.

### Acceptance criteria

- User A's `whoami` result identifies User A.
- User B's `whoami` result identifies User B.
- User A's consent does not authorize User B.
- Revoking consent causes a new consent request.
- Initialization can reconnect without executing a tool.
- A `401` or `invalid_token` during tool execution is surfaced without replay.
- A request is not replayed automatically after a tool may have executed.

## Phase 4: PowerPoint skill and Code Interpreter

### Objective

Generate branded PowerPoint files through Foundry Code Interpreter.

### Persistent working session

The hosted-agent process and APIM hosted session are multiplexed and must not
own user files. Persist the remote Code Interpreter `container_id` inside the
serialized `AgentSession` for the logical:

```text
(Foundry user ID, Teams conversation ID)
```

boundary. Follow-up turns in the same conversation reuse that container and
its `/mnt/data` working directory, so the agent can reopen and revise an
existing presentation. A different user or Teams conversation receives a
different `AgentSession` and container.

Foundry keeps Code Interpreter outputs as downloadable `assistant` container
files, but does not automatically remount them into later executions. After
validating each generated artifact, upload it back into the same container as
a user-owned input. Foundry prefixes uploaded filenames; the code wrapper
restores the original basename under `/mnt/data` before executing model code.

The `container_id` is private orchestration state, never a model/tool
parameter. Bind it to the validated protocol user ID and reject an owner
mismatch when a session is restored. Do not copy user working files onto the
hosted-agent filesystem; only packaged static assets such as the canonical
template live there.

Code Interpreter containers can expire independently of conversation history.
If a persisted container returns `404`, clear the stale reference and report
that the previous working files expired. Do not silently create a replacement
while claiming continuity.

### Skill package

Create:

```text
hosted-agents/teams-agent/skills/powerpoint/
├── SKILL.md
├── assets/
│   └── template.pptx
└── references/
    └── layouts.md
```

Copy the canonical template from:

```text
hosted-agents/copilot-canary/assets/template.pptx
```

The skill should describe:

- when presentation generation is appropriate;
- mandatory use of the supplied template;
- named slide layouts and intended uses;
- slide-count and content-density rules;
- speaker notes;
- source citations and image attribution;
- output naming;
- `python-pptx` validation;
- LibreOffice rendering checks;
- overflow and broken-layout remediation.

Provision the directory as a versioned Foundry skill and attach it to
`teams-tools`.

### Toolbox tools

Add:

- web search;
- Code Interpreter;
- the PowerPoint skill.

The source of truth for the skill and template remains Git. Deployment creates
or updates the Foundry skill and publishes the Toolbox version that references
it.

### Capability validation gate

Before implementing Teams File Consent, prove the complete Foundry capability
path inside the hosted environment:

1. the Toolbox default version exposes Microsoft Learn MCP, the
   Entra-passthrough MCP connection, Code Interpreter, and the PowerPoint
   skill;
2. the model can discover and invoke the skill;
3. Code Interpreter can read the packaged `template.pptx`;
4. Code Interpreter can import or install `python-pptx` and Pillow;
5. Code Interpreter can create a valid `.pptx` using the supplied template;
6. Code Interpreter can install or use a rendering tool when available;
7. a generated image can be transferred into the Code Interpreter execution;
8. the resulting presentation can be downloaded through the authenticated
   Foundry file API.

The canary demonstrates the desired Python workflow and package set, but its
container image is not the Code Interpreter environment. Treat package
installation as an expected supported capability and fail clearly if the
environment prevents it.

### Artifact handling

Inspect `AgentResponseUpdate.Contents` and provider-specific raw response items
instead of consuming only `update.Text`.

Create an adapter that:

- recognizes `HostedFileContent`, Code Interpreter output files, and
  container-file annotations;
- downloads the file through an authenticated project/container-file client;
- uses an HTTP pipeline containing `FoundryCallIdHandler`;
- enforces file-count, per-file, aggregate-cache, and expiration limits;
- validates the extension, MIME type, and file signature;
- binds the artifact to the hosted session, Foundry user ID, and Teams
  conversation ID;
- returns a typed generated-file object to the Teams layer.

### Acceptance criteria

- The deployed Toolbox exposes the expected tools and skill version.
- The agent invokes the packaged PowerPoint skill.
- Code Interpreter installs or imports the required Python packages.
- The agent uses the OTIS template.
- The resulting `.pptx` opens successfully.
- A rendered preview has no obvious overflow or missing content.
- The file is captured and downloaded as a real generated artifact.
- Another user in the same hosted session cannot download the artifact.
- The model cannot choose an arbitrary local template path.

## Phase 5: Native Teams file delivery

**Status:** Implemented for generated files in personal Teams chats. Consent
tokens are bound to the trusted Foundry user and Teams conversation, uploads
are idempotent across Connector retries, and completed upload metadata remains
available until expiration so `FileInfoCard` delivery can be retried.

### Objective

Deliver generated PowerPoint and other supported artifacts through Teams File
Consent and the Teams-provided OneDrive upload session.

### Application changes

Adapt:

- `AgentFileService`;
- `TeamsFileService`;
- generated-file capture;
- `OnTeamsFileConsentAcceptAsync`;
- `OnTeamsFileConsentDeclineAsync`.

Required flow:

```text
Code Interpreter creates a file
  -> hosted agent downloads and temporarily caches the bytes
  -> bot sends FileConsentCard
  -> user accepts
  -> bot uploads bytes to the Teams-provided OneDrive URL
  -> bot sends FileInfoCard
```

Security requirements:

- permit only expected SharePoint, OneDrive, and configured storage hosts;
- never log upload URLs;
- expire cached files;
- enforce per-file and process-wide size limits;
- remove cached bytes after upload or decline;
- bind pending files to the requesting user and conversation.

### MCP result attachment distinction

MCP tool output is not automatically a user file. Normal MCP results should:

- remain internal to the model; or
- appear as a bounded, redacted Adaptive Card preview when explicitly enabled.

Do not convert arbitrary MCP JSON into a base64 `data:` attachment. Teams
Connector rejects that attachment shape.

Only genuine generated artifacts such as `.pptx`, `.pdf`, `.docx`, `.xlsx`,
or images should use File Consent.

### Acceptance criteria

- A generated PowerPoint produces a File Consent card.
- Accept uploads the exact file to the user's OneDrive.
- Decline removes the pending bytes.
- Expired files produce a clear retry message.
- Another user cannot accept or retrieve the pending file.
- No `data:` attachment is sent to Teams.

## Phase 6: Image-generation tool

### Objective

Allow the agent to generate images for answers and presentations through an
explicit trusted tool.

### Tool contract

Implement a typed tool similar to:

```text
generate_image(prompt, size, style, purpose)
```

The tool should:

- call a configured APIM image-generation endpoint;
- authenticate with the hosted identity;
- use an operator-selected image deployment;
- validate output MIME type and size;
- return a typed image artifact;
- store the image in the current user's artifact partition;
- upload or attach the image to the active Code Interpreter execution as
  `DataContent`, `HostedFileContent`, or a provider-specific file reference;
- make the resulting hosted file reference available to the PowerPoint
  workflow;
- prevent the model from selecting endpoints, credentials, or deployment
  names.

Do not transfer images to Code Interpreter through prompt text, public URLs, or
base64 Teams attachments. If the Agent Framework provider cannot bridge typed
image content directly, upload the validated bytes through the Foundry
project/container file API and pass the resulting file ID.

### Infrastructure

Provision or reference an image-capable model through the existing OTIS AI
Gateway modules. Expose only the required image-generation operation to the
agent.

### Acceptance criteria

- The agent can generate an image and include it in a presentation.
- Code Interpreter reads the transferred image as a real file.
- Authentication headers and model endpoints are not visible to the model.
- Invalid or oversized image output is rejected.
- Generated images follow the same per-user artifact isolation rules.

## Phase 7: Commands and diagnostics

Retain or add:

- `/new`: clears the current user and conversation only;
- `/signout`: signs the user out and clears only that user's conversation,
  consent workflow state, and pending artifacts; it does not dispose the
  shared Toolbox client;
- `/agent`: shows non-sensitive hosted-agent and session details, including
  the current Foundry protocol user ID;
- `/debug`: shows the Foundry protocol user ID and call ID together with
  redacted routing and consent diagnostics;
- `/help`: documents supported commands.

Redact:

- bearer tokens;
- authorization codes;
- consent URLs containing state;
- APIM subscription keys;
- OneDrive upload URLs;
- opaque authentication metadata other than the protocol user ID and call ID
  intentionally shown by `/agent` and `/debug`;
- sensitive MCP output.

## Test matrix

Each phase should add focused tests before deployment.

### Identity and isolation

- two personal-chat users;
- two users in one group conversation;
- same user in two conversations;
- two users sharing one hosted-agent session;
- missing `x-ms-user-identity`;
- missing protocol user ID or call ID;
- explicit and ambient Invocations context mismatch;
- APIM delegation without the custom role returns the expected `403`;
- session expiration;
- `/new`;
- `/signout`;
- concurrent first requests.

### Authentication

- silent SSO success;
- interactive sign-in;
- duplicate token-exchange invoke;
- expired user token;
- revoked consent;
- downstream scope rejection.

### Toolbox

- public MCP;
- Entra-passthrough MCP consent;
- `whoami` identity;
- call ID propagation from Invocations to Toolbox;
- initialization-only reconnect;
- no retry of `tools/call`;
- `401` during tool execution is surfaced;
- no retry after possible side effects.

### PowerPoint and files

- Toolbox exposes Code Interpreter and the PowerPoint skill;
- the model invokes the skill;
- template is available to Code Interpreter;
- `python-pptx` and Pillow import or install successfully;
- generated `.pptx` is valid;
- generated file is captured and downloaded through the Foundry API;
- a second multiplexed user cannot download the file;
- File Consent accept;
- File Consent decline;
- expired file;
- wrong user attempting acceptance;
- oversized file;
- disallowed upload host.

### Images

- successful image generation;
- model/API failure;
- invalid content type;
- oversized response;
- image is uploaded or attached to Code Interpreter;
- PowerPoint embedding.

## Recommended delivery sequence

Implement as separate pull requests:

1. **Protocol user diagnostics, APIM `x-ms-user-identity`, and custom role**
2. **Multiplex-safe Cosmos/model state and Tool replay safety**
3. **Entra-passthrough Toolbox connection and consent**
4. **PowerPoint skill, template, and Code Interpreter capability proof**
5. **Image generation and Code Interpreter artifact transfer**
6. **Generated-file capture and authenticated download**
7. **Teams SSO and trusted display context**
8. **Native Teams File Consent**
9. **Cross-user security and end-to-end hardening**

The first release target is a hosted-agent capability proof: Toolbox OBO,
skills, the PowerPoint template, Code Interpreter package installation, image
transfer, and generated-file download. Native Teams file delivery and the
broader Teams SSO experience may follow after those capabilities work.

## Deferred isolation TODO

The following must remain explicitly tracked until validated:

- Confirm APIM's `x-ms-user-identity` produces distinct protocol user IDs for
  two users sharing one hosted session.
- Confirm `FoundryCallIdHandler` forwards the protocol call ID on every
  Toolbox and generated-file API request.
- Confirm serialized `AgentSession` data cannot contain delegated credentials.
- Add a concurrent two-user test that invokes `cloud-helper/whoami`.
- Add a group-chat test with two senders sharing the same Teams conversation.
- Verify token refresh and consent revocation without restarting the container.
- Verify a shared MCP client never crosses user identity when concurrent calls
  carry different call IDs.
- Verify all artifact caches have capacity and TTL limits.
- Verify Code Interpreter package installation, skill assets, image input, and
  output-file download in the deployed hosted environment.
- Verify `/new`, `/signout`, deployment, and APIM recovery evict only the
  intended scope.
- Document incident response for suspected token or session crossover.

This TODO is a release gate for enabling Entra-passthrough tools in a
multi-user Teams installation.
