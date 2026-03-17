defmodule ADK.Telemetry.Contract do
  @moduledoc """
  Canonical contract for all `:adk.*` telemetry events.

  This module defines every telemetry event emitted by ADK as a structured
  contract — the single source of truth for the control plane data surface.

  ## Event Categories

  | Prefix            | Lifecycle                        | Description                    |
  |--------------------|----------------------------------|--------------------------------|
  | `[:adk, :runner]`  | start / stop / exception         | Full `Runner.run/4` invocation |
  | `[:adk, :agent]`   | start / stop / exception         | Individual agent execution     |
  | `[:adk, :tool]`    | start / stop / exception         | Tool function calls            |
  | `[:adk, :llm]`     | start / stop / exception         | LLM API calls                  |
  | `[:adk, :session]` | start / stop                     | Session lifecycle              |

  ## Standard Metadata Keys

  Every event includes at minimum:

  - `:agent_name` — name of the active agent
  - `:app_name` — application name from Runner
  - `:session_id` — session identifier

  Event-specific keys:

  - `:model` — LLM model identifier (llm events)
  - `:tool_name` — tool name (tool events)
  - `:user_id` — user identifier (runner/session events)

  ## Measurements

  - **start**: `%{monotonic_time: integer(), system_time: integer()}`
  - **stop**: `%{duration: integer(), monotonic_time: integer()}`
  - **exception**: `%{duration: integer(), monotonic_time: integer()}`

  Exception metadata also includes `:kind`, `:reason`, and `:stacktrace`.

  ## Usage

      # List all events for attaching handlers
      ADK.Telemetry.Contract.all_events()

      # Emit a runner span
      ADK.Telemetry.Contract.runner_span(metadata, fn -> do_work() end)

      # Emit a session span
      ADK.Telemetry.Contract.session_span(metadata, fn -> do_work() end)
  """

  # ── Runner Events ──────────────────────────────────────────────────────

  @runner_start [:adk, :runner, :start]
  @runner_stop [:adk, :runner, :stop]
  @runner_exception [:adk, :runner, :exception]

  # ── Agent Events ───────────────────────────────────────────────────────

  @agent_start [:adk, :agent, :start]
  @agent_stop [:adk, :agent, :stop]
  @agent_exception [:adk, :agent, :exception]

  # ── Tool Events ────────────────────────────────────────────────────────

  @tool_start [:adk, :tool, :start]
  @tool_stop [:adk, :tool, :stop]
  @tool_exception [:adk, :tool, :exception]

  # ── LLM Events ─────────────────────────────────────────────────────────

  @llm_start [:adk, :llm, :start]
  @llm_stop [:adk, :llm, :stop]
  @llm_exception [:adk, :llm, :exception]

  # ── Session Events ─────────────────────────────────────────────────────

  @session_start [:adk, :session, :start]
  @session_stop [:adk, :session, :stop]

  # ── Event Name Accessors ───────────────────────────────────────────────

  @doc "Runner event names."
  def runner_events, do: [@runner_start, @runner_stop, @runner_exception]

  @doc "Agent event names."
  def agent_events, do: [@agent_start, @agent_stop, @agent_exception]

  @doc "Tool event names."
  def tool_events, do: [@tool_start, @tool_stop, @tool_exception]

  @doc "LLM event names."
  def llm_events, do: [@llm_start, @llm_stop, @llm_exception]

  @doc "Session event names."
  def session_events, do: [@session_start, @session_stop]

  @doc """
  Returns all ADK telemetry event names.

  Includes runner, agent, tool, LLM, and session events — 14 total.
  Suitable for use with `:telemetry.attach_many/4`.
  """
  @spec all_events() :: [list(atom())]
  def all_events do
    runner_events() ++ agent_events() ++ tool_events() ++ llm_events() ++ session_events()
  end

  @doc """
  Returns only stop events — useful for metrics/tracing handlers that
  only care about completed operations.
  """
  @spec stop_events() :: [list(atom())]
  def stop_events do
    [
      @runner_stop,
      @agent_stop,
      @tool_stop,
      @llm_stop,
      @session_stop
    ]
  end

  @doc """
  Returns only exception events — useful for error tracking.
  """
  @spec exception_events() :: [list(atom())]
  def exception_events do
    [
      @runner_exception,
      @agent_exception,
      @tool_exception,
      @llm_exception
    ]
  end

  # ── Span Helpers ───────────────────────────────────────────────────────

  @doc """
  Wrap a function in a `[:adk, :runner, ...]` telemetry span.

  ## Required metadata

  - `:app_name` — application name
  - `:agent_name` — root agent name
  - `:session_id` — session identifier
  - `:user_id` — user identifier

  ## Example

      ADK.Telemetry.Contract.runner_span(
        %{app_name: "myapp", agent_name: "bot", session_id: "s1", user_id: "u1"},
        fn -> Runner.run(...) end
      )
  """
  @spec runner_span(map(), (-> term())) :: term()
  def runner_span(metadata, fun) when is_map(metadata) do
    ADK.Telemetry.span([:adk, :runner], metadata, fun)
  end

  @doc """
  Wrap a function in a `[:adk, :session, ...]` telemetry span.

  ## Required metadata

  - `:app_name` — application name
  - `:session_id` — session identifier
  - `:user_id` — user identifier

  ## Example

      ADK.Telemetry.Contract.session_span(
        %{app_name: "myapp", session_id: "s1", user_id: "u1"},
        fn -> start_session(...) end
      )
  """
  @spec session_span(map(), (-> term())) :: term()
  def session_span(metadata, fun) when is_map(metadata) do
    ADK.Telemetry.span([:adk, :session], metadata, fun)
  end

  @doc """
  Wrap a function in a `[:adk, :agent, ...]` telemetry span.

  Delegates to `ADK.Telemetry.span/3` with the agent prefix.
  """
  @spec agent_span(map(), (-> term())) :: term()
  def agent_span(metadata, fun) when is_map(metadata) do
    ADK.Telemetry.span([:adk, :agent], metadata, fun)
  end

  @doc """
  Wrap a function in a `[:adk, :tool, ...]` telemetry span.

  Delegates to `ADK.Telemetry.span/3` with the tool prefix.
  """
  @spec tool_span(map(), (-> term())) :: term()
  def tool_span(metadata, fun) when is_map(metadata) do
    ADK.Telemetry.span([:adk, :tool], metadata, fun)
  end

  @doc """
  Wrap a function in a `[:adk, :llm, ...]` telemetry span.

  Delegates to `ADK.Telemetry.span/3` with the LLM prefix.
  """
  @spec llm_span(map(), (-> term())) :: term()
  def llm_span(metadata, fun) when is_map(metadata) do
    ADK.Telemetry.span([:adk, :llm], metadata, fun)
  end

  # ── Metadata Builders ─────────────────────────────────────────────────

  @doc """
  Build standard metadata map for runner events.

      ADK.Telemetry.Contract.runner_metadata(runner, session_id, user_id)
  """
  @spec runner_metadata(ADK.Runner.t(), String.t(), String.t()) :: map()
  def runner_metadata(%ADK.Runner{} = runner, session_id, user_id) do
    %{
      app_name: runner.app_name,
      agent_name: ADK.Agent.name(runner.agent),
      session_id: session_id,
      user_id: user_id
    }
  end

  @doc """
  Build standard metadata map for session events.
  """
  @spec session_metadata(String.t(), String.t(), String.t()) :: map()
  def session_metadata(app_name, session_id, user_id) do
    %{
      app_name: app_name,
      session_id: session_id,
      user_id: user_id
    }
  end

  @doc """
  Build standard metadata map for agent events.
  """
  @spec agent_metadata(String.t(), String.t(), String.t()) :: map()
  def agent_metadata(agent_name, session_id, app_name \\ "") do
    %{
      agent_name: agent_name,
      session_id: session_id,
      app_name: app_name
    }
  end

  @doc """
  Build standard metadata map for tool events.
  """
  @spec tool_metadata(String.t(), String.t(), String.t()) :: map()
  def tool_metadata(tool_name, agent_name, session_id) do
    %{
      tool_name: tool_name,
      agent_name: agent_name,
      session_id: session_id
    }
  end

  @doc """
  Build standard metadata map for LLM events.
  """
  @spec llm_metadata(String.t(), String.t(), String.t()) :: map()
  def llm_metadata(model, agent_name, session_id) do
    %{
      model: model,
      agent_name: agent_name,
      session_id: session_id
    }
  end
end
