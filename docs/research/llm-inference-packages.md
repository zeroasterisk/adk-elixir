# Elixir LLM Inference Packages — Research Report

**Date:** 2026-04-03
**Context:** ADK Elixir currently maintains ~2,400 lines of hand-rolled LLM HTTP clients (Gemini, Anthropic, OpenAI) using Req. We're evaluating whether to take a dependency on an external package.

---

## Package Landscape

### 1. LangChain (Elixir) — `langchain`
- **Hex:** https://hex.pm/packages/langchain
- **GitHub:** https://github.com/brainlid/langchain (~1.8k stars)
- **Version:** 0.7.0 (updated Apr 2, 2026)
- **Downloads:** 568k all-time, ~16k/week
- **License:** Apache-2.0
- **LLM Support:** OpenAI, Anthropic (incl. thinking), Google Gemini, xAI Grok, Ollama, Mistral, Perplexity, Bumblebee, LMStudio
- **Features:** Function/tool calling, streaming, chains, agents, structured output, message routing
- **Quality:** Actively maintained by brainlid (Mark Ericksen). 13 dependants. CI. Good docs. LiveView demo project. Most mature Elixir LLM library by far.
- **Assessment:** ⭐⭐⭐⭐⭐ The clear leader. High quality, comprehensive, actively maintained.

### 2. GenAI — `genai`
- **Hex:** https://hex.pm/packages/genai
- **GitHub:** https://github.com/noizu-labs-ml/genai
- **Version:** 0.3.0 (updated Mar 24, 2026)
- **Downloads:** 2.7k all-time, ~0/week
- **License:** MIT
- **LLM Support:** OpenAI, Anthropic, Gemini, Mistral, Groq, XAI, DeepSeek, Ollama, local (ex_llama NIF)
- **Features:** Unified interface, tool integration, dynamic model selection, grid search tuning
- **Quality:** Ambitious scope but very low adoption. Solo maintainer (Noizu Labs). Docs have typos. 0 dependants.
- **Assessment:** ⭐⭐ Interesting ideas but too immature/niche to depend on.

### 3. gemini_ex — `gemini_ex`
- **Hex:** https://hex.pm/packages/gemini_ex
- **GitHub:** https://github.com/nshkrdotcom/gemini_ex
- **Version:** 0.12.0 (updated Apr 2, 2026)
- **Downloads:** 6.4k all-time, ~740/week
- **License:** MIT
- **LLM Support:** Google Gemini only (AI Studio + Vertex AI)
- **Features:** Dual auth, embeddings with MRL, streaming, telemetry, type safety
- **Quality:** Very actively developed (12 versions in short time). 6 dependants. Gemini-focused.
- **Assessment:** ⭐⭐⭐ Good for Gemini-only use, but rapid version churn suggests instability. Single-provider.

### 4. openai — `openai`
- **Hex:** https://hex.pm/packages/openai
- **GitHub:** https://github.com/mgallo/openai.ex
- **Version:** 0.6.2 (last updated Jul 2024 — **stale**)
- **Downloads:** 698k all-time, ~2.1k/week
- **License:** MIT
- **LLM Support:** OpenAI only
- **Assessment:** ⭐⭐ High downloads but stale. Last update ~20 months ago. Missing newer API features.

### 5. Instructor / InstructorLite
- **instructor_lite:** https://hex.pm/packages/instructor_lite (v1.2.0, Feb 2026, 44k downloads)
- **Purpose:** Structured output extraction via Ecto schemas. Not an LLM client per se — sits on top of one.
- **Assessment:** ⭐⭐⭐⭐ Complementary tool, not a replacement for our LLM backends.

---

## Approach: Rustler NIFs wrapping Go SDK?

**Verdict: Not practical.**
- Rustler wraps Rust, not Go. You'd need a Go→C→NIF bridge (cgo + erl_nif), which is fragile.
- Massive complexity for marginal gain — the Go SDK is just an HTTP client with types.
- The Elixir ecosystem has adequate HTTP-level wrappers already.
- If we wanted official SDK parity, better to port the protocol buffer definitions and generate Elixir structs.

---

## Analysis & Recommendation

### Option A: Depend on `langchain` (the framework)
**Pros:**
- Most complete multi-LLM support in Elixir
- Tool calling, streaming, all the features we need
- Actively maintained, large community
- Would eliminate our ~2,400 lines of LLM client code

**Cons:**
- It's a *framework*, not just a client library — opinionated about chains, messages, routing
- ADK is itself a framework; taking a dependency on another framework creates coupling
- LangChain's abstractions may conflict with ADK's own agent/tool abstractions
- We'd depend on LangChain's release cycle for API updates (though it's fast)

### Option B: Depend on `gemini_ex` + keep OpenAI/Anthropic in-house
**Pros:**
- Gemini is our most complex/problematic API (toolConfig, Vertex auth, etc.)
- gemini_ex handles both AI Studio and Vertex AI auth
- Keep simpler OpenAI/Anthropic clients in-house (they're more stable APIs)

**Cons:**
- gemini_ex is young, fast-churning, single maintainer
- Splits our dependency strategy

### Option C: Maintain in-house (status quo, improved)
**Pros:**
- Full control over API surface
- No framework conflicts
- Can move as fast as needed when APIs change
- ~2,400 lines is manageable

**Cons:**
- Must track API changes ourselves (the bug that prompted this research)
- No community help catching edge cases

### ✅ Recommendation: **Option C — Maintain in-house, with targeted improvements**

**Reasoning:**
1. **ADK is a framework** — depending on another framework (LangChain) creates architectural tension. We'd fight its abstractions.
2. **Our code is small** — 2,400 lines across 3 providers is very manageable. The issue isn't volume, it's *keeping up with API changes*.
3. **The real fix is better testing** — the `toolConfig` bug wasn't a library problem, it was a testing gap. Integration tests against real APIs (even in CI with test keys) would catch these.
4. **Targeted adoption is fine** — if `gemini_ex` matures and stabilizes, we could adopt it for just the Gemini backend later. Monitor it.

**Specific improvements to make:**
- Add integration test suite that exercises tool calling against each provider
- Subscribe to API changelogs (Gemini, Anthropic, OpenAI)
- Consider auto-generating request types from OpenAPI specs where available
- Add a `PROVIDERS.md` doc tracking which API version each backend targets
- Review `gemini_ex` source for features/params we're missing (like `toolConfig`)

---

## References

| Package | Hex | GitHub | Weekly DL | Last Update |
|---------|-----|--------|-----------|-------------|
| langchain | [hex](https://hex.pm/packages/langchain) | [brainlid/langchain](https://github.com/brainlid/langchain) | 16,169 | Apr 2, 2026 |
| openai | [hex](https://hex.pm/packages/openai) | [mgallo/openai.ex](https://github.com/mgallo/openai.ex) | 2,128 | Jul 18, 2024 |
| gemini_ex | [hex](https://hex.pm/packages/gemini_ex) | [nshkrdotcom/gemini_ex](https://github.com/nshkrdotcom/gemini_ex) | 739 | Apr 2, 2026 |
| genai | [hex](https://hex.pm/packages/genai) | [noizu-labs-ml/genai](https://github.com/noizu-labs-ml/genai) | 0 | Mar 24, 2026 |
| instructor_lite | [hex](https://hex.pm/packages/instructor_lite) | [martosaur/instructor_lite](https://github.com/martosaur/instructor_lite) | 1,246 | Feb 1, 2026 |
