# ADK Elixir / ExClaw: End-User Polish & Recovery Design

**Status:** Draft  
**Author:** Zaf  
**Date:** 2026-03-26  
**Sources audited:** Gemini CLI, OpenCode, OpenClaw, Claude Code

## Purpose

Audit peer agent CLIs/frameworks for recovery, error handling, and UX polish
patterns. Identify what we should steal, what we already have, and what's missing.

---

## Audit Findings

### 1. Gemini CLI

**What they do well:**
- **Silent retry** — API errors are retried up to 3x silently before surfacing to user (v0.35.0)
- **Structured exit codes** — specific codes for scripting/automation (auth failure ≠ API error ≠ crash)
- **Verbose mode** — `--verbose` flag for detailed debugging without cluttering normal output
- **GEMINI_API_KEY detection** — startup validates env var presence, gives actionable message

**What they struggle with (from issues):**
- Cryptic errors: "CLI quits without any error after 20 seconds" (#1425)
- Auth confusion: "Confusing and fragmented authentication flow" (#1872)
- False errors: "Ensure your Google account is not a Workspace account" shown for standard accounts (#1432)
- No guided recovery: "Authentication timed out" with no next steps (#1559)

**Proposed fix (their issue #2151):**
- Error categories: Network, Authentication, Configuration, API, Platform
- Severity levels with appropriate user actions
- Unique error codes
- Platform-specific advice (Windows/macOS/Linux)
- Automatic environment validation at startup
- Recovery suggestions: "Offer to create missing config files"

**Relevance to ADK Elixir:** HIGH. We need all of this.

### 2. OpenCode

**What they do well:**
- **Session recovery** — automatically handles interrupted tool calls:
  - `tool_result_missing` → injects synthetic tool_result ("Operation cancelled by user")
  - `thinking_block_order` → auto-prepends empty thinking block
  - `thinking_disabled_violation` → auto-strips thinking blocks
- **Auto-resume** — optional: after recovery, automatically sends "continue" to restore conversation
- **Deduplication** — prevents same error from being processed repeatedly (Set-based)
- **Human-readable errors** — recent fix: tool/session errors display clean format, not raw technical strings
- **Tool discovery recovery** — includes cache bin directory in PATH lookups
- **`models --refresh`** — clears corrupted model cache

**Relevance to ADK Elixir:** HIGH. Session recovery with synthetic tool results is critical.

### 3. OpenClaw (our platform)

**What it already does:**
- **Synthetic tool result injection** — `session-transcript-repair.ts` inserts synthetic error results when tool results are missing in session history
- **Tool result truncation guard** — `session-tool-result-guard.ts` caps oversized tool results (proportional truncation with newline-boundary cuts, truncation suffix warning)
- **Tool call input sanitization** — strips sensitive data from persisted tool calls
- **`openclaw doctor --fix`** — automated diagnostics + repair
- **Config validation** — schema validation at startup with actionable messages
- **Session path security** — enforces session files within sessions directory (path traversal prevention)
- **PID lock management** — handles "gateway already running" gracefully
- **Token mismatch recovery** — guidance for device/gateway token issues

**What it doesn't do well (from community reports):**
- Silent failures — things break without logging anything
- Config migration confusion — `agent.*` moved to `agents.defaults.*` but error message is terse
- Model allowlist blocks — unclear why a model isn't available

**Relevance to ADK Elixir:** MEDIUM. We can steal the transcript repair pattern directly.

### 4. Claude Code

**What they do well:**
- **Permission system** — allowlist/denylist for tool access, `--dangerously-skip-permissions` as explicit opt-out
- **`claude doctor`** — diagnostic command that checks npm prefix, permissions, environment
- **Tool error → LLM feedback** — tool exceptions become function_response errors, LLM can adapt

**What they struggle with:**
- Permission deny patterns not actually enforced (#6631)
- `rm -rf /` incident from permission skip (#10077) — catastrophic
- MCP server permission configuration is confusing
- No session recovery mechanism for interrupted tool calls

**Relevance to ADK Elixir:** MEDIUM. Permission model is good, `doctor` command is good.

---

## Pattern Catalog

### P1: Silent Retry (Gemini CLI)
**What:** Retry transient API errors 1-3x before surfacing to user.  
**ADK Elixir status:** ✅ ALREADY HAVE — `ADK.LLM.Retry` with exponential backoff + jitter.  
**ExClaw status:** ❌ NEED — Wire Retry into the Runner pipeline so users never see transient 500s.

### P2: Synthetic Tool Result Injection (OpenCode, OpenClaw)
**What:** When a tool call is interrupted (timeout, crash, user cancel), inject a synthetic tool_result so the LLM can continue instead of stalling.  
**ADK Elixir status:** ❌ NEED — `FunctionTool.run/3` now rescues exceptions (#673), but we don't handle: missing results from crashed processes, interrupted async tools, or session replay with gaps.  
**ExClaw status:** ❌ NEED

**Proposed implementation:**
```elixir
defmodule ADK.Session.TranscriptRepair do
  @moduledoc "Detects and repairs gaps in session history."
  
  def repair(events) do
    # Walk events, find tool_calls without matching tool_results
    # Inject synthetic error results for orphaned calls
    # Log repair action to telemetry
  end
end
```

### P3: Tool Result Size Guard (OpenClaw)
**What:** Cap oversized tool results to prevent context window blowout.  
**ADK Elixir status:** ❌ NEED — No truncation guard exists. A tool returning 1MB of stdout will blow the context.  
**ExClaw status:** ❌ NEED

**Proposed implementation:**
```elixir
defmodule ADK.Tool.ResultGuard do
  @moduledoc "Truncates oversized tool results to protect context window."
  
  @default_max_chars 50_000
  @truncation_suffix "\n\n⚠️ [Output truncated — exceeded size limit. Use offset/limit for large content.]"
  
  def cap(result, opts \\ []) do
    max = Keyword.get(opts, :max_chars, @default_max_chars)
    if String.length(result) > max do
      # Cut at newline boundary
      # Append truncation suffix
    else
      result
    end
  end
end
```

### P4: Actionable Error Messages (Gemini CLI #2151)
**What:** Replace cryptic errors with structured messages: what happened, why, what to do.  
**ADK Elixir status:** ❌ NEED — Errors are raw Elixir terms (`{:error, :econnrefused}`).  
**ExClaw status:** ❌ NEED

**Proposed implementation:**
```elixir
defmodule ADK.Error do
  @moduledoc "Structured, actionable error messages."
  
  defstruct [:code, :category, :message, :action, :detail]
  
  @type t :: %__MODULE__{
    code: String.t(),           # "ADK_AUTH_001"
    category: :auth | :network | :config | :api | :tool | :session,
    message: String.t(),        # "API key not found"
    action: String.t(),         # "Set GEMINI_API_KEY environment variable"
    detail: String.t() | nil    # Technical detail for --verbose
  }
  
  # Example:
  # %ADK.Error{
  #   code: "ADK_AUTH_001",
  #   category: :auth,
  #   message: "Gemini API key not found",
  #   action: "Set GEMINI_API_KEY env var or add auth config to your Gateway",
  #   detail: "Checked: GEMINI_API_KEY, GOOGLE_API_KEY, ~/.config/gemini/credentials.json"
  # }
end
```

### P5: Startup Environment Validation (Gemini CLI, Claude Code)
**What:** At boot, check that required env vars, configs, and dependencies exist.  
**ADK Elixir status:** ✅ PARTIAL — `Gateway.Config.validate!/1` checks backend configs.  
**ExClaw status:** ❌ NEED — No `mix ex_claw.doctor` command.

**Proposed:**
```
$ mix adk.doctor
✅ Elixir 1.18.4 / OTP 27
✅ GEMINI_API_KEY set (ends in ...4f2e)
❌ OPENAI_API_KEY not set — needed for OpenAI backend
⚠️  ADK.LLM.Gateway: 2 of 3 backends reachable
✅ MCP: npx available at /usr/local/bin/npx
❌ Python 3: not found — needed for .py skill scripts
```

### P6: Exit Codes for Scripting (Gemini CLI)
**What:** Distinct exit codes so scripts/CI can branch on failure type.  
**ADK Elixir status:** ❌ NEED — `mix adk.server` returns 0 or 1.  
**ExClaw status:** ❌ NEED

**Proposed codes:**
| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Config error |
| 3 | Auth error |
| 4 | Network error |
| 5 | Tool execution error |
| 10 | Rate limited (all backends exhausted) |

### P7: Auto-Resume After Recovery (OpenCode)
**What:** After recovering from an interrupted tool call, automatically continue the conversation.  
**ADK Elixir status:** ❌ NEED  
**ExClaw status:** ❌ NEED — Critical for headless/daemon mode.

### P8: Corrupted Cache Recovery (OpenCode, OpenClaw)
**What:** `models --refresh` clears bad model cache. `doctor --fix` repairs config.  
**ADK Elixir status:** ❌ NEED  
**ExClaw status:** ❌ NEED — `mix ex_claw.doctor --fix`

### P9: Permission System (Claude Code)
**What:** Allowlist/denylist for tool access. Explicit opt-out for dangerous operations.  
**ADK Elixir status:** ❌ NEED — We have `ADK.Policy` but it's not wired to a permission config file.  
**ExClaw status:** 🟡 PARTIAL — Task #612 (tool policies) covers this.

### P10: Graceful Degradation on Missing Optional Dependencies
**What:** If Python isn't installed but a skill has `.py` scripts, warn but don't crash.  
**ADK Elixir status:** ❌ NEED — `ADK.Skill.Script` will crash on `System.cmd("python3", ...)`.  
**ExClaw status:** ❌ NEED

**Proposed:** Check dependencies at skill load time:
```elixir
def validate_scripts(skill) do
  for tool <- skill.tools do
    case tool do
      %{type: :python} -> 
        unless System.find_executable("python3"),
          do: Logger.warning("Skill '#{skill.name}': python3 not found, .py scripts will fail")
      %{type: :shell} ->
        unless System.find_executable("bash"),
          do: Logger.warning("Skill '#{skill.name}': bash not found, .sh scripts will fail")
    end
  end
end
```

---

## Summary Matrix

| Pattern | Gemini CLI | OpenCode | OpenClaw | Claude Code | ADK Elixir | ExClaw |
|---------|-----------|----------|----------|-------------|------------|--------|
| P1: Silent retry | ✅ | ? | ✅ | ? | ✅ | ❌ |
| P2: Synthetic tool results | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| P3: Result size guard | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ |
| P4: Actionable errors | 🟡 (planned) | ✅ (recent) | 🟡 | 🟡 | ❌ | ❌ |
| P5: Startup validation | ✅ | ✅ | ✅ (doctor) | ✅ (doctor) | 🟡 | ❌ |
| P6: Exit codes | ✅ | ? | ❌ | ❌ | ❌ | ❌ |
| P7: Auto-resume | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| P8: Cache recovery | ❌ | ✅ | ✅ (doctor --fix) | ✅ (doctor) | ❌ | ❌ |
| P9: Permission system | ❌ | ❌ | ❌ | ✅ | 🟡 (Policy) | 🟡 (#612) |
| P10: Graceful degradation | ? | ✅ | 🟡 | 🟡 | ❌ | ❌ |

## Priority for ADK Elixir

| Priority | Pattern | Task |
|----------|---------|------|
| **P0** | P2: Synthetic tool results | `ADK.Session.TranscriptRepair` |
| **P0** | P3: Result size guard | `ADK.Tool.ResultGuard` |
| **P0** | P4: Actionable errors | `ADK.Error` struct |
| **P1** | P5: `mix adk.doctor` | Startup validation command |
| **P1** | P10: Graceful degradation | Script dependency checks at skill load |
| **P1** | P7: Auto-resume | Session recovery + continue |
| **P2** | P6: Exit codes | Standardized exit codes |
| **P2** | P8: Cache recovery | `mix adk.doctor --fix` |
| Already done | P1: Silent retry | `ADK.LLM.Retry` ✅ |
| Already done | P9: Permission system | `ADK.Policy` (needs wiring) |
