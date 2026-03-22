# ADK Elixir Roadmap

This document outlines the priorities and boundaries of the ADK Elixir project, specifically clarifying what will be ported from the Python ADK baseline vs what will be deferred or ignored.

## 🎯 High Priority (Focus)

1.  **Standard Text Streaming (SSE)**: Essential functionality for responsive AI applications. We prioritize standard chunked text streaming over complex Realtime/Voice modes.
2.  **Eval Framework Components**: Bringing `ADK.Eval.LLMJudge` and other evaluator structures to parity.
3.  **CLI Tooling**: Providing `mix adk.run` and `mix adk.eval` workflows for dev UX.
4.  **A2A v1.0 Compliance**: Complete testing and integration with `a2a-elixir`.
5.  **Robust Error Handling & Telemetry**: Hardening the core OTP loop for production.

## ⏸️ Postponed / Future (Low Priority)

These features from the Python baseline are acknowledged but intentionally delayed. Do not create placeholder implementations or fake parity tests for these.

*   **Gemini Live / Realtime WebSockets & VAD**: Deep integration with bidirectional audio streaming is postponed until the core text/SSE baseline is fully stable.
*   **AudioCacheManager**: Low priority component related to the postponed realtime streaming.
*   **Vertex AI Search / Grounding**: Deferred pending clearer usage patterns.
*   **Built-in Python Sandbox Execution**: `ADK.Tool.BuiltInCodeExecution` for sandboxed Python evaluation is postponed unless a native Elixir equivalent makes sense.

## ❌ Dropped / Won't Port

These Python ADK integrations are explicitly excluded from the Elixir roadmap to keep the framework lean and focused.

*   **LangChain Tool Adapters**: The LangChain ecosystem is Python-native. ADK Elixir will not bridge to LangChain.
*   **CrewAI Tool Adapters**: CrewAI is Python-native. ADK Elixir uses OTP/A2A for multi-agent.
*   **Apigee Proxy Routing**: Hardcoded proxy dispatchers (`apigee/`) are dropped in favor of clean environment-based URL overrides in standard HTTP clients.
