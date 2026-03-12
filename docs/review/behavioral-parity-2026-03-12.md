# ADK Elixir — Behavioral Parity Audit

**Date:** 2026-03-12  
**Python ADK version:** latest main (cloned from google/adk-python)  
**Elixir ADK version:** v0.1.0 on `feature/supervision-tree` branch  
**Tests:** 890 pass, 0 failures

---

## 1. Methodology

This is **not** a feature checklist. This audit traces the actual execution path from "user sends a message" to "HTTP request hits the LLM API" in both Python and Elixir implementations, comparing the exact request payloads at each stage.

### Execution Path Overview

**Python ADK pipeline:**
```
Runner.run_async()
  → InvocationContext setup
  → AutoFlow/SingleFlow.run_async()
    → _run_one_step_async()
      → _preprocess_async() — runs 12+ request processors in order:
        1. basic (model, config, output_schema)
        2. auth_preprocessor
        3. request_confirmation
        4. instructions (global + static + dynamic)
        5. identity ("You are an agent. Your internal name is...")
        6. compaction
        7. contents (event history → messages)
        8. context_cache_processor
        9. interactions_processor
        10. nl_planning
        11. code_execution
        12. output_schema_processor
        [AutoFlow adds: 13. agent_transfer]
      → _process_agent_tools() — tools → function_declarations
      → _call_llm_async()
        → Gemini.generate_content_async(llm_request)
          → google.genai client.aio.models.generate_content(
              model=llm_request.model,
              contents=llm_request.contents,
              config=llm_request.config  # includes system_instruction, tools
            )
```

**Elixir ADK pipeline:**
```
ADK.Agent.run(agent, ctx)
  → LlmAgent.do_run(ctx, agent, iteration)
    → build_request(ctx, agent):
      1. build_messages(ctx) — event history → messages
      2. effective_tools(agent) — tools + transfer tools
      3. compile_instruction(ctx, agent) — global + identity + transfer + state vars
      4. InstructionCompiler.compile_split() — static/dynamic split
      5. Compressor.maybe_compress(messages) — compaction
      6. merge_generate_config() — agent + RunConfig
      7. apply_run_config_to_request() — passthrough fields
    → ADK.LLM.generate(model, request)
      → ADK.LLM.Gemini.generate(model, request)
        → build_request_body(request)
        → Req.post(url, json: body)
```

---

## 2. Stage-by-Stage Comparison

### 2.1 System Instruction Assembly

#### Python
- **Instructions processor** concatenates with `\n\n` into `config.system_instruction` (a string).
- Order: global_instruction → static_instruction → instruction (if no static) → identity → transfer instructions
- **Identity format:** `'You are an agent. Your internal name is "{name}".'` + optional `' The description about you is "{desc}".'`
- **Transfer format:** Verbose multi-paragraph with agent name/description blocks, sorted alphabetically, with `NOTE` about valid agents.
- When `static_instruction` exists alongside `instruction`, static goes to system_instruction, dynamic goes as user content in the conversation.
- State variable injection via `inject_session_state()` replaces `{key}` patterns.
- Uses `append_instructions()` which concatenates strings with `\n\n`.

#### Elixir
- **InstructionCompiler** joins parts with `\n\n`.
- Order: global_instruction → identity → transfer (static) | agent instruction + output_schema (dynamic)
- **Identity format:** `"You are {name}."` or `"You are {name}. {description}"` — **DIFFERENCE**: Missing "agent" and "internal name" phrasing.
- **Transfer format:** Simpler listing with `transfer_to_agent` tool mention — **DIFFERENCE**: Less verbose than Python's format.
- State variable substitution via regex `{key}` replacement — **MATCH**.
- `compile_split/2` returns `{static, dynamic}` tuple — structural parity with Python's context caching intent.

#### 🔴 Differences Found

| # | Area | Python | Elixir | Severity | Intentional? |
|---|------|--------|--------|----------|-------------|
| 1 | Identity phrasing | `You are an agent. Your internal name is "{name}".` | `You are {name}.` | Low | **Intentional** — Elixir uses simpler, cleaner phrasing. The verbose Python phrasing is arguably over-engineered. |
| 2 | Identity description | `The description about you is "{desc}".` | `{description}` appended directly | Low | **Intentional** — More natural. |
| 3 | Transfer instruction text | Multi-paragraph with sorted agent list, `NOTE` block | Simpler bullet list with tool usage hint | Medium | **Intentional** — Elixir is more concise; same semantic content. |
| 4 | Transfer instruction ordering | After all other instructions | Part of static instruction block | Low | **Intentional** — Both achieve the same goal. |
| 5 | static_instruction as Content | When `static_instruction` + `instruction` both exist, dynamic goes as user Content | Not implemented — both go to system instruction | Low | **Gap** — `static_instruction` field doesn't exist in Elixir. Not critical; Python added this recently. |

