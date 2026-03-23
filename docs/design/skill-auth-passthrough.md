# ADK Elixir: Skill Auth Passthrough Design

**Status:** Draft  
**Author:** Zaf  
**Date:** 2026-03-23  
**ADK Elixir:** `adk` v0.0.1-alpha.1  

## Problem Statement

When a user authenticates with an ADK-powered application, their identity and
credentials need to flow through to skills and the tools inside those skills —
shell scripts, Python scripts, MCP servers, Elixir tools, A2A remote agents,
and sub-agents. Each tool type has a different mechanism for receiving
credentials. The auth landscape is complex: a single skill invocation may need
**both** user OAuth2 tokens **and** service account API keys simultaneously.

## Identities in Play

An ADK agent system involves multiple distinct identities that may all be
active during a single tool invocation:

| Identity | What it is | Example |
|----------|-----------|---------|
| **End User** | The human using the application | Alice (OAuth2 bearer token from Google Sign-In) |
| **Agent** | The AI agent's own identity | `adk-agent-prod` (service account, SPIFFE SVID, or API key) |
| **Application** | The hosting app's identity | `my-saas-app` (OAuth2 client credentials) |
| **Downstream Service** | The API/tool being called | GitHub API (needs user's GitHub OAuth token) |
| **MCP Server** | A tool provider process | `@anthropic/mcp-server-github` (needs auth to call GitHub) |

### Multi-credential scenarios (common, not edge cases)

1. **User + API key:** OAuth2 user token for "who is asking" + OpenAI API key
   for "which LLM to call"
2. **User + Service Account:** User's Google token for Drive access + service
   account for BigQuery billing
3. **User + User (different providers):** Google OAuth for calendar + GitHub
   OAuth for PR review — same user, different providers
4. **Agent + User:** Agent's own SPIFFE identity for service mesh auth + user's
   token for data access
5. **Delegated:** User token → attenuated/scoped token passed to sub-agent
   (Biscuit-style)

## Auth Modes (every skill MUST declare one)

```yaml
# SKILL.md frontmatter
---
name: github-reviewer
auth:
  mode: user_passthrough  # REQUIRED
  credentials:
    - name: github_token
      type: oauth2
      flow: authorization_code  # 3-legged
      scopes: ["repo", "read:org"]
      required: true
    - name: openai_key
      type: api_key
      required: true
      source: config  # not from user, from app config
---
```

| Mode | Meaning | Credential sources |
|------|---------|-------------------|
| `unauthenticated` | No credentials needed | None |
| `service_account` | Uses app/agent's own identity | App config, ADC, SPIFFE |
| `user_passthrough` | Acts on behalf of authenticated user | Session → OAuth2/OIDC tokens |
| `user_or_service` | Prefers user, falls back to service | Session → App config |
| `explicit` | Skill provides its own credentials | Skill config, env vars |
| `delegated` | Receives attenuated token from parent | Parent context → scoped token |

## OAuth2 Complexity

OAuth2 alone has multiple flows, each with different trust models:

| Flow | Legs | Who authenticates | Use case |
|------|------|-------------------|----------|
| Authorization Code | 3-leg | End user (browser redirect) | User grants access to their data |
| Client Credentials | 2-leg | Application (client_id/secret) | Server-to-server, no user involved |
| On-Behalf-Of (OBO) | Hybrid | App exchanges user token | App calls API as user, without user present |
| Device Code | 2-leg + user | User (out-of-band) | CLI tools, IoT, headless agents |
| Refresh Token | N/A | Stored refresh → new access | Long-lived sessions |

A skill might need **authorization_code** for user-facing GitHub access **and**
**client_credentials** for the OpenAI API — in the same invocation.

## Credential Bag (the common struct)

Rather than threading individual tokens, we pass a **credential bag** — a
single struct that travels with every tool invocation and can hold multiple
credentials of different types simultaneously.

```elixir
defmodule ADK.Auth.CredentialBag do
  @moduledoc """
  A collection of resolved credentials that flows through the entire
  tool invocation chain. Supports multiple simultaneous credentials
  of different types.
  """

  @type credential_entry :: %{
    name: String.t(),           # "github_token", "openai_key"
    type: :oauth2 | :api_key | :bearer | :basic | :mtls | :spiffe | :biscuit,
    value: String.t() | map(),  # The actual credential material
    identity: :user | :agent | :application | :delegated,
    scopes: [String.t()],       # Granted scopes
    expires_at: DateTime.t() | nil,
    metadata: map()             # Provider-specific (issuer, audience, etc.)
  }

  @type t :: %__MODULE__{
    credentials: [credential_entry()],
    user_id: String.t() | nil,
    agent_id: String.t() | nil,
    session_id: String.t() | nil
  }

  defstruct credentials: [], user_id: nil, agent_id: nil, session_id: nil

  @doc "Get a specific credential by name."
  @spec get(t(), String.t()) :: {:ok, credential_entry()} | :not_found

  @doc "Get all credentials for a specific identity type."
  @spec for_identity(t(), :user | :agent | :application) :: [credential_entry()]

  @doc "Check if a required credential set is satisfied."
  @spec satisfies?(t(), [%{name: String.t(), type: atom()}]) :: boolean()
end
```

## Credential Resolver Pipeline

```
Request arrives with user session
         │
         ▼
┌─────────────────────────┐
│ 1. Session credentials  │  User's OAuth tokens from login
│    (user identity)      │
├─────────────────────────┤
│ 2. App config           │  Service accounts, API keys from config
│    (agent/app identity) │
├─────────────────────────┤
│ 3. Skill config         │  Skill-specific credentials (explicit mode)
│    (explicit identity)  │
├─────────────────────────┤
│ 4. Environment          │  ADK_CRED_* env vars (fallback)
│    (deployment-level)   │
├─────────────────────────┤
│ 5. Token exchange       │  OBO flow, refresh, SPIFFE attestation
│    (derived identity)   │
├─────────────────────────┤
│ 6. Interactive          │  Trigger OAuth consent if needed
│    (user interaction)   │  (pause agent, redirect user, resume)
└─────────────────────────┘
         │
         ▼
   CredentialBag (populated)
         │
         ▼
   Tool execution layer
```

```elixir
defmodule ADK.Auth.CredentialResolver do
  @moduledoc """
  Resolves credentials for a skill's requirements from multiple sources.
  Returns a populated CredentialBag or signals that interaction is needed.
  """

  @type resolve_result ::
    {:ok, CredentialBag.t()}
    | {:needs_auth, auth_request :: map()}  # Trigger OAuth flow
    | {:error, missing :: [String.t()]}     # Unresolvable credentials

  @callback resolve(
    requirements :: [map()],
    context :: ADK.InvocationContext.t()
  ) :: resolve_result()
end
```

## How Credentials Reach Each Tool Type

| Tool type | Env vars | Function args | HTTP headers | Stdin/pipe | File |
|-----------|----------|---------------|-------------|------------|------|
| **Elixir tool** | ❌ | ✅ `context.credentials` | N/A | N/A | N/A |
| **Shell script** | ✅ `ADK_CRED_*` | ✅ argv | N/A | ✅ | ✅ tmp file |
| **Python script** | ✅ `ADK_CRED_*` | ✅ argv | N/A | ✅ | ✅ tmp file |
| **MCP server** | ✅ (at init) | N/A | ✅ (SSE transport) | ✅ (stdio) | N/A |
| **A2A remote** | N/A | N/A | ✅ `Authorization` | N/A | N/A |
| **Sub-agent** | Inherited | ✅ `context.credentials` | N/A | N/A | N/A |

### Injection patterns

```elixir
# Elixir tool — credentials in context
def my_tool(args, context) do
  {:ok, token} = ADK.Auth.CredentialBag.get(context.credentials, "github_token")
  # use token.value
end

# Shell script — env vars (ADK.Skill.ExecTool)
System.cmd("bash", [script_path], env: [
  {"ADK_CRED_GITHUB_TOKEN", token.value},
  {"ADK_CRED_GITHUB_TOKEN_TYPE", "oauth2"},
  {"ADK_CRED_OPENAI_KEY", api_key.value},
  {"ADK_IDENTITY", "user"},
  {"ADK_USER_ID", bag.user_id}
])

# MCP server — Authorization header or env at startup
ADK.MCP.Toolset.start_link(
  command: "npx @anthropic/mcp-server-github",
  env: [{"GITHUB_TOKEN", token.value}],
  # OR for SSE transport:
  headers: [{"Authorization", "Bearer #{token.value}"}]
)

# A2A remote — HTTP header
ADK.Tool.RemoteAgent.call(url, task,
  headers: [{"Authorization", "Bearer #{token.value}"}]
)
```

## Elixir Ecosystem Libraries

| Library | What it does | Relevance |
|---------|-------------|-----------|
| **assent** | Multi-provider OAuth2/OIDC strategy framework | User login flows, token acquisition |
| **ueberauth** | Plug-based auth framework with provider strategies | Phoenix app user auth |
| **goth** | Google service account OAuth2 token generation | GCP service account credentials |
| **joken** | JWT creation/validation | Token verification, custom claims |
| **boruta** | Full OAuth2/OIDC authorization server | If ADK needs to *issue* tokens |
| **pow/pow_assent** | Full user auth system with multi-provider | If building a full app on top |
| **guardian** | JWT-based session/auth for Phoenix | Token-based auth in Phoenix apps |
| **x509** | X.509 certificate handling | mTLS, SPIFFE SVIDs |

### What's missing in the Elixir ecosystem

- **No Biscuit library for Elixir.** Rust has `biscuit-auth`, there's no Hex
  package. Would need NIF wrapper or pure Elixir implementation.
- **No SPIFFE Workload API client.** Would need gRPC client for SPIRE agent.
- **No unified credential bag pattern.** Each library manages its own tokens.
  ADK's `CredentialBag` would be novel.

## Unresolved Design Questions

### 1. Token lifecycle ownership

Who refreshes expired tokens? Options:
- **a)** CredentialBag is immutable — resolver re-resolves on each invocation
- **b)** CredentialBag has a GenServer that auto-refreshes (like Goth)
- **c)** Lazy refresh — check expiry, refresh inline if needed

