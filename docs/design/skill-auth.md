# ADK Elixir: Skill Auth Passthrough Design

**Status:** Draft  
**Author:** Zaf  
**Date:** 2026-03-23  
**FR from:** Alan Blount

## Problem Statement

A user authenticates with your app. Their identity and credentials need to flow
through to skills and every tool type inside those skills — Elixir functions,
shell scripts, Python scripts, MCP servers, A2A remote agents, sub-agents.

This is not simple. Auth in an agent system involves multiple overlapping concerns:

1. **User identity** — who is the end user? (OAuth2 3-leg, OIDC, session token)
2. **Agent identity** — who is the agent/service? (service account, mTLS, SPIFFE)
3. **API access** — what can we call? (API keys, scoped tokens, proxy tokens)
4. **Delegation** — can the agent act on behalf of the user? (on_behalf_of, token exchange)
5. **Composition** — a single tool call may need MULTIPLE credentials simultaneously
   (e.g., user's GitHub OAuth token + platform's OpenAI API key)

## The Hard Parts

### Multiple credentials per tool call

A code review skill might need:
- User's **GitHub OAuth token** (to read their private repos)
- Platform's **OpenAI API key** (to call GPT for analysis)
- User's **Jira API token** (to create tickets)

These are three different credential types, from three different sources,
all needed for one skill invocation.

### OAuth2 is not one thing

| Flow | Who authenticates | Use case |
|------|------------------|----------|
| Authorization Code (3-leg) | End user via browser | "Sign in with GitHub" |
| Client Credentials (2-leg) | Agent/service itself | Service-to-service calls |
| On-Behalf-Of / Token Exchange | Agent acting as user | Delegated access |
| Device Code | End user on limited device | CLI tools, IoT |
| Refresh Token | Background renewal | Long-running agents |

A skill might need different OAuth flows depending on whether:
- It's running in a web app (3-leg available)
- It's running in a CLI (device code flow)
- It's running in a background pipeline (service account only)

### Credential lifetime and refresh

User tokens expire. The agent might be mid-tool-call when a token expires.
The credential resolver must handle:
- Pre-flight token refresh
- Mid-flight 401 → retry with refreshed token
- Refresh token rotation (some providers rotate refresh tokens)

### Security boundaries

Tokens MUST NOT:
- Appear in LLM context (prompt or response)
- Be logged in plaintext
- Be stored in session state without encryption
- Be accessible to untrusted skills

### SPIFFE/SPIRE (workload identity)

In production, agent workloads should have cryptographic identity via SPIFFE SVIDs.
This means:
- The agent itself has a verifiable identity (X.509 or JWT SVID)
- mTLS between agent and tools/services
- No static API keys for service-to-service auth

**Current Elixir support:** None. No SPIFFE workload API client exists for Elixir.
Would need a gRPC client to the SPIRE agent's unix domain socket.

### Biscuit tokens (attenuated delegation)

Biscuit tokens allow:
- Authority block: "This token grants access to repos X, Y, Z"
- Attenuation block: "But only read access, and only until 5pm"
- Offline verification (no round-trip to auth server)

Perfect for agent delegation: "The user gave me full GitHub access, but this
skill only needs read access to one repo, so I attenuate the token before
passing it to the shell script."

**Current Elixir support:** None. No `biscuit-elixir` package exists.
Would need a NIF wrapper around the Rust implementation.

## Skill Auth Declaration

Every skill MUST declare its auth posture. No implicit defaults.

### Auth modes

```yaml
# SKILL.md frontmatter
---
name: github-reviewer
description: Reviews PRs and posts comments
auth:
  mode: user_passthrough      # REQUIRED — see modes below
  credentials:
    - name: github_token
      type: oauth2
      flow: authorization_code  # 3-leg
      scopes: ["repo", "read:org"]
      required: true
      description: "GitHub access for PR operations"
    - name: openai_key
      type: api_key
      source: platform          # from platform config, not user
      required: true
      description: "OpenAI for code analysis"
    - name: jira_token
      type: oauth2
      flow: authorization_code
      scopes: ["read:jira-work", "write:jira-work"]
      required: false           # optional — degrades gracefully
      description: "Jira for ticket creation"
---
```