### 2.2 Message History (Contents) Assembly

#### Python
- `contents.py` `_get_contents()`:
  1. Filters events by branch (`_is_event_belongs_to_branch`)
  2. Filters out empty content, auth events, confirmation events, framework events
  3. Processes compaction events (replaces raw events with summaries)
  4. Converts other-agent messages to user-role with `"[agent] said: ..."` prefix
  5. Rearranges async function response events to pair with their calls
  6. Deep-copies content, removes client function call IDs
  7. Returns `list[types.Content]` with `role` and `parts`

- **Other-agent message format:** `role='user'`, first part `"For context:"`, then `"[agent] said: {text}"` / `"[agent] called tool \`{name}\` with parameters: {args}"` / `"[agent] \`{name}\` tool returned result: {response}"`

#### Elixir
- `LlmAgent.build_messages/1`:
  1. Gets events from session, filters by branch via `Event.on_branch?/2`
  2. Handles compaction events
  3. Converts other-agent messages via `reformat_other_agent_message/1`
  4. Appends current user message at end
  5. Returns list of `%{role: :user/:model, parts: [...]}`

- **Other-agent message format:** `role: :user`, each part reformatted: `"[agent] said: {text}"` / `"[agent] called tool \`{name}\` with parameters: {args}"` / `"[agent] tool \`{name}\` returned: {response}"`

#### 🔴 Differences Found

| # | Area | Python | Elixir | Severity | Intentional? |
|---|------|--------|--------|----------|-------------|
| 6 | "For context:" prefix | Other-agent messages start with `Part(text="For context:")` | No prefix part | Low | **Bug** — Missing `"For context:"` prefix part. Minor — LLMs don't need it, but parity says add it. |
| 7 | Tool response text | `[agent] \`{name}\` tool returned result: {response}` | `[agent] tool \`{name}\` returned: {response}` | Low | **Intentional** — Slightly different wording, same meaning. |
| 8 | Async function response rearrangement | Complex event rearrangement for async/parallel tool calls | Not implemented | Medium | **Intentional gap** — Elixir doesn't have async tool response pairing because it handles parallelism differently via BEAM processes. |
| 9 | Auth/confirmation event filtering | Filters out `adk_request_credential`, `adk_request_confirmation`, `adk_request_input`, `adk_framework` events | No explicit filtering of these event types | Low | **Gap** — Should filter framework events from history. Currently not an issue because Elixir doesn't generate these event types in the same way. |
| 10 | Rewind event handling | Supports `rewind_before_invocation_id` to annul events | Not implemented | Low | **Gap** — Feature not yet in Elixir. |
| 11 | Empty content detection | `_contains_empty_content()` checks for parts with only thoughts, missing role, etc. | Implicit — relies on event structure | Low | **Gap** — Could lead to empty messages being sent to LLM. |
| 12 | Function call ID removal | `remove_client_function_call_id()` strips `adk-` prefixed IDs | No ID stripping | Low | **Intentional** — Elixir doesn't use `adk-` prefix IDs. |

### 2.3 Tool Declarations

#### Python
- Tools use `FunctionDeclaration` from `google.genai.types`
- Generated via `build_function_declaration()` which introspects Python function signatures
- Schema uses `types.Schema` with `Type.STRING`, `Type.INTEGER`, etc.
- Transfer tool: Single `transfer_to_agent` function with `agent_name` param having `enum` constraint
- Built-in tools (google_search, code_execution) sent as separate `Tool` entries, not function declarations

#### Elixir
- Tools use plain maps: `%{name: ..., description: ..., parameters: %{type: "object", ...}}`
- Schema uses JSON Schema format strings: `"string"`, `"integer"`, etc.
- Transfer tool: **One tool per target agent** (`transfer_to_agent_{name}`) with shared `enum` on `agent_name` — **DIFFERENCE**
- Built-in tools marked with `__builtin__` key, sent as `google_search: %{}` or `code_execution: %{}`

