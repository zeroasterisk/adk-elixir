defmodule ADK.LLM.Gateway.Budget do
  @moduledoc """
  Token budget tracking and enforcement for LLM Gateway requests.

  ADK Elixir extension — no Python equivalent.

  Tracks token usage per named budget with configurable limits and periods.
  Daily budgets auto-reset at midnight UTC.

  ## Example

      budgets = [
        %{name: :default, max_total_tokens: 1_000_000, period: :daily},
        %{name: :eval, max_total_tokens: 10_000_000, period: :lifetime}
      ]

      {:ok, pid} = Budget.start_link(budgets: budgets)
      :ok = Budget.check(pid, :default, 500)
      :ok = Budget.record(pid, :default, 480)
  """

  use GenServer

  @type budget_config :: %{
          name: atom(),
          max_total_tokens: pos_integer(),
          period: :session | :daily | :lifetime
        }

  @type status :: %{
          used: non_neg_integer(),
          remaining: non_neg_integer(),
          max: pos_integer(),
          period: :session | :daily | :lifetime
        }

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    budgets = Keyword.get(opts, :budgets, [])
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, budgets, gen_opts)
  end

  @doc "Check if a request with estimated_tokens would exceed the budget."
  @spec check(GenServer.server(), atom(), non_neg_integer()) ::
          :ok | {:error, :budget_exceeded} | {:error, :unknown_budget}
  def check(server, name, estimated_tokens) do
    GenServer.call(server, {:check, name, estimated_tokens})
  end

  @doc "Record actual token usage against a budget."
  @spec record(GenServer.server(), atom(), non_neg_integer()) :: :ok | {:error, :unknown_budget}
  def record(server, name, actual_tokens) do
    GenServer.call(server, {:record, name, actual_tokens})
  end

  @doc "Get current status for a named budget."
  @spec status(GenServer.server(), atom()) :: {:ok, status()} | {:error, :unknown_budget}
  def status(server, name) do
    GenServer.call(server, {:status, name})
  end

  @doc "Reset a single budget's usage to zero."
  @spec reset(GenServer.server(), atom()) :: :ok | {:error, :unknown_budget}
  def reset(server, name) do
    GenServer.call(server, {:reset, name})
  end

  @doc "Reset all budgets."
  @spec reset_all(GenServer.server()) :: :ok
  def reset_all(server) do
    GenServer.call(server, :reset_all)
  end

  # -- GenServer callbacks --

  @impl true
  def init(budget_configs) do
    state =
      Map.new(budget_configs, fn %{name: name, max_total_tokens: max, period: period} ->
        {name, %{used: 0, max: max, period: period}}
      end)

    schedule_daily_reset(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:check, name, estimated_tokens}, _from, state) do
    case Map.get(state, name) do
      nil ->
        {:reply, {:error, :unknown_budget}, state}

      %{used: used, max: max} ->
        if used + estimated_tokens <= max do
          {:reply, :ok, state}
        else
          {:reply, {:error, :budget_exceeded}, state}
        end
    end
  end

  def handle_call({:record, name, actual_tokens}, _from, state) do
    case Map.get(state, name) do
      nil ->
        {:reply, {:error, :unknown_budget}, state}

      %{} = budget ->
        new_state = Map.put(state, name, %{budget | used: budget.used + actual_tokens})
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:status, name}, _from, state) do
    case Map.get(state, name) do
      nil ->
        {:reply, {:error, :unknown_budget}, state}

      %{used: used, max: max, period: period} ->
        {:reply, {:ok, %{used: used, remaining: max(0, max - used), max: max, period: period}},
         state}
    end
  end

  def handle_call({:reset, name}, _from, state) do
    case Map.get(state, name) do
      nil ->
        {:reply, {:error, :unknown_budget}, state}

      %{} = budget ->
        {:reply, :ok, Map.put(state, name, %{budget | used: 0})}
    end
  end

  def handle_call(:reset_all, _from, state) do
    new_state = Map.new(state, fn {name, budget} -> {name, %{budget | used: 0}} end)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:daily_reset, state) do
    new_state =
      Map.new(state, fn
        {name, %{period: :daily} = budget} -> {name, %{budget | used: 0}}
        entry -> entry
      end)

    schedule_daily_reset(new_state)
    {:noreply, new_state}
  end

  # -- Private --

  defp schedule_daily_reset(state) do
    has_daily? = Enum.any?(state, fn {_name, %{period: period}} -> period == :daily end)

    if has_daily? do
      ms_until_midnight = ms_until_next_midnight()
      Process.send_after(self(), :daily_reset, ms_until_midnight)
    end
  end

  defp ms_until_next_midnight do
    now = DateTime.utc_now()

    midnight =
      now
      |> DateTime.to_date()
      |> Date.add(1)
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    DateTime.diff(midnight, now, :millisecond)
  end
end
