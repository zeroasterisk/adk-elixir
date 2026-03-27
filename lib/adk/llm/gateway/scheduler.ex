defmodule ADK.LLM.Gateway.Scheduler do
  @moduledoc """
  Priority queue scheduler for LLM Gateway requests.

  ADK Elixir extension — no Python equivalent.

  Sits in front of `Gateway.generate/3` as an optional scheduling layer.
  Manages priority queues per level and dispatches based on available capacity.

  ## Priority Levels

  | Priority | Behavior |
  |----------|----------|
  | `:interactive` | Immediate dispatch, never queued |
  | `:background` | Queued when near rate limits, dispatched during low-usage |
  | `:batch` | Buffered, dispatched during off-peak or on flush |

  ## Example

      {:ok, pid} = Scheduler.start_link(
        dispatch_fn: fn model, request, opts -> {:ok, %{text: "response"}} end,
        drain_interval_ms: 1_000,
        background_threshold: 0.8
      )

      {:ok, response} = Scheduler.submit(pid, "gemini-2.5-pro", %{}, priority: :interactive)
  """

  use GenServer

  require Logger

  @default_drain_interval_ms 5_000
  @default_background_threshold 0.8

  @type priority :: :interactive | :background | :batch

  defmodule Request do
    @moduledoc false
    defstruct [:model, :request, :opts, :from, :submitted_at]
  end

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Submit a request through the scheduler.

  Options:
  - `:priority` - `:interactive` (default), `:background`, or `:batch`
  - `:timeout` - max ms to wait for dispatch (default 30_000)
  """
  @spec submit(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def submit(server, model, request, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(server, {:submit, model, request, opts}, timeout)
  end

  @doc "Returns queue depths per priority level."
  @spec queue_depth(GenServer.server()) :: %{
          interactive: non_neg_integer(),
          background: non_neg_integer(),
          batch: non_neg_integer()
        }
  def queue_depth(server) do
    GenServer.call(server, :queue_depth)
  end

  @doc "Force drain all queues immediately."
  @spec flush(GenServer.server()) :: :ok
  def flush(server) do
    GenServer.call(server, :flush, 30_000)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    drain_interval = Keyword.get(opts, :drain_interval_ms, @default_drain_interval_ms)
    threshold = Keyword.get(opts, :background_threshold, @default_background_threshold)
    default_priority = Keyword.get(opts, :default_priority, :interactive)
    dispatch_fn = Keyword.get(opts, :dispatch_fn, &default_dispatch/3)
    capacity_fn = Keyword.get(opts, :capacity_fn, fn -> 0.0 end)

    state = %{
      background_queue: :queue.new(),
      batch_queue: :queue.new(),
      drain_interval_ms: drain_interval,
      background_threshold: threshold,
      default_priority: default_priority,
      dispatch_fn: dispatch_fn,
      capacity_fn: capacity_fn
    }

    schedule_drain(drain_interval)
    {:ok, state}
  end

  @impl true
  def handle_call({:submit, model, request, opts}, from, state) do
    priority = Keyword.get(opts, :priority, state.default_priority)

    case priority do
      :interactive ->
        # Always dispatch immediately
        result = state.dispatch_fn.(model, request, opts)
        {:reply, result, state}

      :background ->
        usage = state.capacity_fn.()

        if usage < state.background_threshold do
          # Capacity available — dispatch immediately
          result = state.dispatch_fn.(model, request, opts)
          {:reply, result, state}
        else
          # Queue it
          entry = %Request{
            model: model,
            request: request,
            opts: opts,
            from: from,
            submitted_at: System.monotonic_time(:millisecond)
          }

          new_queue = :queue.in(entry, state.background_queue)
          {:noreply, %{state | background_queue: new_queue}}
        end

      :batch ->
        entry = %Request{
          model: model,
          request: request,
          opts: opts,
          from: from,
          submitted_at: System.monotonic_time(:millisecond)
        }

        new_queue = :queue.in(entry, state.batch_queue)
        {:noreply, %{state | batch_queue: new_queue}}
    end
  end

  def handle_call(:queue_depth, _from, state) do
    depths = %{
      interactive: 0,
      background: :queue.len(state.background_queue),
      batch: :queue.len(state.batch_queue)
    }

    {:reply, depths, state}
  end

  def handle_call(:flush, _from, state) do
    state = drain_all(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:drain_queues, state) do
    state = drain_queues(state)
    schedule_drain(state.drain_interval_ms)
    {:noreply, state}
  end

  # -- Private --

  defp drain_queues(state) do
    usage = state.capacity_fn.()

    state =
      if usage < state.background_threshold do
        drain_queue(state, :background_queue)
      else
        state
      end

    # Batch gets drained only when very low usage (< half threshold)
    if usage < state.background_threshold * 0.5 do
      drain_queue(state, :batch_queue)
    else
      state
    end
  end

  defp drain_all(state) do
    state
    |> drain_queue(:background_queue)
    |> drain_queue(:batch_queue)
  end

  defp drain_queue(state, queue_key) do
    queue = Map.fetch!(state, queue_key)
    {new_queue, _dispatched} = do_drain(queue, state.dispatch_fn, :queue.new(), 0)
    Map.put(state, queue_key, new_queue)
  end

  defp do_drain(queue, dispatch_fn, acc, count) do
    case :queue.out(queue) do
      {:empty, _} ->
        {acc, count}

      {{:value, %Request{} = req}, rest} ->
        result = dispatch_fn.(req.model, req.request, req.opts)
        GenServer.reply(req.from, result)
        do_drain(rest, dispatch_fn, acc, count + 1)
    end
  end

  defp schedule_drain(interval_ms) do
    Process.send_after(self(), :drain_queues, interval_ms)
  end

  defp default_dispatch(model, request, opts) do
    ADK.LLM.Gateway.generate(model, request, opts)
  end
end