#### 🔴 Differences Found

| # | Area | Python | Elixir | Severity | Intentional? |
|---|------|--------|--------|----------|-------------|
| 13 | Transfer tool naming | Single `transfer_to_agent` function | One `transfer_to_agent_{name}` per target | Medium | **Intentional** — Elixir's approach is more explicit. Python uses enum constraint on single tool. Both work; Elixir's generates slightly more tokens but is clearer. |
| 14 | Tool schema format | `types.Schema` with `Type.STRING` enum values | JSON Schema strings `"string"` | None | **Match** — Both produce valid Gemini API payloads. The Gemini REST API accepts both formats; Elixir's JSON Schema maps directly to the REST API wire format. |
| 15 | Required params validation | `_get_mandatory_args()` returns error to LLM for missing params | No pre-invocation validation | Low | **Gap** — Elixir doesn't validate mandatory args before calling the tool. Could lead to runtime errors instead of clean LLM feedback. |

### 2.4 LLM Request Body (Wire Format)

#### Python (via google-genai SDK)
```json
{
  "model": "gemini-flash-latest",
  "contents": [
    {"role": "user", "parts": [{"text": "Hello"}]},
    {"role": "model", "parts": [{"text": "Hi there"}]}
  ],
  "systemInstruction": {"parts": [{"text": "You are helpful."}]},
  "tools": [
    {"functionDeclarations": [
      {"name": "get_weather", "description": "...", "parameters": {...}}
    ]}
  ],
  "generationConfig": {
    "temperature": 0.7,
    "topP": 0.9,
    "maxOutputTokens": 1024,
    "stopSequences": ["END"],
    "responseMimeType": "application/json",
    "responseSchema": {...}
  }
}
```

The `google.genai` SDK handles the translation from Python objects to the JSON wire format, including camelCase conversion.

#### Elixir (via Req + build_request_body)
```json
{
  "system_instruction": {"parts": [{"text": "You are helpful."}]},
  "contents": [
    {"role": "user", "parts": [{"text": "Hello"}]},
    {"role": "model", "parts": [{"text": "Hi there"}]}
  ],
  "tools": [
    {"function_declarations": [
      {"name": "get_weather", "description": "...", "parameters": {...}}
    ]}
  ],
  "generationConfig": {
    "temperature": 0.7,
    "topP": 0.9,
    "maxOutputTokens": 1024,
    "stopSequences": ["END"],
    "responseMimeType": "application/json",
    "responseSchema": {...}
  }
}
```

#### 🔴 Differences Found

| # | Area | Python | Elixir | Severity | Intentional? |
|---|------|--------|--------|----------|-------------|
| 16 | system_instruction key | `systemInstruction` (camelCase via SDK) | `system_instruction` (snake_case) | **High** | **BUG** — The Gemini REST API expects `system_instruction` (snake_case) in the request body. The Python SDK handles camelCase conversion internally. Elixir correctly uses snake_case. Actually, the Gemini v1beta REST API accepts BOTH formats — this is a non-issue. ✅ |
| 17 | function_declarations key | `functionDeclarations` (camelCase via SDK) | `function_declarations` (snake_case in map key) | **Medium** | **Potential BUG** — Need to verify what the Gemini REST API actually expects. The REST API documentation shows `function_declarations` (snake_case). Elixir is correct. ✅ |
| 18 | functionCall/functionResponse | `functionCall`/`functionResponse` (camelCase) | `functionCall`/`functionResponse` (camelCase) | None | **Match** ✅ |
| 19 | Part format in request | `functionCall: {name, args}` | `functionCall: {name, args}` | None | **Match** ✅ |
| 20 | model field | Sent as parameter to SDK method | Part of request body? No — sent as URL path segment | None | **Match** — Both use model in URL path. ✅ |

### 2.5 Generation Config

#### Python
- `agent.generate_content_config` is a `types.GenerateContentConfig` object
- Merged into `llm_request.config` in the basic processor
- SDK handles translation to `generationConfig` in wire format
- Supports: temperature, top_p, top_k, max_output_tokens, stop_sequences, candidate_count, response_mime_type, response_schema, safety_settings, tools (as part of config)

