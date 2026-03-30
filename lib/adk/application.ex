defmodule ADK.Application do
  @moduledoc """
  OTP Application for ADK.

  ## Supervision Tree

      ADK.Supervisor (rest_for_one)
      ├── ADK.SessionRegistry        — Registry for session lookup by {app, user, session_id}
      ├── ADK.Plugin.Registry        — Agent storing global plugins
      ├── ADK.Auth.InMemoryStore     — Agent for credential storage (dev/test)
      ├── ADK.Artifact.InMemory      — Agent for artifact storage (dev/test)
      ├── ADK.Memory.InMemory        — ETS-backed memory store (dev/test)
      ├── ADK.Session.Store.InMemory — ETS-backed session persistence
      ├── ADK.SessionSupervisor      — DynamicSupervisor for session GenServers
      ├── ADK.RunnerSupervisor       — Task.Supervisor for async agent executions
      ├── ADK.Telemetry.SpanStore    — ETS-backed debug span storage
      ├── ADK.Workflow.Checkpoint.EtsStore — ETS-backed workflow checkpoints
      ├── ADK.Tool.Approval          — GenServer for HITL tool approval (optional)
      ├── ADK.LLM.CircuitBreaker     — Circuit breaker for LLM calls
      └── ADK.LLM.Router             — Smart multi-backend LLM router with failover

  Uses `rest_for_one` because sessions depend on the Registry being alive.
  If the Registry restarts, all sessions must restart to re-register.

  ## Configuration

  Optional application env to control which children start:

      config :adk,
        start_credential_store: true,   # default true
        start_artifact_store: true,     # default true
        start_circuit_breaker: true,    # default true
        start_llm_router: true,         # default true
        start_approval_server: false,   # default false — enable for HITL in server mode
        circuit_breaker: [              # CircuitBreaker options
          failure_threshold: 5,
          reset_timeout_ms: 60_000
        ],
        llm_router: [                   # LLM Router options
          backends: [],
          fallback_error: :all_backends_failed
        ]
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Registry must start first — sessions register here
        {Registry, keys: :unique, name: ADK.SessionRegistry},

        # Plugin registry (Agent)
        ADK.Plugin.Registry,

        # Credential store (optional, for dev/test)
        if(start_child?(:start_credential_store, true),
          do: {ADK.Auth.InMemoryStore, name: ADK.Auth.InMemoryStore}
        ),

        # Artifact store (optional, for dev/test)
        if(start_child?(:start_artifact_store, true),
          do: {ADK.Artifact.InMemory, name: ADK.Artifact.InMemory}
        ),

        # ETS-backed memory store (optional, for dev/test)
        if(start_child?(:start_memory_store, true),
          do: {ADK.Memory.InMemory, name: ADK.Memory.InMemory}
        ),

        # ETS-backed session store
        ADK.Session.Store.InMemory,

        # DynamicSupervisor for session processes
        {DynamicSupervisor,
         name: ADK.SessionSupervisor, strategy: :one_for_one, max_restarts: 10, max_seconds: 5},

        # Task.Supervisor for async runner executions
        {Task.Supervisor, name: ADK.RunnerSupervisor, max_restarts: 20, max_seconds: 10},

        # ETS-backed debug span storage
        ADK.Telemetry.SpanStore,

        # ETS-backed workflow checkpoint store
        ADK.Workflow.Checkpoint.EtsStore,

        # Approval server for HITL tool confirmation (optional)
        if(start_child?(:start_approval_server, false),
          do: {ADK.Tool.Approval, name: ADK.Tool.Approval}
        ),

        # Circuit breaker for LLM calls (optional)
        if(start_child?(:start_circuit_breaker, true),
          do:
            {ADK.LLM.CircuitBreaker,
             Keyword.merge(
               [name: ADK.LLM.CircuitBreaker],
               Application.get_env(:adk, :circuit_breaker, [])
             )}
        ),

        # Smart LLM router with failover (optional)
        if(start_child?(:start_llm_router, true),
          do: {ADK.LLM.Router, name: ADK.LLM.Router}
        )
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :rest_for_one, name: ADK.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Attach debug telemetry handler after supervision tree is up
    ADK.Telemetry.DebugHandler.attach()

    result
  end

  defp start_child?(key, default) do
    Application.get_env(:adk, key, default)
  end
end