| Mode | Meaning | When to use |
|------|---------|-------------|
| `unauthenticated` | No credentials needed | Pure computation skills |
| `service_account` | Uses platform's own identity | Internal API calls |
| `user_passthrough` | Acts on behalf of authenticated user | User-facing tools |
| `user_or_service` | Prefers user token, falls back to SA | Flexible skills |
| `explicit` | Skill brings its own credentials | Self-contained skills |
| `multi` | Needs multiple credential types simultaneously | Complex integrations |

### Credential source types

```elixir
@type credential_source ::
  :user       |  # From authenticated user's session
  :platform   |  # From platform/app configuration
  :skill      |  # Bundled with the skill itself
  :env        |  # Environment variable
  :vault      |  # HashiCorp Vault / GCP Secret Manager
  :runtime       # Resolved at runtime via callback
```

## The Common Credential Struct

One struct to rule them all. Passed everywhere credentials are needed.

```elixir
defmodule ADK.Auth.Credential do
  @type t :: %__MODULE__{
    # What type of credential
    type: :api_key | :oauth2 | :bearer | :service_account | :mtls | :biscuit | :spiffe,

    # The resolved, usable value
    token: String.t() | nil,

    # Metadata
    name: String.t(),                    # "github_token"
    source: credential_source(),         # :user, :platform, :skill
    scopes: [String.t()],               # OAuth scopes granted
    expires_at: DateTime.t() | nil,     # Token expiry
    refresh_token: String.t() | nil,    # For renewal

    # For multi-credential scenarios
    identity: identity_info(),           # Who this credential represents

    # Attenuation (future: Biscuit)
    attenuations: [attenuation()],       # Restrictions applied

    # Resolution status
    status: :resolved | :pending | :expired | :failed,
    error: String.t() | nil
  }

  @type identity_info :: %{
    type: :user | :service | :workload,
    id: String.t(),                      # user ID, SA email, SPIFFE ID
    display_name: String.t() | nil
  }

  @type attenuation :: %{
    scope: :read_only | :time_limited | :resource_scoped,
    params: map()
  }
end
```

## The Credential Resolver Pipeline

```elixir
defmodule ADK.Auth.CredentialResolver do
  @moduledoc """
  Resolves credential requirements to usable tokens.
  Called at skill load time and refreshed at tool execution time.
  """

  @doc """
  Resolve all credentials for a skill.
  Returns {:ok, resolved_map} or {:error, missing_creds}.
  """
  def resolve(skill, context) do
    skill.auth.credentials
    |> Enum.map(fn cred_req -> {cred_req.name, resolve_one(cred_req, context)} end)
    |> check_required(skill)
  end

  defp resolve_one(req, context) do
    case req.source do
      :user     -> resolve_from_session(req, context.session)
      :platform -> resolve_from_config(req, context.app_config)
      :env      -> resolve_from_env(req)
      :vault    -> resolve_from_vault(req, context.vault_client)
      :skill    -> resolve_from_skill(req, context.skill)
      :runtime  -> resolve_via_callback(req, context)
    end
  end
end
```

## How Credentials Reach Each Tool Type

### Elixir tools (in-process)

```elixir
# Credentials available via InvocationContext
def review_pr(%{"pr_url" => url}, context) do
  github = ADK.Auth.get_credential(context, "github_token")
  openai = ADK.Auth.get_credential(context, "openai_key")
  # Use directly — no serialization needed
end
```

### Shell scripts

```elixir
# Injected as prefixed env vars
System.cmd("bash", ["scripts/review.sh", pr_url], env: [
  {"ADK_CRED_GITHUB_TOKEN", github_token},
  {"ADK_CRED_OPENAI_KEY", openai_key},
  {"ADK_AUTH_MODE", "user_passthrough"},
  {"ADK_AUTH_USER_ID", user_id}
])
```

**Security:** Env vars are process-scoped in BEAM. Each `System.cmd` gets its
own OS process with isolated env. Tokens don't leak to other skills.

### Python scripts

