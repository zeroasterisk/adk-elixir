defmodule ADK.Tool.Approval do
  @moduledoc """
  GenServer that manages pending human approval requests for tool calls.

  When `ADK.Policy.HumanApproval` intercepts a sensitive tool call, it registers
  a request here and blocks until a decision is made. External actors (CLI, LiveView,
  webhook handlers) call `approve/2` or `deny/3` to resolve pending requests.

  ## Supervision

  Start it in your supervision tree or via `Application` config:

      # In your Supervisor:
      {ADK.Tool.Approval, name: ADK.Tool.Approval}

      # Or via ADK application config (starts with default name):
      config :adk, start_approval_server: true

  ## Usage

      # From a policy (internal — use ADK.Policy.HumanApproval instead):
      {request_id, request} = ADK.Tool.Approval.register("shell_command", %{"command" => "rm -rf /"})
      decision = ADK.Tool.Approval.await(request_id, 60_000)
      # => :allow | {:deny, reason}

      # From a LiveView or CLI handler:
      ADK.Tool.Approval.approve(request_id)
      ADK.Tool.Approval.deny(request_id, "User clicked No")

      # List pending (for a LiveView dashboard):
      requests = ADK.Tool.Approval.list_pending()
      # => [%{id: ..., tool_name: ..., args: ..., requested_at: ...}]
  """

  use GenServer

  @default_name __MODULE__

  defstruct pending: %{}

  @type request :: %{
          id: String.t(),
          tool_name: String.t(),
          args: map(),
          requested_at: DateTime.t()
        }

  @doc "Start the Approval server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Register a new approval request. Returns `{request_id, request_map}`.

  Called by `ADK.Policy.HumanApproval` before blocking on `await/3`.
  """
  @spec register(atom() | pid(), String.t(), map()) :: {String.t(), request()}
  def register(server \\ @default_name, tool_name, args) do
    request_id =
      "approval-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    request = %{
      id: request_id,
      tool_name: tool_name,
      args: args,
      requested_at: DateTime.utc_now()
    }

    :ok = GenServer.call(server, {:register, request_id, request})
    {request_id, request}
  end

  @doc """
  Block the calling process until `request_id` is approved, denied, or times out.

  Returns:
  - `:allow` — request was approved
  - `{:deny, reason}` — request was denied or timed out
  """
  @spec await(atom() | pid(), String.t(), pos_integer()) ::
          :allow | {:deny, String.t()}
  def await(server \\ @default_name, request_id, timeout_ms \\ 60_000) do
    :ok = GenServer.call(server, {:subscribe, request_id, self()})

    receive do
      {:approval_decision, ^request_id, decision} -> decision
    after
      timeout_ms ->
        GenServer.cast(server, {:remove, request_id})
        {:deny, "Approval timed out after #{div(timeout_ms, 1000)} seconds"}
    end
  end

  @doc "Approve a pending request by ID."
  @spec approve(atom() | pid(), String.t()) :: :ok | {:error, :not_found}
  def approve(server \\ @default_name, request_id) do
    GenServer.call(server, {:decide, request_id, :allow})
  end

  @doc "Deny a pending request by ID with an optional reason."
  @spec deny(atom() | pid(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def deny(server \\ @default_name, request_id, reason \\ "User denied") do
    GenServer.call(server, {:decide, request_id, {:deny, reason}})
  end

  @doc "List all pending (unresolved) approval requests."
  @spec list_pending(atom() | pid()) :: [request()]
  def list_pending(server \\ @default_name) do
    GenServer.call(server, :list_pending)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register, request_id, request}, _from, state) do
    entry = %{request: request, waiter: nil}
    updated = Map.put(state.pending, request_id, entry)
    {:reply, :ok, %{state | pending: updated}}
  end

  def handle_call({:subscribe, request_id, waiter_pid}, _from, state) do
    updated =
      Map.update(state.pending, request_id, %{request: %{id: request_id}, waiter: waiter_pid}, fn entry ->
        %{entry | waiter: waiter_pid}
      end)

    {:reply, :ok, %{state | pending: updated}}
  end

  def handle_call({:decide, request_id, decision}, _from, state) do
    case Map.get(state.pending, request_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{waiter: nil} ->
        # Waiter hasn't subscribed yet — remove the pending entry.
        # Edge case: the decision arrived before await/3 subscribed.
        {:reply, :ok, %{state | pending: Map.delete(state.pending, request_id)}}

      %{waiter: waiter_pid} ->
        send(waiter_pid, {:approval_decision, request_id, decision})
        {:reply, :ok, %{state | pending: Map.delete(state.pending, request_id)}}
    end
  end

  def handle_call(:list_pending, _from, state) do
    requests = state.pending |> Map.values() |> Enum.map(& &1.request)
    {:reply, requests, state}
  end

  @impl true
  def handle_cast({:remove, request_id}, state) do
    {:noreply, %{state | pending: Map.delete(state.pending, request_id)}}
  end
end