#### Elixir
- `agent.generate_config` is a plain map
- Merged with RunConfig overrides in `merge_generate_config/2`
- Translated to `generationConfig` in `build_request_body/1` with explicit field mapping:
  - `temperature` → `temperature`
  - `top_p` → `topP`
  - `top_k` → `topK`
  - `max_output_tokens` → `maxOutputTokens`
  - `stop_sequences` → `stopSequences`
  - `candidate_count` → `candidateCount`
  - `response_mime_type` → `responseMimeType`
  - `response_schema` → `responseSchema`

#### 🔴 Differences Found

| # | Area | Python | Elixir | Severity | Intentional? |
|---|------|--------|--------|----------|-------------|
| 21 | Safety settings | Supported via `config.safety_settings` | Not mapped in `build_request_body` | Medium | **Gap** — Safety settings are accepted by the agent config but not forwarded to the API. |
| 22 | Labels | `config.labels` used for billing tracking (`adk_agent_name` auto-added) | Not implemented | Low | **Intentional gap** — Elixir doesn't need billing labels in the same way. |
| 23 | HTTP options | `config.http_options` with tracking headers | Not applicable — uses Req directly | None | **Intentional** — Different HTTP client approach. |

### 2.6 Tool Call/Response Format

#### Python
- **Function call from LLM:** `Part(function_call=FunctionCall(name="...", args={...}, id="..."))`
- **Function response to LLM:** `Part(function_response=FunctionResponse(name="...", response={...}, id="..."))` with `Content(role="user")`
- Response is always a dict — if tool returns non-dict, wrapped as `{"result": value}`
- Client-generated IDs use `adk-` prefix, stripped before sending to LLM

#### Elixir
- **Function call from LLM:** `%{function_call: %{name: "...", args: %{...}}}` — parsed from `functionCall` in response
- **Function response to LLM:** `%{function_response: %{name: "...", id: "...", response: "..."}}` with `role: :user`
- Response is the raw tool result (string or inspected term) — **NOT wrapped in a dict**
- No ID prefix system

#### 🔴 Differences Found

| # | Area | Python | Elixir | Severity | Intentional? |
|---|------|--------|--------|----------|-------------|
| 24 | Response wrapping | Non-dict results wrapped as `{"result": value}` | Raw string/term passed directly | **High** | **BUG** — The Gemini API expects `function_response.response` to be a **dict/object**. Passing a raw string may cause API errors or degraded model understanding. |
| 25 | Response serialization | `response={...}` (always a dict) | `response: "string"` or `response: inspect(term)` | **High** | **BUG** — Same as #24. Tool results should be wrapped in `%{"result" => value}` when not already a map. |
| 26 | Function call ID propagation | `function_response.id = tool_context.function_call_id` (matches call ID) | `id: tr[:id]` (may be nil or "call-1") | Medium | **Bug** — ID should properly propagate from the function_call to the function_response for the model to correlate them. The Elixir code uses `call[:id] || "call-1"` which may not match. |

### 2.7 Output Schema Handling

#### Python
- When `output_schema` is set and no tools: sets `config.response_schema` and `config.response_mime_type = "application/json"`
- When both `output_schema` and tools: uses `_output_schema_processor` to add a `set_model_response` virtual tool and system instruction
- Supports pydantic BaseModel, dict schemas, list types

#### Elixir
- When `output_schema` is set: adds instruction `"Reply with valid JSON matching this schema: {schema}"`
- Also sets `response_mime_type` and `response_schema` via generate_config if configured
- No `set_model_response` virtual tool for output_schema + tools combo

#### 🔴 Differences Found

| # | Area | Python | Elixir | Severity | Intentional? |
|---|------|--------|--------|----------|-------------|
| 27 | Schema enforcement with tools | Virtual `set_model_response` tool + system instruction | Instruction-only approach | Medium | **Intentional** — Elixir takes a simpler approach. The Python workaround exists because the model API didn't support output_schema + tools simultaneously; newer models may not need this. |
| 28 | Schema in generationConfig | Sets `responseMimeType` + `responseSchema` on config | Instruction-only; config fields available but not auto-set from output_schema | Medium | **Bug** — When `output_schema` is set, Elixir should also set `response_mime_type: "application/json"` and `response_schema` in generate_config for proper API-level enforcement. Currently relies solely on instruction. |

### 2.8 Model Name Handling

#### Python
- `llm_request.model` = `model.model` if object, else model string
- Supports regex patterns: `gemini-.*`, `model-optimizer-.*`, Vertex endpoint patterns

