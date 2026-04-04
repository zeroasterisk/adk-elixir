# LLM Backends

Reference for the four LLM backends in ADK Elixir: **Gemini**, **Anthropic**, **OpenAI**, and **Gemma**.

## Architecture

```
ADK.LLM.generate/3  (behaviour + telemetry + retry + circuit breaker)
    │
    ├─ ADK.LLM.Retry          — exponential backoff with jitter
    ├─ ADK.LLM.CircuitBreaker  — failure threshold + half-open recovery
    ├─ ADK.LLM.Router          — multi-backend priority failover
    └─ ADK.LLM.Gateway         — multi-key pooling + stats (ADK extension)

Backends (all implement ADK.LLM behaviour):
    ├─ ADK.LLM.Gemini      — Google Gemini REST API
    ├─ ADK.LLM.Anthropic   — Anthropic Messages API
    ├─ ADK.LLM.OpenAI      — OpenAI Chat Completions (+ compatible providers)
    ├─ ADK.LLM.Gemma       — Gemma via Gemini API (text-based tool calling)
    └─ ADK.LLM.Mock         — Echoes input / configurable responses (testing)
```

## Authentication

### Gemini

| Source | Priority | Mechanism |
|--------|----------|-----------|
| `config :adk, :gemini_api_key` | 1 | `?key=` query param |
| `GEMINI_API_KEY` env var | 2 | `?key=` query param |
| `config :adk, :gemini_bearer_token` | 3 | `Authorization: Bearer` header |
| `GEMINI_BEARER_TOKEN` env var | 4 | `Authorization: Bearer` header |

Returns `{:error, :missing_api_key}` if none found.

### Anthropic

Supports two auth modes, checked in order:

| Source | Priority | Mode | Header |
|--------|----------|------|--------|
| `config :adk, :anthropic_oauth_token` | 1 | OAuth | `Authorization: Bearer` |
| `ANTHROPIC_OAUTH_TOKEN` env var | 2 | OAuth | `Authorization: Bearer` |
| `CLAUDE_AI_SESSION_KEY` env var (requires `anthropic_auto_discover: true`) | 3 | OAuth | `Authorization: Bearer` |
| `config :adk, :anthropic_api_key` | 4 | API Key | `x-api-key` |
| `ANTHROPIC_API_KEY` env var | 5 | API Key | `x-api-key` |

**OAuth headers include:** `anthropic-version: 2023-06-01`, `anthropic-beta: claude-code-20250219,oauth-2025-04-20`, `user-agent: claude-cli/2.1.2`, `x-app: cli`.

**API key headers include:** `x-api-key`, `anthropic-version: 2023-06-01`.

> ⚠️ OAuth mode requires the system instruction to start with "You are Claude Code, Anthropic's official CLI for Claude." — this is an API requirement.

### OpenAI

| Source | Priority | Header |
|--------|----------|--------|
| `config :adk, :openai_api_key` | 1 | `Authorization: Bearer` |
| `OPENAI_API_KEY` env var | 2 | `Authorization: Bearer` |

Base URL override: `config :adk, :openai_base_url` or `OPENAI_BASE_URL` env var. Defaults to `https://api.openai.com/v1`. Set to `http://localhost:11434/v1` for Ollama, etc.

### Gemma

No separate auth — delegates to the Gemini backend.

## Request Format

All backends accept the same canonical request map via `ADK.LLM`:

```elixir
%{
  instruction: "System prompt string",          # optional
  messages: [                                   # required
    %{role: :user, parts: [%{text: "Hello"}]},
    %{role: :model, parts: [%{text: "Hi!"}]},
    %{role: :model, parts: [%{function_call: %{name: "search", args: %{q: "cats"}, id: "call_1"}}]},
    %{role: :user, parts: [%{function_response: %{name: "search", response: %{result: "..."}}}]}
  ],
  tools: [                                      # optional
    %{name: "search", description: "Search the web", parameters: %{type: "object", ...}}
  ],
  generate_config: %{                           # optional
    temperature: 0.7,
    top_p: 0.9,
    top_k: 40,
    max_output_tokens: 4096,
    stop_sequences: ["END"],
    candidate_count: 1,
    response_mime_type: "application/json",
    response_schema: %{...},
    thinking_config: %{...},                    # Gemini only
    safety_settings: [...]                      # Gemini only
  },
  tool_choice: :auto,                           # Anthropic only (:auto | :any | :none | {:tool, name})
  tool_config: %{...},                          # Gemini only (overrides default AUTO mode)
  metadata: %{user_id: "..."},                  # Anthropic only
  max_tokens: 4096,                             # Anthropic only (default: 4096)
  base_url: "...",                              # Override per-request
  custom_headers: [{"x-custom", "val"}]         # Gemini/OpenAI only
}
```

### How Each Backend Transforms the Request

#### Gemini

- `instruction` → `system_instruction.parts[0].text`
- `messages` → `contents[]` with string roles (`"user"`, `"model"`)
- `tools` → `tools[].function_declarations[]` + builtins (`google_search`, `code_execution`)
- `toolConfig` → defaults to `%{functionCallingConfig: %{mode: "AUTO"}}` when tools present (prevents Gemini 2.5+ from hallucinating tool calls in text)
- `generate_config` → `generationConfig` with camelCase keys (`maxOutputTokens`, `topP`, `topK`, `thinkingConfig`, etc.)
- `generate_config.safety_settings` → top-level `safetySettings`
- `thoughtSignature` on function_call/text parts is preserved round-trip (required for Gemini 2.5+/3 multi-turn tool calling)

#### Anthropic

- `instruction` → top-level `system` param (NOT in messages)
- `messages` → flattened with role mapping (`:model` → `"assistant"`, `:user` → `"user"`)
- Function calls → `tool_use` blocks with `id`, `name`, `input`
- Function responses → `tool_result` blocks with `tool_use_id`, `content`
  - `tool_use_id` resolution: part `:id` → response `:tool_call_id` → generated ID
  - Supports `is_error: true` propagation
- `tools` → `tools[]` with `input_schema` (defaults to `%{type: "object"}` when nil)
- `tool_choice` → `%{type: "auto"|"any"|"none"}` or `%{type: "tool", name: "..."}` 
- `generate_config.max_output_tokens` overrides the `max_tokens` body param
- Inline images (`:inline_data`) → base64 `image` blocks (user turns only)
- PDFs → base64 `document` blocks (user turns only)
- Media in assistant turns is logged as warning and dropped

#### OpenAI

- `instruction` → `system` role message prepended
- `messages` → standard OpenAI format with `role: "user"|"assistant"|"system"|"tool"`
- Function calls → `tool_calls[]` with `function.name` + JSON-encoded `function.arguments`
- Function responses → `role: "tool"` with `tool_call_id` + JSON content
- `tools` → `tools[]` with `type: "function"` wrapper
- `generate_config.response_mime_type: "application/json"` → `response_format: %{type: "json_object"}` or `json_schema`

#### Gemma

Preprocesses then delegates to `ADK.LLM.Gemini`:

1. **Function turns → text:** All `function_call` and `function_response` parts are serialized to plain text
2. **Tools → text instruction:** Tool declarations are converted to a text block prepended to the system instruction
3. **System instruction → user message:** Gemma has no native system instructions — moved to first user message
4. **Response post-processing:** Scans model text output for JSON matching function call patterns, converts back to structured `function_call` parts

Only supports `gemma-3-*` models (raises `ArgumentError` otherwise).

## Response Format

All backends normalize to the same structure:

```elixir
%{
  content: %{
    role: :model,
    parts: [
      %{text: "Hello!"},
      # or
      %{function_call: %{name: "search", args: %{q: "cats"}, id: "call_1"}},
      # Gemini thinking:
      %{text: "thinking...", thought: true, thought_signature: "base64..."},
      # Anthropic thinking:
      %{thinking: "internal reasoning..."},
      # Gemini code execution:
      %{executable_code: %{language: "python", code: "print(1)"}},
      %{code_execution_result: %{outcome: "OUTCOME_OK", output: "1"}}
    ]
  },
  usage_metadata: %{...},    # provider-specific usage data
  # Gemini extras:
  finish_reason: "STOP",     # Gemini finishReason string
  prompt_feedback: %{...},   # Gemini promptFeedback (if present)
  model_version: "...",      # Gemini modelVersion (if present)
  # Anthropic extras:
  stop_reason: :end_turn,    # :end_turn | :max_tokens | :stop_sequence | :tool_use
  model: "claude-...",       # Anthropic model string
  id: "msg_..."              # Anthropic message ID
}
```

## Error Handling

### Error Types (all backends)

| Error | Meaning |
|-------|---------|
| `{:error, :missing_api_key}` | No credentials configured |
| `{:error, :unauthorized}` | 401 — invalid/expired credentials |
| `{:error, {:api_error, status, body}}` | Non-retryable API error (400, 403, 404, etc.) |
| `{:error, {:request_failed, reason}}` | Connection-level failure |
| `{:error, :rate_limited}` | 429 (OpenAI only — Gemini/Anthropic use `retry_after` tuple) |
| `{:error, :circuit_open}` | Circuit breaker is open |
| `{:error, :all_backends_failed}` | Router exhausted all backends |

### Retry-After Signaling (Gemini & Anthropic)

Gemini and Anthropic return a special 3-tuple on rate limits:

```elixir
{:retry_after, milliseconds_or_nil, :rate_limited}   # 429
{:retry_after, milliseconds_or_nil, :overloaded}      # 529 (Anthropic only)
```

`ADK.LLM.Retry` intercepts these and extracts the delay from:
1. `retry-after-ms` header (Anthropic-specific, milliseconds)
2. `retry-after` header (standard, seconds → converted to ms)

## Retry Logic

`ADK.LLM.Retry.with_retry/2` wraps backend calls (applied by `ADK.LLM.generate/3` — **not** by individual backends, to avoid double-wrapping).

| Option | Default | Description |
|--------|---------|-------------|
| `max_retries` | 3 | Maximum retry attempts |
| `base_delay_ms` | 1,000 | Base delay for exponential backoff |
| `max_delay_ms` | 30,000 | Maximum delay cap |
| `retry_after_ms` | nil | Override backoff for first retry (from server header) |
| `sleep_fn` | `Process.sleep/1` | Override for testing |

**Backoff formula:** `delay = random(0, min(base * 2^attempt, max))` (full jitter).

**Transient errors (retried):**
- `:rate_limited`, `:overloaded`
- `{:api_error, status, _}` where status ∈ {500, 502, 503, 504, 529}
- `{:request_failed, _}` (connection errors)
- `:timeout`, `:econnrefused`, `:closed`

**Non-transient errors (NOT retried):**
- `:unauthorized` (401)
- `{:api_error, 400|403|404, _}` (client errors)
- `:missing_api_key`

> ⚠️ Individual backends do NOT apply retry internally. The comment in each backend's `do_generate` explains why — double-wrapping caused worst-case stalls of ~5 minutes.

## Circuit Breaker

`ADK.LLM.CircuitBreaker` — GenServer-based, three states:

| State | Behavior |
|-------|----------|
| **Closed** | Normal operation. Tracks consecutive failures. |
| **Open** | All calls rejected with `{:error, :circuit_open}`. Transitions to half-open after `reset_timeout_ms`. |
| **Half-open** | Allows one probe call. Success → closed. Failure → open again. |

**Defaults:** `failure_threshold: 5`, `reset_timeout_ms: 60_000` (1 min).

Enable per-call: `ADK.LLM.generate(model, req, circuit_breaker: :my_breaker)`

## Router

`ADK.LLM.Router` — tries backends in priority order:

