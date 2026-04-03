# Google GenAI Python SDK vs ADK Elixir Gemini Backend — Comparison Report

**Date:** 2026-04-03
**ADK Elixir file:** `lib/adk/llm/gemini.ex`
**Python SDK:** `googleapis/python-genai` (main branch)
**API endpoint:** `v1beta/models/{model}:generateContent`

---

## Executive Summary

ADK Elixir's Gemini backend covers the **core happy path** well (contents, system instruction, tools with toolConfig, basic generationConfig, thoughtSignature round-tripping, code execution parts, retry logic). However, it's missing significant generationConfig fields, several content part types, full candidate/response metadata parsing, streaming support, and thinking config passthrough.

**Recently fixed:** ✅ `toolConfig` with `functionCallingConfig.mode: AUTO` is now sent when tools are present.

---

## Discrepancy Table

### P0 — Breaks Functionality

| # | Area | Python SDK | ADK Elixir | Fix |
|---|------|-----------|------------|-----|
| 1 | **thinkingConfig in generationConfig** | Sends `generationConfig.thinkingConfig` with `thinkingBudget` and/or `thinkingLevel` | Not sent. No way to pass thinking config. | Add `thinking_config` to `generate_config` mapping → `generationConfig.thinkingConfig` |
| 2 | **finishReason not parsed** | Parses `candidates[0].finishReason` (STOP, MAX_TOKENS, SAFETY, MALFORMED_FUNCTION_CALL, etc.) | `parse_response` ignores `finishReason` entirely. Callers can't detect truncation, safety blocks, or malformed tool calls. | Extract `finishReason` from candidate and include in response map |
| 3 | **promptFeedback / blocked prompts** | Parses `promptFeedback.blockReason` when no candidates returned | `parse_response` with no candidates returns empty text, losing the block reason | Parse `promptFeedback` and return as error or metadata |
| 4 | **functionResponse part not parsed from response** | Parses `functionResponse` parts in responses (needed for cached content replay) | `parse_response_part` has no clause for `"functionResponse"` — falls through to raw passthrough | Add `parse_response_part` clause for `"functionResponse"` |

### P1 — Missing Feature

| # | Area | Python SDK | ADK Elixir | Fix |
|---|------|-----------|------------|-----|
| 5 | **generationConfig: presencePenalty, frequencyPenalty** | Sends `presencePenalty`, `frequencyPenalty` | Not mapped in `generate_config` | Add to `build_request_body` generationConfig section |
| 6 | **generationConfig: seed** | Sends `seed` for reproducibility | Not mapped | Add `seed` mapping |
| 7 | **generationConfig: responseLogprobs, logprobs** | Sends both fields | Not mapped | Add mapping |
| 8 | **generationConfig: responseModalities** | Sends `responseModalities` (TEXT, IMAGE, AUDIO) | Not mapped | Add mapping |
| 9 | **generationConfig: responseJsonSchema** | Sends `responseJsonSchema` (alternative to responseSchema) | Not mapped | Add mapping |
| 10 | **Content part: inlineData (images/audio)** | Sends `inlineData` with `mimeType` + base64 `data` | `format_part` has no clause for `inline_data`; falls through to passthrough (may work if caller uses camelCase keys, but fragile) | Add explicit `format_part(%{inline_data: ...})` clause |
| 11 | **Content part: fileData** | Sends `fileData` with `fileUri` + `mimeType` | No explicit clause; passthrough only | Add `format_part(%{file_data: ...})` clause |
| 12 | **Response part: inlineData** | Parses `inlineData` (returned images/audio) | No clause in `parse_response_part` | Add clause to parse inline data blobs |
| 13 | **Streaming support** | Full streaming via `generate_content_stream()` with SSE | No streaming at all — only synchronous `Req.post` | Implement streaming endpoint (`:streamGenerateContent?alt=sse`) with chunked response parsing |
| 14 | **Candidate metadata: safetyRatings** | Parses per-candidate `safetyRatings` array | Not extracted from response | Add to `parse_response` |
| 15 | **Candidate metadata: citationMetadata** | Parses `citationMetadata.citationSources` | Not extracted | Add to `parse_response` |
| 16 | **Candidate metadata: groundingMetadata** | Parses `groundingMetadata` for search grounding | Not extracted | Add to `parse_response` |
| 17 | **Usage metadata: thoughtsTokenCount** | Parses `usageMetadata.thoughtsTokenCount` | Passes through raw `usageMetadata` map (works, but not normalized) | OK as-is, but document the raw passthrough |
| 18 | **cachedContent** | Sends `cachedContent` at request body top level | Not supported | Add `cached_content` option to request |
| 19 | **Google Search / URL Context tools** | Sends `google_search`, `url_context`, `code_execution` as tool entries | Supports `google_search` and `code_execution` builtins, but **not `url_context`** | Add `url_context` builtin |
| 20 | **Tool: allowed_function_names** | `toolConfig.functionCallingConfig.allowedFunctionNames` restricts which functions model can call | `tool_config` passthrough works if caller provides full structure, but no convenience API | Document or add helper |
| 21 | **Tool: functionCallingConfig modes** | AUTO, ANY, NONE, VALIDATED | Hardcodes `AUTO` as default. Caller can override via `tool_config` key, but no validation of modes. | Good enough, but add validation |
| 22 | **FunctionDeclaration: response schema** | Supports `response` and `responseJsonSchema` on function declarations | Not mapped in `format_tools` | Add if needed for validated mode |
| 23 | **Error response: structured error parsing** | Parses error responses into typed exceptions with status, message | Returns `{:error, {:api_error, status, body}}` — body is raw, no structured parsing | Parse `error.message` and `error.status` from body |