Trade-off: (a) is simplest but wasteful; (b) is most correct but complex;
(c) is pragmatic but can cause latency spikes.

### 2. Credential scoping / attenuation

When a skill calls a sub-agent, should the sub-agent get the **full**
credential bag or an **attenuated** version? Biscuit tokens solve this
elegantly (add restrictions, can't remove them), but there's no Elixir
library. Options:
- **a)** Pass full bag, trust skills (simple, insecure)
- **b)** Skill declares what it passes down (configuration-based narrowing)
- **c)** Build a Biscuit NIF or pure Elixir implementation (correct, expensive)
- **d)** Use standard OAuth2 scope narrowing on re-issued tokens

### 3. MCP auth negotiation

MCP spec defines auth via OAuth2 for HTTP/SSE transport. But many MCP servers
use stdio transport where there's no HTTP layer for auth headers. Current
pattern: inject credentials via env vars at process startup. This means
credentials are fixed for the lifetime of the MCP server process — no
per-request user passthrough for shared MCP servers.

Options:
- **a)** One MCP server per user session (resource-heavy, correct)
- **b)** Shared MCP server with per-request auth injection (needs MCP spec work)
- **c)** Only support env-based auth for stdio MCP (simple, limited)

### 4. Credential storage security

Session state stores credentials. If session is persisted (Ecto, Redis), tokens
are at rest. Options:
- **a)** Encrypt credentials in session store (needs key management)
- **b)** Store only token references, resolve from secret manager at runtime
- **c)** Short-lived tokens only, re-auth on session restore
- **d)** Pluggable — let the SessionService implementation decide

