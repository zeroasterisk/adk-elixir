defmodule ADK.LLM.Router do
  @moduledoc """
  Smart LLM router with failover across backends/models, exponential backoff,
  and rate-limit awareness.

  The router tries backends in priority order (as configured), skipping those
  that are currently rate-limited or in a circuit-breaker open state. On success,
  it returns immediately. On failure, it falls over to the next backend.

  ## Configuration

  Define a list of backends in priority order. Each entry is a map:

      config :adk, :llm_router, [
        backends: [
          %{
            id: :gemini_pro,
            backend: ADK.LLM.Gemini,
            model: "gemini-2.0-flash",
            priority: 1
          },
          %{
            id: :anthropic_sonnet,
            backend: ADK.LLM.Anthropic,
            model: "claude-sonnet-4-20250514",
            priority: 2
          },
          %{
            id: :openai_gpt4,
            backend: ADK.LLM.OpenAI,
            model: "gpt-4o",
            priority: 3
          }
        ],
        fallback_error: :all_backends_failed
      ]

  ## Usage

      # Use as drop-in via ADK.LLM.generate/3 (set llm_backend to ADK.LLM.Router)
      config :adk, :llm_backend, ADK.LLM.Router

      # Or call directly with an explicit request:
      ADK.LLM.Router.generate("auto", %{messages: msgs})

      # Override backend order per-call:
      ADK.LLM.Router.generate("auto", %{messages: msgs}, backends: [:gemini_pro])

  ## Failover behaviour

  - **Rate limit (429):** Backend is backed off with exponential delay. Retry from
    the next available backend. Backed-off backend re-enters rotation after its
    cool-down elapses.
  - **Circuit breaker:** If a `CircuitBreaker` GenServer is registered for a backend
    id (e.g. `ADK.LLM.Router.CircuitBreaker.gemini_pro`), it is consulted before
    each attempt. Open circuit = skip to next.
  - **Other errors:** Backend is penalised with a short cool-down (10s) and the
    next backend is tried.
  - **All backends exhausted:** Returns `{:error, :all_backends_failed}` (or the
    configured `:fallback_error`).

  ## GenServer state

  `ADK.LLM.Router` starts a GenServer (supervised via `ADK.Application`) to track
  per-backend rate-limit windows. Start it manually when using outside the full
  OTP tree:

      {:ok, _} = ADK.LLM.Router.start_link(name: ADK.LLM.Router)
  """

  @behaviour ADK.LLM

  use GenServer

  require Logger

  # How long to cool down after a rate-limit hit (ms); doubles on repeated hits.
  @default_rate_limit_backoff_ms 5_000
  @max_rate_limit_backoff_ms 300_000

  # Short penalty for non-rate-limit transient errors (ms)
  @transient_error_penalty_ms 10_000

  # ----- Public API -----

  @doc "Start the router GenServer (supervised by ADK.Application)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, nil, name: name)
  end

  @doc """
  Reset all backend rate-limit/cooldown state.
  Useful in tests and after manual intervention.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @doc "Return a snapshot of per-backend penalty state."
  @spec backend_states(GenServer.server()) :: %{atom() => map()}
  def backend_states(server \\ __MODULE__) do
    GenServer.call(server, :get_states)
  end

  @doc """
  Mark a backend as rate-limited, computing its next-available timestamp.
  Called internally after a 429 response.
  """
  @spec record_rate_limited(GenServer.server(), atom()) :: :ok
  def record_rate_limited(server \\ __MODULE__, backend_id) do
    GenServer.cast(server, {:rate_limited, backend_id})
  end

  @doc """
  Mark a backend as having encountered a transient (non-rate-limit) error.
  """
  @spec record_transient_error(GenServer.server(), atom()) :: :ok
  def record_transient_error(server \\ __MODULE__, backend_id) do
    GenServer.cast(server, {:transient_error, backend_id})
  end

  @doc "Mark a backend as having succeeded; clears any penalty."
  @spec record_success(GenServer.server(), atom()) :: :ok
  def record_success(server \\ __MODULE__, backend_id) do
    GenServer.cast(server, {:success, backend_id})
  end

  @doc "Return whether a backend is currently available (not backed off)."
  @spec backend_available?(GenServer.server(), atom()) :: boolean()
  def backend_available?(server \\ __MODULE__, backend_id) do
    GenServer.call(server, {:available?, backend_id})
  end

  # ----- LLM behaviour -----

  @impl ADK.LLM
  @spec generate(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def generate(model, request) do
    generate(model, request, [])
  end

  @doc """
  Generate with optional per-call overrides.

  Options:
    * `:backends` - list of backend ids to restrict this call to (default: all configured)
    * `:server` - GenServer name/pid for penalty tracking (default: `__MODULE__`)
    * `:retry` - Retry options for each individual backend call (default: `[]` — no extra retry layer)
  """
  @spec generate(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(_model, request, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    allowed_ids = Keyword.get(opts, :backends, nil)
    backends = configured_backends()

    backends =
      if allowed_ids do
        Enum.filter(backends, fn b -> b.id in allowed_ids end)
      else
        backends
      end

    backends = Enum.sort_by(backends, & &1.priority)

    do_generate(backends, request, opts, server)
  end

  # ----- GenServer callbacks -----

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{}}
  end

  def handle_call(:get_states, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:available?, id}, _from, state) do
    {:reply, available_now?(state, id), state}
  end

  @impl true
  def handle_cast({:rate_limited, id}, state) do
    existing = Map.get(state, id, default_backend_state())
    new_backoff = min(existing.rl_backoff_ms * 2, @max_rate_limit_backoff_ms)
    now = System.monotonic_time(:millisecond)

    new_state =
      Map.put(state, id, %{
        existing
        | rl_backoff_ms: new_backoff,
          rl_count: existing.rl_count + 1,
          available_at: now + existing.rl_backoff_ms
      })

    Logger.warning(
      "[Router] Backend #{id} rate-limited; cooling down #{existing.rl_backoff_ms}ms"
    )

    {:noreply, new_state}
  end

  def handle_cast({:transient_error, id}, state) do
    now = System.monotonic_time(:millisecond)
    existing = Map.get(state, id, default_backend_state())

    new_state =
      Map.put(state, id, %{existing | available_at: now + @transient_error_penalty_ms})

    Logger.debug(
      "[Router] Backend #{id} transient error; penalty #{@transient_error_penalty_ms}ms"
    )

    {:noreply, new_state}
  end

  def handle_cast({:success, id}, state) do
    existing = Map.get(state, id, default_backend_state())
    # Clear penalties but keep rl_backoff_ms halved (gradual recovery)
    recovered_backoff = max(@default_rate_limit_backoff_ms, div(existing.rl_backoff_ms, 2))

    new_state =
      Map.put(state, id, %{
        existing
        | available_at: nil,
          rl_backoff_ms: recovered_backoff
      })

    {:noreply, new_state}
  end

  # ----- Private helpers -----

  defp do_generate([], _request, opts, _server) do
    fallback =
      Keyword.get(opts, :fallback_error, router_config(:fallback_error, :all_backends_failed))

    {:error, fallback}
  end

  defp do_generate([backend | rest], request, opts, server) do
    # Skip backed-off backends
    unless available_backend?(server, backend.id) do
      Logger.debug("[Router] Skipping #{backend.id} (backed off)")
      do_generate(rest, request, opts, server)
    else
      attempt(backend, request, opts, server, rest)
    end
  end

  defp attempt(backend, request, opts, server, rest) do
    Logger.debug("[Router] Trying backend #{backend.id} (#{backend.backend} / #{backend.model})")

    result = call_backend(backend, request, opts)

    case result do
      {:ok, _} = success ->
        record_success(server, backend.id)
        success

      {:error, :rate_limited} ->
        record_rate_limited(server, backend.id)
        do_generate(rest, request, opts, server)

      {:error, :circuit_open} ->
        Logger.debug("[Router] Backend #{backend.id} circuit open, failing over")
        do_generate(rest, request, opts, server)

      {:error, reason} when reason in [:timeout, :econnrefused, :closed] ->
        record_transient_error(server, backend.id)
        do_generate(rest, request, opts, server)

      {:error, {:api_error, status, _}} when status in [500, 502, 503, 504] ->
        record_transient_error(server, backend.id)
        do_generate(rest, request, opts, server)

      {:error, _} = error ->
        # Non-transient errors (e.g., 401, 403, bad config): do not penalise or retry
        error
    end
  end

  defp call_backend(backend, request, opts) do
    retry_opts = Keyword.get(opts, :retry, false)

    fun = fn -> backend.backend.generate(backend.model, request) end

    fun =
      if retry_opts == false do
        fun
      else
        fn -> ADK.LLM.Retry.with_retry(fun, retry_opts) end
      end

    # If a per-backend CircuitBreaker is registered, use it
    cb_name = cb_name_for(backend.id)

    if Process.whereis(cb_name) do
      ADK.LLM.CircuitBreaker.call(cb_name, fun)
    else
      fun.()
    end
  end

  # Check live penalty state AND optional circuit breaker
  defp available_backend?(server, id) do
    state_available =
      try do
        GenServer.call(server, {:available?, id}, 1_000)
      catch
        :exit, _ -> true
      end

    cb_name = cb_name_for(id)

    cb_available =
      if Process.whereis(cb_name) do
        ADK.LLM.CircuitBreaker.get_state(cb_name) != :open
      else
        true
      end

    state_available and cb_available
  end

  defp available_now?(state, id) do
    case Map.get(state, id) do
      nil -> true
      %{available_at: nil} -> true
      %{available_at: t} -> System.monotonic_time(:millisecond) >= t
    end
  end

  defp cb_name_for(id) do
    Module.concat([ADK.LLM.Router.CircuitBreaker, to_string(id)])
  end

  defp configured_backends do
    router_config(:backends, [])
  end

  defp router_config(key, default) do
    Application.get_env(:adk, :llm_router, [])
    |> Keyword.get(key, default)
  end

  defp default_backend_state do
    %{rl_backoff_ms: @default_rate_limit_backoff_ms, rl_count: 0, available_at: nil}
  end
end
