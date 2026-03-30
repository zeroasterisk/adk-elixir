defmodule ADK.LLM.Gateway do
  @moduledoc """
  Multi-key LLM provider management with key pooling, stats, and failover.

  ADK Elixir extension — no Python equivalent.

  Implements `ADK.LLM` behaviour so it can be used as a drop-in replacement:

      config :adk, :llm_backend, ADK.LLM.Gateway

  The Gateway supervises KeyPools (one per backend) and a Stats collector,
  routing requests through the existing `ADK.LLM.Router` with auth injection.
  """

  use Supervisor

  @behaviour ADK.LLM

  alias ADK.LLM.Gateway.{Auth, Config, KeyPool, Stats}

  require Logger

  # -- Supervisor --

  @spec start_link(keyword() | Config.t()) :: Supervisor.on_start()
  def start_link(config) when is_list(config) do
    start_link(Config.from_keyword(config))
  end

  def start_link(%Config{} = config) do
    Config.validate!(config)
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl Supervisor
  def init(%Config{backends: backends}) do
    pool_children =
      Enum.map(backends, fn backend ->
        keys = List.wrap(backend.auth)
        strategy = Map.get(backend, :pool_strategy, :round_robin)
        pool_name = pool_name(backend.id)

        %{
          id: pool_name,
          start: {KeyPool, :start_link, [[keys: keys, strategy: strategy, name: pool_name]]}
        }
      end)

    stats_child = %{
      id: Stats,
      start: {Stats, :start_link, [[name: Stats]]}
    }

    # Store config in persistent_term for fast access
    :persistent_term.put({__MODULE__, :config}, backends)

    children = [stats_child | pool_children]
    Supervisor.init(children, strategy: :one_for_one)
  end

  # -- ADK.LLM behaviour --

  @impl ADK.LLM
  @spec generate(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def generate(model, request) do
    generate(model, request, [])
  end

  @doc "Generate with per-call overrides."
  @spec generate(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate(model, request, opts) do
    backends = get_backends()
    target_backend = Keyword.get(opts, :backend)

    backends =
      if target_backend do
        Enum.filter(backends, &(&1.id == target_backend))
      else
        backends
      end
      |> Enum.sort_by(&Map.get(&1, :priority, 1))

    do_generate(backends, model, request, opts)
  end

  # -- Management API --

  @spec health_check() :: map()
  def health_check do
    backends = get_backends()

    Map.new(backends, fn backend ->
      pool = pool_name(backend.id)

      key_status =
        case KeyPool.next_key(pool) do
          {:ok, {idx, auth}} ->
            KeyPool.record_success(pool, idx)
            if Auth.resolved?(auth), do: :ok, else: :auth_not_resolved

          {:error, reason} ->
            reason
        end

      {backend.id, %{status: key_status, backend: backend.backend, model: backend.model}}
    end)
  end

  @spec stats() :: map()
  def stats, do: Stats.get_all_stats()

  @spec add_backend(map()) :: :ok | {:error, term()}
  def add_backend(backend_config) do
    keys = List.wrap(backend_config.auth)
    strategy = Map.get(backend_config, :pool_strategy, :round_robin)
    pool_name = pool_name(backend_config.id)

    spec = %{
      id: pool_name,
      start: {KeyPool, :start_link, [[keys: keys, strategy: strategy, name: pool_name]]}
    }

    case Supervisor.start_child(__MODULE__, spec) do
      {:ok, _} ->
        backends = get_backends()
        :persistent_term.put({__MODULE__, :config}, backends ++ [backend_config])
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec remove_backend(atom()) :: :ok | {:error, term()}
  def remove_backend(id) do
    pool_name = pool_name(id)

    case Supervisor.terminate_child(__MODULE__, pool_name) do
      :ok ->
        Supervisor.delete_child(__MODULE__, pool_name)
        backends = get_backends() |> Enum.reject(&(&1.id == id))
        :persistent_term.put({__MODULE__, :config}, backends)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Private --

  defp do_generate([], _model, _request, _opts) do
    {:error, :all_backends_failed}
  end

  defp do_generate([backend | rest], model, request, opts) do
    pool = pool_name(backend.id)

    case KeyPool.next_key(pool) do
      {:ok, {key_idx, auth}} ->
        _resolved_auth =
          case Auth.resolve(auth) do
            {:ok, resolved} -> resolved
            {:error, _} -> auth
          end

        use_model = if model == "auto", do: backend.model, else: model
        start = System.monotonic_time(:millisecond)
        result = backend.backend.generate(use_model, request)
        latency = System.monotonic_time(:millisecond) - start

        case result do
          {:ok, response} ->
            KeyPool.record_success(pool, key_idx)
            tokens = extract_tokens(response)
            KeyPool.record_usage(pool, key_idx, %{tokens: tokens})

            Stats.record_request(backend.id, key_idx, %{
              latency_ms: latency,
              tokens_in: 0,
              tokens_out: tokens,
              status: :ok
            })

            {:ok, response}

          {:error, :rate_limited} ->
            KeyPool.record_rate_limited(pool, key_idx)

            Stats.record_request(backend.id, key_idx, %{
              latency_ms: latency,
              tokens_in: 0,
              tokens_out: 0,
              status: :rate_limited
            })

            # Try next key in same pool, or fall through to next backend
            do_generate(rest, model, request, opts)

          {:error, _} ->
            Stats.record_request(backend.id, key_idx, %{
              latency_ms: latency,
              tokens_in: 0,
              tokens_out: 0,
              status: :error
            })

            # Try next backend
            do_generate(rest, model, request, opts)
        end

      {:error, :all_keys_rate_limited} ->
        do_generate(rest, model, request, opts)
    end
  end

  defp extract_tokens(%{usage_metadata: %{candidates_token_count: c}}), do: c
  defp extract_tokens(_), do: 0

  defp pool_name(backend_id) do
    Module.concat([__MODULE__, KeyPool, Atom.to_string(backend_id) |> Macro.camelize()])
  end

  defp get_backends do
    :persistent_term.get({__MODULE__, :config}, [])
  end
end