```elixir
# Option A: env vars (same as shell)
System.cmd("python3", ["scripts/analyze.py"], env: cred_env_vars)

# Option B: temp credentials file (for complex auth like SA JSON)
{path, _} = System.cmd("mktemp", [])
File.write!(path, Jason.encode!(credentials))
System.cmd("python3", ["scripts/analyze.py", "--cred-file", path])
File.rm!(path)  # cleanup in ensure block
```

### MCP servers

```elixir
# Auth passed at MCP connection initialization
ADK.MCP.Toolset.start_link(
  command: "npx @anthropic/mcp-server-github",
  env: [{"GITHUB_TOKEN", github_token}],           # For stdio transport
  headers: [{"Authorization", "Bearer #{token}"}]   # For SSE transport
)
```

### A2A remote agents

```elixir
# Standard HTTP headers
ADK.Tool.RemoteAgent.call(url, task,
  headers: [
    {"Authorization", "Bearer #{user_token}"},        # User identity
    {"X-ADK-Agent-Identity", agent_spiffe_id},         # Agent identity
    {"X-ADK-Delegation", "on_behalf_of:#{user_id}"}   # Delegation chain
  ]
)
```

### Sub-agents (inherited)

```elixir
# Sub-agents inherit parent's credential context by default
# Can be restricted via attenuation
sub_agent = ADK.Agent.LlmAgent.new(
  name: "sub",
  auth_inherit: :restricted,  # only credentials this agent's skills need
  auth_filter: ["github_token"]  # explicit allowlist
)
```

## Validation Layers

### Load time (fast fail)

```elixir
# When Toolset is created
ADK.Skill.Toolset.new(skills, auth_context: ctx)
# Checks:
# - Every skill has auth.mode declared
# - Required credentials are resolvable
# - OAuth providers are configured for oauth2 credentials
# - Warns if user_passthrough but no user session
```

### Runtime (graceful degrade)

```elixir
# At tool execution
case CredentialResolver.resolve(skill, context) do
  {:ok, creds} ->
    execute_tool(tool, args, creds)
  {:error, {:missing, "jira_token"}} when not required ->
    execute_tool(tool, args, %{jira_token: nil})  # degrade
  {:error, {:missing, "github_token"}} when required ->
    {:error, "Authentication required: please sign in with GitHub"}
  {:error, {:expired, "github_token"}} ->
    case refresh_and_retry(context, "github_token") do
      {:ok, new_creds} -> execute_tool(tool, args, new_creds)
      {:error, _} -> {:error, "GitHub token expired, please re-authenticate"}
    end
end
```

## Security Rules

1. **Tokens never in LLM context.** Resolved at tool execution layer only.
2. **Tokens never in logs.** `ADK.Auth` redacts from telemetry automatically.
3. **Tokens never in session state unencrypted.** Encrypted at rest.
4. **Short-lived by default.** Resolved tokens have TTL; re-resolve on expiry.
5. **Scope narrowing.** Request minimum scopes per skill, not user's full grant.
6. **Audit trail.** `:adk.auth.credential_resolved` telemetry on every resolution.
7. **Skill isolation.** Each skill only sees credentials it declared. No global access.

## Feature Matrix

| Credential delivery | Elixir tool | Shell script | Python script | MCP server | A2A remote | Sub-agent |
|---------------------|-------------|-------------|---------------|------------|------------|-----------|
| Function arg (context) | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ (inherited) |
| Env var | ❌ | ✅ | ✅ | ✅ (init) | ❌ | ❌ |
| HTTP header | ❌ | ❌ | ❌ | ✅ (SSE) | ✅ | ❌ |
| Stdin pipe | ❌ | ✅ | ✅ | ✅ (stdio) | ❌ | ❌ |
| Temp file | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| mTLS | ❌ | ❌ | ❌ | ❌ | ✅ (future) | ❌ |

## Unresolved Requirements

### UR1: Multi-credential composition

A tool needs GitHub token (user) + OpenAI key (platform) + Jira token (user, optional).
How does the credential resolver know which credential goes where in the tool call?

**Options:**
- A: Named credentials — tool declares `needs: ["github_token", "openai_key"]`
- B: Typed credentials — tool declares `needs: [{:oauth2, "github"}, {:api_key, "openai"}]`
- C: Role-based — credentials tagged with roles: `:user_identity`, `:api_access`, `:delegation`

