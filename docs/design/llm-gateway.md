# ADK Elixir: LLM Gateway Design

**Status:** Draft  
**Author:** Zaf  
**Date:** 2026-03-23  
**FR from:** Alan Blount

## Problem Statement

An ADK agent ecosystem needs to manage LLM access across:
- **X providers** (Gemini AI Studio, Vertex AI, OpenAI, Anthropic, Ollama, LiteLLM proxies)
- **Y models** (gemini-2.5-pro, claude-opus, gpt-4o, etc.)
- **Z authentication methods** (API keys, service accounts, OAuth2, mTLS, proxy tokens)

This creates X × Y × Z possible configurations. Today's `ADK.LLM.Router` handles
failover across backends but lacks: multi-key rotation, per-key usage tracking,
batch mode, centralized stats, and config validation.

## What We Have Today

| Module | What it does | Gap |
|--------|-------------|-----|
| `ADK.LLM.Router` | Priority-ordered failover across backends | Single key per backend, no rotation |
| `ADK.LLM.CircuitBreaker` | Per-backend failure detection | No per-key granularity |
| `ADK.LLM.Retry` | Exponential backoff with jitter | Not key-aware |
| `ADK.LLM.Gemini` | Gemini API client | Single API key from env |
| `ADK.LLM.OpenAI` | OpenAI-compatible client | Single API key |
| `ADK.LLM.Anthropic` | Claude client | Single API key |
| Telemetry | `:adk.llm.*` events | No aggregated stats dashboard |

**The Router is 80% of the way there.** The gap is in credential management,
multi-key rotation, and observability — not in routing logic.

## Requirements

### R1: Multi-key per provider
```elixir
# Multiple API keys for the same provider + model
%{
  id: :gemini_key_1,
  backend: ADK.LLM.Gemini,
  model: "gemini-2.5-pro",
  auth: %{type: :api_key, value: {:env, "GEMINI_KEY_1"}}
},
%{
  id: :gemini_key_2,
  backend: ADK.LLM.Gemini,
  model: "gemini-2.5-pro",
  auth: %{type: :api_key, value: {:env, "GEMINI_KEY_2"}}
},
%{
  id: :gemini_key_3,
  backend: ADK.LLM.Gemini,
  model: "gemini-2.5-pro",
  auth: %{type: :api_key, value: {:env, "GEMINI_KEY_3"}}
}
```

Round-robin or least-recently-used across keys for the same provider+model.
When one key hits 429, rotate to the next. Track per-key usage (RPM, TPM).

### R2: Multiple auth types per provider
```elixir
# Same model, different auth paths
%{id: :gemini_studio, backend: ADK.LLM.Gemini, model: "gemini-2.5-pro",
  auth: %{type: :api_key, value: {:env, "GEMINI_API_KEY"}}},
%{id: :gemini_vertex, backend: ADK.LLM.Gemini, model: "gemini-2.5-pro",
  auth: %{type: :service_account, path: "path/to/sa.json"}},
%{id: :gemini_vertex_adc, backend: ADK.LLM.Gemini, model: "gemini-2.5-pro",
  auth: %{type: :adc}}  # Application Default Credentials
```

### R3: LiteLLM / proxy support
```elixir
# LiteLLM as an intermediary
%{id: :litellm, backend: ADK.LLM.OpenAI, model: "gemini-2.5-pro",
  auth: %{type: :api_key, value: {:env, "LITELLM_KEY"}},
  base_url: "http://localhost:4000/v1"}
```

Any OpenAI-compatible proxy works here — LiteLLM, vLLM, Ollama, etc.
The `ADK.LLM.OpenAI` backend already supports `base_url` override.

### R4: Batch mode
```elixir
# Vertex AI batch prediction
%{id: :gemini_batch, backend: ADK.LLM.Gemini.Batch, model: "gemini-2.5-pro",
  auth: %{type: :service_account, path: "sa.json"},
  batch: %{max_size: 100, flush_interval_ms: 5_000, output_gcs: "gs://bucket/output"}}
```

Batch mode buffers requests and submits as a batch job. Not suitable for
interactive agents but critical for eval pipelines and bulk processing.

### R5: Centralized stats and reporting
```
[:adk, :llm, :gateway, :request]  — every request with backend_id, model, key_id, latency, tokens
[:adk, :llm, :gateway, :rate_limit] — rate limit events with key_id, retry_after
[:adk, :llm, :gateway, :failover]  — failover events with from_backend, to_backend
[:adk, :llm, :gateway, :error]     — non-transient errors
```

ETS-backed stats aggregation: per-key RPM/TPM, per-backend success rate,
p50/p95 latency, total spend estimation.

### R6: Config validation
```elixir
# At startup, validate all configs
ADK.LLM.Gateway.validate!(config)
# => raises with clear error if:
#    - missing env vars
#    - invalid auth type for backend
#    - duplicate backend ids
#    - unreachable base_url (optional network check)

# Optional: test query against real APIs
ADK.LLM.Gateway.health_check!(config)
# => sends "ping" to each backend, reports latency + auth status
```

