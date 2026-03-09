defmodule ADK.Application do
  @moduledoc """
  OTP Application for ADK.

  ## Supervision Tree

      ADK.Supervisor (rest_for_one)
      ├── ADK.SessionRegistry        — Registry for session lookup by {app, user, session_id}
      ├── ADK.Plugin.Registry        — Agent storing global plugins
      ├── ADK.Auth.InMemoryStore     — Agent for credential storage (dev/test)
      ├── ADK.Artifact.InMemory      — Agent for artifact storage (dev/test)
      ├── ADK.Session.Store.InMemory — ETS-backed session persistence
      ├── ADK.SessionSupervisor      — DynamicSupervisor for session GenServers
      ├── ADK.RunnerSupervisor       — Task.Supervisor for async agent executions
      └── ADK.LLM.CircuitBreaker     — Circuit breaker for LLM calls

  Uses `rest_for_one` because sessions depend on the Registry being alive.
  If the Registry restarts, all sessions must restart to re-register.

  ## Configuration

  Optional application env to control which children start:

      config :adk,
        start_credential_store: true,   # default true
        start_artifact_store: true,     # default true
        start_circuit_breaker: true,    # default true
        circuit_breaker: [              # CircuitBreaker options
          failure_threshold: 5,
          reset_timeout_ms: 60_000
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

        # ETS-backed session store
        ADK.Session.Store.InMemory,

        # DynamicSupervisor for session processes
        {DynamicSupervisor,
         name: ADK.SessionSupervisor,
         strategy: :one_for_one,
         max_restarts: 10,
         max_seconds: 5},

        # Task.Supervisor for async runner executions
        {Task.Supervisor,
         name: ADK.RunnerSupervisor,
         max_restarts: 20,
         max_seconds: 10},

        # Circuit breaker for LLM calls (optional)
        if(start_child?(:start_circuit_breaker, true),
          do:
            {ADK.LLM.CircuitBreaker,
             Keyword.merge(
               [name: ADK.LLM.CircuitBreaker],
               Application.get_env(:adk, :circuit_breaker, [])
             )}
        )
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :rest_for_one, name: ADK.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp start_child?(key, default) do
    Application.get_env(:adk, key, default)
  end
end