**Leaning:** A (named) — simplest, most explicit, matches Python ADK pattern.

### UR2: OAuth flow initiation from inside a skill

When a skill needs a user's OAuth token but the user hasn't authenticated:
- Who initiates the OAuth flow?
- How does the UI/client know to show a consent screen?
- How does the token get back to the agent?

Python ADK solves this with `adk_request_credential` events in the event stream.
The client intercepts these, shows a consent screen, and sends back the auth code.

**We have this:** `ADK.Auth.Handler` + `ADK.Auth.Preprocessor` handle this flow.
But it's not wired into the skill auth declaration system yet.

### UR3: Token exchange / delegation chains

User grants token to App → App delegates to Agent → Agent delegates to Skill → Skill calls API.

Each hop may need token exchange (RFC 8693) or on_behalf_of flow. The delegation
chain needs to be:
- Auditable (who delegated to whom)
- Attenuable (each hop can narrow scope)
- Revocable (revoking user's grant cascades)

**No Elixir library handles this today.** Would need custom implementation.

### UR4: Credential storage backend

Where do resolved credentials live?
- In-memory (process dict / ETS) — fast, lost on restart
- Session state — persisted, but security concerns
- External store (Vault, Secret Manager) — secure, latency
- Encrypted ETS — compromise

**Leaning:** Encrypted ETS for active tokens, external store for refresh tokens.

### UR5: Cross-skill credential isolation

Skill A has `github_token`. Skill B should NOT be able to access Skill A's
`github_token` even if they're loaded in the same agent. How?

**Options:**
- A: Process isolation — each skill runs in its own process/Task
- B: Credential namespacing — `skill_name:credential_name`
- C: Capability-based — skill receives only an opaque handle, not the raw token

**Leaning:** B for simplicity, C as aspirational (Biscuit tokens).

### UR6: Agent-to-agent credential forwarding

Agent A calls Agent B via A2A. Agent B needs to act on behalf of the same user.
How is the user's credential forwarded?

**Options:**
- A: Include token in A2A task metadata (simple, risky)
- B: Token exchange — Agent A gets a delegated token for Agent B (RFC 8693)
- C: Shared credential store — both agents read from same Vault/Secret Manager

**Leaning:** B for production, A acceptable for trusted internal agents.

### UR7: SPIFFE/SPIRE workload identity for Elixir

No Elixir SPIFFE client exists. To implement:
1. gRPC client to SPIRE agent's workload API (unix domain socket)
2. Receive X.509 SVID or JWT SVID
3. Use SVID for mTLS to other services
4. Auto-rotate on SVID expiry

**Effort estimate:** Medium. Needs `grpc` Elixir package + SPIFFE protobuf compilation.
Could be a separate `spiffe_elixir` Hex package.

### UR8: Biscuit tokens for Elixir

No Elixir Biscuit implementation exists. Options:
- A: NIF wrapping `biscuit-rust` — fast, complex build
- B: Port process wrapping `biscuit` CLI — simple, slower
- C: Pure Elixir implementation — large effort, full control
- D: JWT with custom claims as approximation — pragmatic

**Leaning:** D for now, A as future investment.

## Relationship to LLM Gateway

See [LLM Gateway Design](./llm-gateway.md).

Both designs share the credential resolution pattern:
- **Skill Auth:** User credentials → tools
- **LLM Gateway:** Platform credentials → LLM providers

The `ADK.Auth.Credential` struct and `source_config` types should be shared.
The `CredentialResolver` should handle both use cases with different source priorities.

## Implementation Priority

| Phase | What | Blocks |
|-------|------|--------|
| P0 | `auth.mode` required on skills, validation at load time | ExClaw |
| P0 | `CredentialResolver` with env + platform sources | ExClaw |
| P1 | OAuth2 flow initiation from skills (wire existing Handler) | User-facing apps |
| P1 | Multi-credential composition (named credentials) | Complex skills |
| P2 | Encrypted credential storage | Production deploys |
| P2 | Token exchange / delegation chains | Multi-agent systems |
| P3 | SPIFFE/SPIRE client | Service mesh deploys |
| P3 | Biscuit token support | Fine-grained delegation |