### 5. Multi-tenant credential isolation

In a multi-tenant deployment, User A's credentials must never leak to User B's
tool invocations, even if they share the same agent process. The CredentialBag
must be scoped to the invocation context, never shared across sessions.

### 6. Agent-to-Agent auth chain

When Agent A calls Agent B via A2A, what identity does B see? Options:
- **a)** Agent A's identity only (service-to-service)
- **b)** End user's identity only (full passthrough)
- **c)** Both — A2A supports `on_behalf_of` header (like OAuth OBO)
- **d)** Attenuated token — A narrows B's access

### 7. OAuth consent in agent flows

When an agent needs a user OAuth token that doesn't exist yet, the agent must
**pause execution**, present an auth URL to the user, wait for callback, then
**resume**. This is fundamentally different from web app OAuth (redirect →
callback) because the agent is mid-invocation.

Python ADK handles this via `adk_request_credential` function calls in the
event stream. We have `ADK.Auth.Handler` and `ADK.Auth.Preprocessor` for this,
but the UX for different surfaces (CLI, web, chat) varies wildly.

### 8. SPIFFE/SPIRE integration path

SPIFFE provides workload identity — the agent process itself gets a
cryptographic identity (X.509 SVID) attested by SPIRE. This is orthogonal to
user auth but critical for:
- mTLS between agent ↔ tool services
- Proving agent identity to downstream APIs
- Zero-trust network postures

