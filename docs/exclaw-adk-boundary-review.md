# ADK ↔ ExClaw Boundary Review

> Audit: which ExClaw modules should move to ADK? March 26, 2026.

## Principle
**ADK = reusable agent framework.** Generic agent capabilities that any Elixir app could use.
**ExClaw = opinionated agent platform.** Specific to personal assistant use case (channels, workspace, config, lifecycle).

---

## Already Correct (no changes needed)

### Belongs in ADK ✅
| ADK Module | Why |
|-----------|-----|
| ADK.Agent.* | Agent abstractions |
| ADK.Runner | Agent execution |
| ADK.Session, ADK.Session.Store.* | Session management |
| ADK.LLM.* (Gemini, Anthropic, OpenAI) | LLM backends |
| ADK.Tool.* | Tool framework |
| ADK.Skill.* | Skill loading/discovery |
| ADK.MCP.* | MCP client |
| ADK.A2A.* | Agent-to-agent |
| ADK.Event, ADK.EventCompaction | Event model + compaction |
| ADK.LLM.Gateway, Router | Multi-provider management |
| ADK.Workflow.* | DAG execution |
| ADK.Context.Compressor | Token budget compression |

### Belongs in ExClaw ✅
| ExClaw Module | Why |
|--------------|-----|
| Channel.* (Discord, Telegram) | Platform-specific integrations |
| Gateway, Gateway.Router | HTTP server, specific to ExClaw |
| Config, Config.Schema | ExClaw-specific JSON config |
| Workspace.*, InstructionBuilder | SOUL.md/USER.md/MEMORY.md patterns |
| Lifecycle.*, Health, Shutdown | OTP app lifecycle |
| Scheduler, CronParser | ExClaw-specific job scheduling |
| Security.* (ExecGuard, PathGuard) | ExClaw's security model |
| TalkerDoer.* | ExClaw-specific architecture |
| Plugin.* | ExClaw plugin system |
| SessionManager, Announcer | ExClaw session orchestration |
| Usage.* (Tracker, Budget, Cost) | ExClaw usage tracking |
| Mix tasks | CLI interface |

---

## Potential Moves (ExClaw → ADK)

### 1. ExClaw.Tool.{Read,Write,Edit,Exec} → ADK.Tool.*
**Status:** ADK already has `ADK.Tool.BashTool`. ExClaw has more specialized versions.
**Recommendation:** Keep ExClaw versions as they are. They're tailored to ExClaw's security model (PathGuard, ExecGuard). ADK's BashTool serves the generic case. No move needed.

### 2. ExClaw.Compaction.{Summarize,Truncate} → ADK.EventCompaction
**Status:** ADK has `ADK.EventCompaction` but it's simpler. ExClaw's strategies are more sophisticated (LLM-based summarization).
**Recommendation:** Enhance `ADK.EventCompaction` with ExClaw's summarize strategy. The truncate strategy is trivial. **Move the summarizer pattern** (inject LLM function) into ADK.
**Priority:** Low — works fine in ExClaw for now.

### 3. ExClaw.LLM.Cascade → ADK.LLM.Router
**Status:** ADK has `ADK.LLM.Router` (priority failover + circuit breaker). ExClaw has `LLM.Cascade` which overlaps significantly.
**Recommendation:** ExClaw.LLM.Cascade should be REMOVED and replaced with ADK.LLM.Router. **Deduplicate.**
**Priority:** Medium — reduces maintenance burden.

### 4. ExClaw.TokenBudget → ADK.Context.Compressor.TokenBudget
**Status:** ADK has token budget in `Context.Compressor.TokenBudget`. ExClaw has its own.
**Recommendation:** Same as Cascade — **use ADK's version**, remove ExClaw's duplicate.
**Priority:** Medium.

### 5. ExClaw.MCP.* → Use ADK.MCP.* directly
**Status:** Both have MCP implementations. ExClaw's wraps ADK's with extra lifecycle management.
**Recommendation:** The wrapper pattern is correct. ExClaw.MCP.Manager adds supervisor/registry on top of ADK.MCP.Client. No change needed.

### 6. ExClaw.Queue → ADK generic?
**Status:** Message serialization queue. Generic pattern.
**Recommendation:** Keep in ExClaw. It's tightly coupled to ExClaw's channel→agent flow. Not generic enough for ADK.

---

## Action Items

| # | Action | Priority | Impact |
|---|--------|----------|--------|
| 1 | Replace ExClaw.LLM.Cascade with ADK.LLM.Router | Medium | Dedup, single source of truth |
| 2 | Replace ExClaw.TokenBudget with ADK.Context.Compressor.TokenBudget | Medium | Dedup |
| 3 | Port ExClaw's LLM summarize strategy to ADK.EventCompaction | Low | Enriches ADK |
| 4 | Verify ExClaw.Skill uses ADK.Skill (not duplicating) | Low | Already aligned |

**None of these are beta blockers.** The current boundary works. These are maintenance improvements for post-beta.

---

## Conclusion

The boundary is mostly clean. The main overlap is in LLM cascade/routing and token budgets — both exist in ADK and ExClaw. Post-beta, deduplicate by having ExClaw delegate to ADK for these. Everything else is correctly placed.
