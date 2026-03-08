defmodule ADK.LLM.CircuitBreaker do
  @moduledoc """
  Simple circuit breaker for LLM calls using GenServer.

  ## States

    * `:closed` — Normal operation, calls pass through
    * `:open` — Too many failures, calls rejected with `{:error, :circuit_open}`
    * `:half_open` — Testing recovery, allows one call through

  ## Options

    * `:name` - GenServer name (default: `__MODULE__`)
    * `:failure_threshold` - Failures before opening (default: 5)
    * `:reset_timeout_ms` - Time in open state before half-open (default: 60_000)

  ## Examples

      {:ok, _} = ADK.LLM.CircuitBreaker.start_link(name: :llm_breaker)
      ADK.LLM.CircuitBreaker.call(:llm_breaker, fn -> some_llm_call() end)
  """

  use GenServer

  @default_failure_threshold 5
  @default_reset_timeout_ms 60_000

  @type t :: %__MODULE__{
          failure_threshold: pos_integer(),
          reset_timeout_ms: pos_integer(),
          state: :closed | :open | :half_open,
          failure_count: non_neg_integer(),
          opened_at: integer() | nil
        }

  defstruct [
    :failure_threshold,
    :reset_timeout_ms,
    state: :closed,
    failure_count: 0,
    opened_at: nil
  ]

  # Client API

  @doc "Start the circuit breaker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    config = %__MODULE__{
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      reset_timeout_ms: Keyword.get(opts, :reset_timeout_ms, @default_reset_timeout_ms)
    }
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @doc """
  Execute `fun` through the circuit breaker.

  Returns `{:error, :circuit_open}` if the circuit is open.
  """
  @spec call(GenServer.server(), (() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def call(server \\ __MODULE__, fun) do
    case GenServer.call(server, :acquire) do
      :ok ->
        result = fun.()
        case result do
          {:ok, _} -> GenServer.cast(server, :record_success)
          {:error, _} -> GenServer.cast(server, :record_failure)
        end
        result

      {:error, :circuit_open} = err ->
        err
    end
  end

  @doc "Get the current state of the circuit breaker."
  @spec get_state(GenServer.server()) :: :closed | :open | :half_open
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @doc "Reset the circuit breaker to closed state."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  # Server callbacks

  @impl true
  def init(config), do: {:ok, config}

  @impl true
  def handle_call(:acquire, _from, %{state: :closed} = s), do: {:reply, :ok, s}

  def handle_call(:acquire, _from, %{state: :open} = s) do
    if timeout_elapsed?(s) do
      {:reply, :ok, %{s | state: :half_open}}
    else
      {:reply, {:error, :circuit_open}, s}
    end
  end

  def handle_call(:acquire, _from, %{state: :half_open} = s) do
    # Only one call allowed in half-open; reject others
    {:reply, {:error, :circuit_open}, s}
  end

  def handle_call(:get_state, _from, %{state: :open} = s) do
    if timeout_elapsed?(s) do
      {:reply, :half_open, s}
    else
      {:reply, :open, s}
    end
  end

  def handle_call(:get_state, _from, s), do: {:reply, s.state, s}

  def handle_call(:reset, _from, s) do
    {:reply, :ok, %{s | state: :closed, failure_count: 0, opened_at: nil}}
  end

  @impl true
  def handle_cast(:record_success, _s = %{state: :half_open} = s) do
    {:noreply, %{s | state: :closed, failure_count: 0, opened_at: nil}}
  end

  def handle_cast(:record_success, s) do
    {:noreply, %{s | failure_count: 0}}
  end

  def handle_cast(:record_failure, %{state: :half_open} = s) do
    {:noreply, %{s | state: :open, opened_at: System.monotonic_time(:millisecond)}}
  end

  def handle_cast(:record_failure, s) do
    new_count = s.failure_count + 1
    if new_count >= s.failure_threshold do
      {:noreply, %{s | state: :open, failure_count: new_count, opened_at: System.monotonic_time(:millisecond)}}
    else
      {:noreply, %{s | failure_count: new_count}}
    end
  end

  defp timeout_elapsed?(%{opened_at: opened_at, reset_timeout_ms: timeout}) do
    System.monotonic_time(:millisecond) - opened_at >= timeout
  end
end