### R7: Per-agent / per-skill model assignment
```elixir
# Agent-level model override
agent = ADK.Agent.LlmAgent.new(
  name: "reviewer",
  model: "gemini-2.5-pro",  # resolved through Gateway
  gateway: %{prefer: [:gemini_vertex], fallback: [:gemini_studio, :openai]}
)

# Skill-level model requirements
# SKILL.md frontmatter:
# ---
# model:
#   prefer: gemini-2.5-pro
#   min_context: 128000
#   capabilities: [tool_calling, structured_output]
# ---
```

### R8: Retry strategy configuration
```elixir
%{
  id: :gemini_key_1,
  # ...
  retry: %{
    max_retries: 5,
    base_delay_ms: 1_000,
    max_delay_ms: 60_000,
    strategy: :exponential_with_jitter
  },
  circuit_breaker: %{
    failure_threshold: 3,
    reset_timeout_ms: 30_000
  },
  rate_limit: %{
    rpm: 60,       # self-imposed limit (below provider's actual limit)
    tpm: 1_000_000
  }
}
```

## Proposed Architecture

### Should this be an ADK primitive?

**Yes.** This is the "how agents talk to LLMs" layer — it's as fundamental as
the Runner or Session. Every ADK user needs it. External proxies (LiteLLM) are
complementary, not replacements — the Gateway handles the Elixir-side routing,
key management, and observability regardless of what's on the other end.

### Module structure

```
lib/adk/llm/
  gateway.ex           # Main entry point + config struct
  gateway/
    config.ex          # Config parsing, validation, health check
    key_pool.ex        # Multi-key rotation (round-robin, LRU, weighted)
    stats.ex           # ETS-backed per-key/per-backend stats
    batch.ex           # Batch request buffer + flush
  router.ex            # Existing — enhanced to use Gateway config
  circuit_breaker.ex   # Existing — unchanged
  retry.ex             # Existing — unchanged
```

### `ADK.LLM.Gateway` — the entry point

```elixir
defmodule ADK.LLM.Gateway do
  @moduledoc "Centralized LLM access management."

  defstruct [:backends, :stats, :key_pools]

  @doc "Start the gateway with validated config."
  def start_link(config) do
    # Validate all backend configs
    # Start key pools for multi-key backends
    # Start stats ETS table
    # Start Router GenServer with enhanced config
  end

  @doc "Generate a completion through the gateway."
  def generate(model, request, opts \\ []) do
    # Resolve model → backend(s) via config
    # Pick key from pool
    # Inject auth into request
    # Call through Router (failover, retry, circuit breaker)
    # Record stats
    # Return result
  end

  @doc "Validate config at startup."
  def validate!(config) do
    # Check all required fields
    # Verify env vars exist
    # Check for duplicate ids
    # Validate auth types match backends
  end

  @doc "Health check all backends."
  def health_check!(config) do
    # Send minimal request to each backend
    # Report latency, auth status, model availability
  end

  @doc "Get aggregated stats."
  def stats(gateway) do
    # Per-key: RPM, TPM, error rate, p50/p95 latency
    # Per-backend: success rate, total requests, total tokens
    # Per-model: usage across all backends
  end
end
```

### `ADK.LLM.Gateway.KeyPool` — multi-key rotation

```elixir
defmodule ADK.LLM.Gateway.KeyPool do
  @moduledoc "Manages multiple API keys for a single backend."

  use GenServer

  # State: list of keys with usage counters and rate limit windows
  # Strategies: :round_robin, :least_used, :weighted, :random

  def next_key(pool_id) do
    # Return the next available key
    # Skip rate-limited keys
    # Track usage per key
  end

  def record_usage(pool_id, key_id, tokens) do
    # Update RPM/TPM counters
    # Check against self-imposed limits
  end
end
```

### Auth struct — the common credential resolver

```elixir
defmodule ADK.LLM.Gateway.Auth do
  @moduledoc """
  Common auth struct passed to all backends.
  Resolves credentials from various sources.
  """

  @type t :: %__MODULE__{
    type: :api_key | :service_account | :oauth2 | :adc | :bearer | :mtls | :proxy_token,
    # Resolved value (populated at runtime)
    resolved_token: String.t() | nil,
    # Source configuration
    source: source_config()
  }

  @type source_config ::
    {:env, String.t()} |          # Environment variable
    {:file, Path.t()} |           # Service account JSON file
    {:adc, keyword()} |           # Application Default Credentials
    {:static, String.t()} |       # Hardcoded (testing only)
    {:vault, String.t()} |        # HashiCorp Vault path
    {:secret_manager, String.t()} # GCP Secret Manager

  @doc "Resolve auth to a usable token/header."
  def resolve(%__MODULE__{} = auth) do
    case auth.source do
      {:env, var} -> System.get_env(var) || {:error, "Missing env: #{var}"}
      {:file, path} -> resolve_service_account(path)
      {:adc, opts} -> resolve_adc(opts)
      {:vault, path} -> resolve_vault(path)
      {:secret_manager, name} -> resolve_secret_manager(name)
      {:static, value} -> value
    end
  end
end
```