No Elixir SPIFFE client exists. Options:
- **a)** Build gRPC client for SPIRE Workload API
- **b)** Use envoy sidecar for mTLS (infrastructure-level, no code)
- **c)** Park this — only matters for production mesh deployments

### 9. Biscuit tokens for capability delegation

Biscuit tokens are perfect for agent chains — each hop can attenuate (narrow)
the token's capabilities without contacting the issuer. But:
- No Elixir implementation exists
- Would need Rust NIF (biscuit-auth crate) or pure Elixir port
- Is the complexity justified vs. simpler scope-based narrowing?

## Proposed Implementation Phases

### Phase 1: Foundation (P0)
- `ADK.Auth.CredentialBag` struct
- `ADK.Auth.CredentialResolver` pipeline (session → config → env)
- Skill `auth:` frontmatter parsing and validation
- CredentialBag injection into `InvocationContext`
- ExecTool env var injection from CredentialBag

### Phase 2: Tool integration (P1)
- MCP server credential injection (env + headers)
- A2A remote agent auth headers
- OAuth2 interactive flow (pause/resume agent for consent)
- Token refresh handling (lazy inline refresh)

### Phase 3: Advanced (P2)
- Multi-provider credential resolution (user GitHub + user Google)
- On-behalf-of token exchange
- Credential encryption in persistent session stores
- Audit trail telemetry (`:adk.auth.credential_resolved`)

### Phase 4: Production hardening (P3)
- SPIFFE/SPIRE workload identity (if demand exists)
- Biscuit token support (if Elixir library emerges or we NIF it)
- Credential scoping/attenuation for sub-agent delegation
- Formal security audit of credential flow

## Security Invariants (non-negotiable)

1. **Tokens never in LLM context.** Credentials resolved at tool execution
   layer, never passed through model prompts or responses.
2. **Tokens never in logs.** CredentialBag implements Inspect protocol to
   redact values. Telemetry events emit credential names, never values.
3. **Per-invocation isolation.** CredentialBag is scoped to InvocationContext,
   never shared across sessions or users.
4. **Fail closed.** Missing required credential → tool returns error, never
   proceeds without auth.
5. **Minimum privilege.** Request narrowest scopes possible. Document why
   broader scopes are needed.

## References

- [Python ADK Authentication Docs](https://google.github.io/adk-docs/tools-custom/authentication/)
- [Python ADK Auth Discussion #2743](https://github.com/google/adk-python/discussions/2743)
- [agentskills.io specification](https://agentskills.io/specification)
- [SPIFFE specification](https://spiffe.io/docs/latest/spiffe-about/overview/)
- [Biscuit authorization tokens](https://www.biscuitsec.org/)
- [Assent — multi-provider framework](https://github.com/pow-auth/assent)
- [Goth — Google service account auth](https://github.com/peburrows/goth)
- [Boruta — OAuth2/OIDC server](https://github.com/malach-it/boruta_auth)
- [ADK Elixir existing auth modules](https://github.com/zeroasterisk/adk-elixir/tree/main/lib/adk/auth)