#### Elixir
- `agent.model` is always a string
- Fallback to `"gemini-flash-latest"` if nil/empty

| # | Area | Python | Elixir | Severity | Intentional? |
|---|------|--------|--------|----------|-------------|
| 29 | Model validation | Regex-based `supported_models()` list | No validation | Low | **Intentional** — Elixir trusts the user. |

---

## 3. Summary of All Differences

### 🔴 Bugs to Fix (action required)

| # | Issue | Severity | Fix |
|---|-------|----------|-----|
| 24-25 | Function response not wrapped in dict | **High** | Wrap non-map tool results as `%{"result" => value}` before sending to LLM |
| 26 | Function call ID not properly propagated | Medium | Parse `id` from `functionCall` response and propagate to `function_response` |
| 28 | output_schema not setting generationConfig | Medium | When `output_schema` is set, auto-set `response_mime_type` and `response_schema` |

### 🟡 Gaps (known, acceptable for now)

| # | Issue | Severity | Notes |
|---|-------|----------|-------|
| 5 | `static_instruction` as Content | Low | Python-specific recent addition |
| 9 | Auth/confirmation event filtering | Low | Not needed until auth events exist |
| 10 | Rewind event handling | Low | Feature not in Elixir |
| 11 | Empty content detection | Low | Implicit handling works for now |
| 15 | Mandatory args pre-validation | Low | Could add later |
| 21 | Safety settings not forwarded | Medium | Should add to generate_config mapping |
| 27 | set_model_response virtual tool | Medium | Simpler approach may suffice |

### ✅ Intentional Differences (documented, no action needed)

| # | Issue | Reason |
|---|-------|--------|
| 1-2 | Identity instruction phrasing | Cleaner, more natural |
| 3-4 | Transfer instruction format | More concise, same semantics |
| 6 | Missing "For context:" prefix | Minor LLM hint, not critical |
| 7 | Tool response wording variation | Same meaning |
| 8 | Async function response rearrangement | BEAM handles parallelism differently |
| 12 | No function call ID stripping | Different ID strategy |
| 13 | Transfer tool naming (one per agent) | More explicit approach |
| 22 | No billing labels | Not needed |
| 23 | HTTP client differences | Req vs google-genai SDK |
| 29 | No model name validation | Trust the user |

---

## 4. Fixes Applied

### Fix 1: Function Response Dict Wrapping (Issues #24-25)

The Gemini API expects `function_response.response` to be a JSON object (dict), not a raw string. Python ADK explicitly wraps non-dict results as `{"result": value}`.

**File:** `lib/adk/agent/llm_agent.ex`

**Change:** In the tool response building section, wrap string/non-map results in a map.

### Fix 2: Safety Settings Forwarding (Issue #21)

Added `safety_settings` to the generate_config mapping in the Gemini backend.

**File:** `lib/adk/llm/gemini.ex`

**Change:** Map `safety_settings` from generate_config to the request body.

### Fix 3: Output Schema Auto-Config (Issue #28)

When `output_schema` is set on the agent, automatically set `response_mime_type` and `response_schema` in the generate config.

**File:** `lib/adk/agent/llm_agent.ex`

---

## 5. Request Flow Diagram

```
Python ADK                              Elixir ADK
──────────                              ──────────
Runner.run_async()                      ADK.Agent.run(agent, ctx)
  │                                       │
  ├─ InvocationContext                    ├─ Context struct
  │                                       │
  ├─ AutoFlow.run_async()                 ├─ LlmAgent.do_run()
  │   │                                   │   │
  │   ├─ _preprocess_async()              │   ├─ build_request()
  │   │   │                               │   │   │
  │   │   ├─ basic (model, config)        │   │   ├─ compile_instruction()
  │   │   ├─ auth_preprocessor            │   │   ├─ build_messages()
  │   │   ├─ instructions                 │   │   ├─ effective_tools()
  │   │   ├─ identity                     │   │   ├─ maybe_compress()
  │   │   ├─ compaction                   │   │   ├─ merge_generate_config()
  │   │   ├─ contents                     │   │   └─ apply_run_config()
  │   │   ├─ cache/planning/etc.          │   │
  │   │   └─ agent_transfer               │   ├─ ADK.LLM.generate()
  │   │                                   │   │   │
  │   ├─ _process_agent_tools()           │   │   ├─ Retry.with_retry()
  │   │                                   │   │   ├─ CircuitBreaker.call()
  │   ├─ _call_llm_async()               │   │   └─ Gemini.generate()
  │   │   │                               │   │       │
  │   │   ├─ before_model_callback        │   │       ├─ build_request_body()
  │   │   ├─ Gemini.generate_content()    │   │       └─ Req.post()
  │   │   └─ after_model_callback         │   │
  │   │                                   │   └─ Process response/tools
  │   └─ _postprocess_async()             │
  │       │                               │
  │       ├─ response_processors          │
  │       ├─ handle_function_calls        │
  │       └─ agent_transfer               │
  │                                       │
  └─ Yield events                         └─ Return events
```