### P2 — Nice to Have

| # | Area | Python SDK | ADK Elixir | Fix |
|---|------|-----------|------------|-----|
| 24 | **generationConfig: mediaResolution** | Sends `mediaResolution` (LOW/MEDIUM/HIGH) | Not mapped | Add if multimodal needed |
| 25 | **generationConfig: speechConfig** | Sends `speechConfig` for audio output | Not mapped | Add if audio needed |
| 26 | **generationConfig: imageConfig** | Sends `imageConfig` for image generation | Not mapped | Add if image gen needed |
| 27 | **Automatic function calling loop** | Python SDK has `automatic_function_calling` that loops tool calls | ADK Elixir handles this at `ADK.Agent` level, not LLM backend | By design — not a gap |
| 28 | **modelVersion in response** | Parses `modelVersion` from response | Not extracted | Low priority |
| 29 | **responseId in response** | Parses `responseId` | Not extracted | Low priority |
| 30 | **serviceTier** | Sends `serviceTier` at request level | Not mapped | Add if needed for priority routing |
| 31 | **FunctionCall.id** | Python SDK sends/parses `id` field on function calls | Not handled | May be needed for parallel function calling |
| 32 | **system_instruction key name** | Python SDK: `systemInstruction` (camelCase in wire format) | ADK Elixir sends `system_instruction` (snake_case) | **Check this!** The API expects `systemInstruction`. ADK sends `:system_instruction` as atom key → serialized to `"system_instruction"`. This could be silently ignored by the API! |

---

## Critical Check: system_instruction Key Format

**LIKELY OK:** ADK Elixir uses `:system_instruction` (snake_case) and `:function_declarations` (snake_case). The Gemini REST API is protobuf-based with JSON transcoding, which typically accepts **both** snake_case and camelCase. The Python SDK uses camelCase (`systemInstruction`, `functionDeclarations`). ADK Elixir's snake_case keys probably work fine since they match the proto field names.

**Recommendation:** Empirically verify, but low risk. If issues arise, change to camelCase to match the Python SDK exactly.

---

## Test Plan

### P0 Tests (Must Have)

| Test | What to verify |
|------|---------------|
| `test_thinking_config_sent` | When `generate_config: %{thinking_config: %{thinkingBudget: 1024}}`, verify `generationConfig.thinkingConfig.thinkingBudget` appears in request body |
| `test_finish_reason_parsed` | Mock a response with `finishReason: "SAFETY"`, verify it's present in parsed output |
| `test_blocked_prompt_error` | Mock response with no candidates + `promptFeedback.blockReason`, verify error returned |
| `test_function_response_part_parsed` | Mock response containing `functionResponse` part, verify parsed correctly |
| `test_system_instruction_camel_case` | Verify the JSON body contains `"systemInstruction"` not `"system_instruction"` |

### P1 Tests

| Test | What to verify |
|------|---------------|
| `test_generation_config_all_fields` | All generationConfig fields (presencePenalty, frequencyPenalty, seed, responseLogprobs, logprobs, responseModalities, responseJsonSchema) appear in request body |
| `test_inline_data_part_sent` | Image/audio parts with `inline_data` are formatted as `inlineData` with correct structure |
| `test_file_data_part_sent` | File parts with `file_data` are formatted as `fileData` |
| `test_inline_data_response_parsed` | Response with `inlineData` part is parsed into `%{inline_data: ...}` |
| `test_safety_ratings_parsed` | Candidate safetyRatings are extracted from response |
| `test_citation_metadata_parsed` | citationMetadata is extracted from response |
| `test_grounding_metadata_parsed` | groundingMetadata is extracted from response |
| `test_cached_content_sent` | `cachedContent` appears at top level of request body |
| `test_url_context_builtin` | `%{__builtin__: :url_context}` produces `{url_context: {}}` in tools array |
| `test_tool_config_modes` | Each mode (AUTO, ANY, NONE, VALIDATED) is correctly sent |
| `test_allowed_function_names` | `allowedFunctionNames` list is passed through in toolConfig |
| `test_streaming_generate` | (Future) Streaming endpoint returns chunks parsed correctly |