## Unresolved Design Questions

### UQ1: Gateway as GenServer vs module?

Option A: `Gateway` is a GenServer that owns KeyPool + Stats processes.
- Pro: Clean lifecycle, supervised, can be stopped/restarted.
- Con: Another process in the tree, message passing overhead.

Option B: `Gateway` is a stateless module; KeyPool and Stats are separate GenServers.
- Pro: Simpler, less coupling.
- Con: No single "stop the gateway" handle.

**Leaning:** Option A — Gateway as supervisor of its children.

### UQ2: Config format — runtime vs compile-time?

Should backend configs be:
- Application env (`config :adk, :llm_gateway, [...]`) — compile-time
- Runtime config passed to `Gateway.start_link/1` — runtime
- Both (compile-time defaults, runtime overrides)

**Leaning:** Both. Compile-time for defaults, runtime for dynamic addition.

### UQ3: Batch mode scope

Batch mode is fundamentally different from interactive mode:
- No streaming
- Async (submit job, poll for results)
- GCS input/output
- Different pricing

Should batch be a separate backend or a mode flag on existing backends?

**Leaning:** Separate backend (`ADK.LLM.Gemini.Batch`) with its own auth + config.

### UQ4: LiteLLM integration depth

Options:
- A: Treat LiteLLM as just another OpenAI-compatible endpoint (minimal)
- B: Build a dedicated `ADK.LLM.LiteLLM` backend that speaks its admin API (virtual keys, budget tracking)
- C: Build our own LiteLLM-equivalent in Elixir (the Gateway IS the LiteLLM)

**Leaning:** Start with A, evolve toward C. The Gateway already does most of what LiteLLM does — key rotation, failover, stats. The missing piece is the proxy HTTP server for non-Elixir clients, which is a Phoenix endpoint.

### UQ5: Per-key vs per-backend rate limits

Provider rate limits apply per-key (API key) not per-backend-config. If you have
3 keys for the same project, each has its own RPM/TPM quota. But if 3 keys are
on the same GCP project, they share a project-level quota.

How deep do we model this? Options:
- A: Per-key tracking only (simple, usually sufficient)
- B: Per-key + per-project grouping (for GCP quota sharing)
- C: Let the user declare quota groups

**Leaning:** A for now, with hooks for B later.

### UQ6: Dynamic backend addition

Can backends be added/removed at runtime? Use case: agent discovers a new MCP
server that provides LLM access, wants to add it to the pool.

**Leaning:** Yes, via `Gateway.add_backend/2` and `Gateway.remove_backend/2`.

### UQ7: Spend tracking and budgets

LiteLLM's killer feature is spend tracking with budgets per team/key. Should
the Gateway track estimated spend?

**Leaning:** Yes, using published pricing tables. But this is P2 — stats first.

## Relationship to Skill Auth

The [Skill Auth Design](./skill-auth.md) covers how *user* credentials flow to
tools. The Gateway covers how the *agent platform* authenticates to LLM providers.

These are orthogonal but share the `Auth` resolver pattern:
- Skill auth: "This user's GitHub token needs to reach this shell script"
- Gateway auth: "This API key needs to reach this Gemini endpoint"

Both should use the same `source_config` type for credential resolution
(env vars, files, vaults, secret managers).

## Migration Path

1. **Phase 1:** Add `Gateway.Auth` struct + `KeyPool` to Router config. Multi-key rotation.
2. **Phase 2:** Add `Gateway.Stats` for per-key/per-backend telemetry. Config validation.
3. **Phase 3:** Add health check, batch mode, spend tracking.
4. **Phase 4:** Phoenix-based proxy endpoint (LiteLLM-equivalent for non-Elixir clients).

## Elixir Ecosystem

| Library | What it does | Relevant? |
|---------|-------------|-----------|
| `assent` | Multi-provider OAuth2/OIDC strategies | Yes — for user-facing OAuth |
| `ueberauth` | Plug-based auth strategies | Yes — for Phoenix web auth |
| `boruta` | Full OAuth2/OIDC server | Maybe — if we need to issue tokens |
| `joken` | JWT encoding/decoding | Yes — for JWT-based auth |
| `tesla` | HTTP client with middleware | Already used by LLM backends |
| `finch` | HTTP client (connection pools) | Used by tesla |
| `biscuit-elixir` | Doesn't exist yet | Would need NIF or port |
| SPIFFE/SPIRE | No Elixir client | Would need gRPC client to workload API |

**Notable gap:** No Elixir Biscuit implementation exists. If we need attenuated
delegation tokens, we'd either build a NIF wrapper or use JWT with custom claims
as an approximation.

## Open Questions for Alan

1. **Priority:** Is this P0 (block ExClaw) or P1 (nice to have for v1)?
2. **LiteLLM proxy:** Do you want the Gateway to expose an HTTP proxy endpoint?
3. **Batch mode:** Is Vertex AI batch a near-term need or future?
4. **Spend tracking:** Important for v1 or can it wait?
5. **SPIFFE/Biscuit:** Real near-term need or aspirational?