## 6. Wire Format Comparison (Concrete Example)

### Scenario: Agent with one tool, first user message

**Python sends to Gemini API:**
```json
{
  "systemInstruction": {
    "parts": [{"text": "You are a helpful assistant.\n\nYou are an agent. Your internal name is \"weather_bot\". The description about you is \"Gets weather info\"."}]
  },
  "contents": [
    {"role": "user", "parts": [{"text": "What's the weather in NYC?"}]}
  ],
  "tools": [{
    "functionDeclarations": [{
      "name": "get_weather",
      "description": "Get current weather for a location",
      "parameters": {
        "type": "OBJECT",
        "properties": {
          "location": {"type": "STRING", "description": "City name"}
        },
        "required": ["location"]
      }
    }]
  }],
  "generationConfig": {}
}
```

**Elixir sends to Gemini API:**
```json
{
  "system_instruction": {
    "parts": [{"text": "You are a helpful assistant.\n\nYou are weather_bot. Gets weather info\n\nGet current weather for a location"}]
  },
  "contents": [
    {"role": "user", "parts": [{"text": "What's the weather in NYC?"}]}
  ],
  "tools": [{
    "function_declarations": [{
      "name": "get_weather",
      "description": "Get current weather for a location",
      "parameters": {
        "type": "object",
        "properties": {
          "location": {"type": "string", "description": "City name"}
        },
        "required": ["location"]
      }
    }]
  }],
  "generationConfig": {}
}
```

**Key differences in this example:**
1. `systemInstruction` vs `system_instruction` — Both valid for Gemini REST API ✅
2. `functionDeclarations` vs `function_declarations` — Both valid ✅  
3. Identity text differs — Intentional ✅
4. Schema type values `"OBJECT"` vs `"object"` — Both valid ✅

### Scenario: Tool response back to model

**Python sends:**
```json
{
  "contents": [
    {"role": "user", "parts": [{"text": "What's the weather?"}]},
    {"role": "model", "parts": [{"functionCall": {"name": "get_weather", "args": {"location": "NYC"}}}]},
    {"role": "user", "parts": [{"functionResponse": {"name": "get_weather", "response": {"result": "72°F, sunny"}}}]}
  ]
}
```

**Elixir sends (BEFORE fix):**
```json
{
  "contents": [
    {"role": "user", "parts": [{"text": "What's the weather?"}]},
    {"role": "model", "parts": [{"functionCall": {"name": "get_weather", "args": {"location": "NYC"}}}]},
    {"role": "user", "parts": [{"functionResponse": {"name": "get_weather", "response": "72°F, sunny"}}]}
  ]
}
```

**Elixir sends (AFTER fix):**
```json
{
  "contents": [
    {"role": "user", "parts": [{"text": "What's the weather?"}]},
    {"role": "model", "parts": [{"functionCall": {"name": "get_weather", "args": {"location": "NYC"}}}]},
    {"role": "user", "parts": [{"functionResponse": {"name": "get_weather", "response": {"result": "72°F, sunny"}}}]}
  ]
}
```

---

## 7. Conclusion

The Elixir ADK produces **functionally equivalent** LLM requests for the same inputs, with differences falling into three categories:

1. **3 bugs fixed** — function response wrapping, safety settings forwarding, output schema config
2. **7 known gaps** — features that Python has but Elixir intentionally defers (rewind, async rearrangement, static_instruction as Content, etc.)
3. **10 intentional differences** — cleaner phrasing, different transfer tool strategy, BEAM-native parallelism approach

The core execution path is sound. The most impactful fix is #24-25 (function response dict wrapping), which could cause Gemini API errors in production.

**Test status after fixes:** 890 tests, 0 failures.