### Regression Tests (Existing Behavior)

| Test | What to verify |
|------|---------------|
| `test_tool_config_auto_default` | When tools present and no explicit tool_config, `toolConfig.functionCallingConfig.mode: "AUTO"` is sent |
| `test_no_tool_config_without_tools` | When no tools, `toolConfig` is absent from body |
| `test_thought_signature_roundtrip` | thoughtSignature in response parts is preserved and sent back in subsequent requests |
| `test_code_execution_parts` | executableCode and codeExecutionResult parts are parsed from responses |

---

## Prioritized Fix Plan

### Phase 1 — Critical (Do Now)
1. **Verify `system_instruction` vs `systemInstruction` key** — test empirically and fix to camelCase if needed
2. **Add `thinkingConfig` to generationConfig** — essential for Gemini 2.5 thinking models
3. **Parse `finishReason`** from candidates — needed to detect truncation/safety/malformed calls
4. **Parse `promptFeedback`** — needed to detect blocked prompts

### Phase 2 — Important (This Week)
5. Add missing generationConfig fields: `presencePenalty`, `frequencyPenalty`, `seed`, `responseLogprobs`, `logprobs`, `responseModalities`, `responseJsonSchema`
6. Add `inlineData` and `fileData` format_part clauses (multimodal support)
7. Add `inlineData` parse_response_part clause
8. Add `url_context` builtin tool
9. Add `cachedContent` support
10. Parse candidate metadata: `safetyRatings`, `citationMetadata`, `groundingMetadata`

### Phase 3 — Enhancement (Next Sprint)
11. Streaming support (`streamGenerateContent`)
12. Structured error parsing
13. `FunctionCall.id` for parallel function calling
14. `serviceTier` support

### Phase 4 — Low Priority
15. mediaResolution, speechConfig, imageConfig
16. modelVersion, responseId in response
17. FunctionDeclaration response schema

---

## Appendix: Request Body Comparison

### Python SDK (via `_GenerateContentParameters_to_mldev`)
```json
{
  "contents": [...],
  "systemInstruction": {"parts": [{"text": "..."}]},
  "tools": [{"functionDeclarations": [...]}],
  "toolConfig": {"functionCallingConfig": {"mode": "AUTO", "allowedFunctionNames": [...]}},
  "generationConfig": {
    "temperature": 0.7,
    "topP": 0.9,
    "topK": 40,
    "candidateCount": 1,
    "maxOutputTokens": 8192,
    "stopSequences": [],
    "presencePenalty": 0.0,
    "frequencyPenalty": 0.0,
    "seed": 42,
    "responseMimeType": "application/json",
    "responseSchema": {...},
    "responseJsonSchema": {...},
    "responseLogprobs": true,
    "logprobs": 5,
    "responseModalities": ["TEXT"],
    "mediaResolution": "MEDIA_RESOLUTION_MEDIUM",
    "speechConfig": {...},
    "thinkingConfig": {"thinkingBudget": 2048},
    "imageConfig": {...},
    "enableEnhancedCivicAnswers": false
  },
  "safetySettings": [{"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_MEDIUM_AND_ABOVE"}],
  "cachedContent": "cachedContents/abc123",
  "serviceTier": "standard"
}
```

### ADK Elixir (current)
```json
{
  "contents": [...],
  "system_instruction": {"parts": [{"text": "..."}]},
  "tools": [{"function_declarations": [...]}],
  "toolConfig": {"functionCallingConfig": {"mode": "AUTO"}},
  "generationConfig": {
    "temperature": 0.7,
    "topP": 0.9,
    "topK": 40,
    "candidateCount": 1,
    "maxOutputTokens": 8192,
    "stopSequences": [],
    "responseMimeType": "application/json",
    "responseSchema": {...}
  },
  "safetySettings": [...]
}
```

**Key differences visible:** Missing thinkingConfig, presencePenalty, frequencyPenalty, seed, logprobs, responseModalities, cachedContent, serviceTier. Possibly wrong key for systemInstruction.