```elixir
config :adk, :llm_router, [
  backends: [
    %{id: :gemini, backend: ADK.LLM.Gemini, model: "gemini-2.0-flash", priority: 1},
    %{id: :anthropic, backend: ADK.LLM.Anthropic, model: "claude-sonnet-4-20250514", priority: 2},
    %{id: :openai, backend: ADK.LLM.OpenAI, model: "gpt-4o", priority: 3}
  ]
]
```

- **Rate limit:** Backend backed off with exponential delay, try next
- **Circuit breaker:** Consulted per-backend if registered (`ADK.LLM.Router.CircuitBreaker.<id>`)
- **Other errors:** 10s cool-down penalty, try next
- **All exhausted:** `{:error, :all_backends_failed}`

## Gateway (ADK Extension)

`ADK.LLM.Gateway` — no Python ADK equivalent. Adds:

- **Key pooling:** Multiple API keys per backend with round-robin or other strategies (`ADK.LLM.Gateway.KeyPool`)
- **Stats collection:** Per-backend request/latency/error tracking (`ADK.LLM.Gateway.Stats`)
- **Budget enforcement:** Rate limiting per key/backend (`ADK.LLM.Gateway.Budget`)
- **Auth injection:** Keys from pool injected into requests before routing
- **Config validation:** `ADK.LLM.Gateway.Config.validate!/1` at startup

Runs as a Supervisor with one KeyPool child per backend + Stats GenServer.

## Known Issues

| Issue | Backend | Detail |
|-------|---------|--------|
| `toolConfig` required | Gemini 2.5+ | Without `toolConfig: %{functionCallingConfig: %{mode: "AUTO"}}`, models hallucinate tool calls in text (`<tool_code>` blocks) instead of structured `functionCall` parts. We set this automatically when tools are present. |
| `thoughtSignature` round-trip | Gemini 2.5+/3 | Function call and text parts may include `thoughtSignature` — must be preserved and sent back in subsequent turns for multi-turn tool calling to work. |
| OAuth system prompt | Anthropic | OAuth auth requires system instruction to start with a specific string ("You are Claude Code..."). Caller responsibility. |
| Media in assistant turns | Anthropic | Images/PDFs in assistant turns are silently dropped with a warning log. Only supported in user turns. |
| No streaming | All | None of the backends implement streaming — all use synchronous `Req.post`. |
| `529 Overloaded` | Anthropic | Anthropic-specific status code. Treated as transient + retryable. |
| Double-retry risk | All | Each backend has a comment explaining NOT to add retry — `ADK.LLM.generate/3` already applies it. |
| Gemma function calling | Gemma | Text-based, not native. Relies on regex/JSON parsing of model output — can be fragile with complex tool schemas. |
| OpenAI rate limit | OpenAI | Returns plain `{:error, :rate_limited}` (no `retry_after` extraction), unlike Gemini/Anthropic which signal delay. |

## Testing

Each backend supports a Req test plug for unit testing without real API calls:

```elixir
# In config/test.exs
config :adk, :gemini_test_plug, true
config :adk, :anthropic_test_plug, true
config :adk, :openai_test_plug, true

# In tests
Req.Test.stub(ADK.LLM.Gemini, fn conn ->
  Req.Test.json(conn, %{"candidates" => [%{"content" => %{"role" => "model", "parts" => [%{"text" => "Hi"}]}}]})
end)
```

`ADK.LLM.Mock` is also available for process-level mock responses:

```elixir
config :adk, :llm_backend, ADK.LLM.Mock
ADK.LLM.Mock.set_responses(["response 1", "response 2"])
```

## Timeouts

All backends use the same Req timeouts:

| Timeout | Value | Description |
|---------|-------|-------------|
| `receive_timeout` | 30,000ms | Max wait for response body |
| `connect_options.timeout` | 10,000ms | TCP connection timeout |

These are hardcoded in each backend's `do_generate`. Not yet configurable per-request (potential improvement).
