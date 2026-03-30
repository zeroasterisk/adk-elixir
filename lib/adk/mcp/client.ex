defmodule ADK.MCP.Client do
  @moduledoc """
  MCP (Model Context Protocol) client over stdio transport.

  Launches an MCP server as a subprocess, performs JSON-RPC initialization,
  and exposes `list_tools/1` and `call_tool/3` for protocol interaction.

  ## Examples

      {:ok, client} = ADK.MCP.Client.start_link(command: "npx", args: ["-y", "@modelcontextprotocol/server-everything"])
      {:ok, tools} = ADK.MCP.Client.list_tools(client)
      {:ok, result} = ADK.MCP.Client.call_tool(client, "echo", %{"message" => "hello"})
  """

  use GenServer

  require Logger

  @protocol_version "2025-03-26"
  @default_timeout 30_000

  # --- Public API ---

  @type start_opt ::
          {:command, String.t()}
          | {:args, [String.t()]}
          | {:env, [{String.t(), String.t()}]}
          | {:name, GenServer.name()}
          | {:timeout, pos_integer()}

  @spec start_link([start_opt]) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, client_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, client_opts, gen_opts)
  end

  @doc "List tools available on the MCP server."
  @spec list_tools(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(client) do
    GenServer.call(client, :list_tools, @default_timeout)
  end

  @doc "Call a tool on the MCP server."
  @spec call_tool(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call_tool(client, tool_name, arguments \\ %{}) do
    GenServer.call(client, {:call_tool, tool_name, arguments}, @default_timeout)
  end

  @doc "Get server info from the initialization response."
  @spec server_info(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def server_info(client) do
    GenServer.call(client, :server_info)
  end

  @doc "Stop the client and terminate the subprocess."
  @spec close(GenServer.server()) :: :ok
  def close(client) do
    GenServer.stop(client, :normal)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])

    port =
      Port.open({:spawn_executable, find_executable(command)}, [
        :binary,
        :exit_status,
        {:args, args},
        {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)},
        {:line, 1_048_576}
      ])

    state = %{
      port: port,
      request_id: 1,
      pending: %{},
      buffer: "",
      server_info: nil,
      server_capabilities: nil
    }

    # Perform initialization handshake
    case do_initialize(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        Port.close(port)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list_tools, from, state) do
    {id, state} = next_id(state)
    request = jsonrpc_request(id, "tools/list", %{})
    state = send_request(state, id, from, request)
    {:noreply, state}
  end

  def handle_call({:call_tool, name, args}, from, state) do
    {id, state} = next_id(state)
    request = jsonrpc_request(id, "tools/call", %{"name" => name, "arguments" => args})
    state = send_request(state, id, from, request)
    {:noreply, state}
  end

  def handle_call(:server_info, _from, state) do
    {:reply, {:ok, state.server_info || %{}}, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, msg} ->
        {:noreply, handle_message(msg, state)}

      {:error, _} ->
        Logger.debug("[MCP.Client] Non-JSON line from server: #{line}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    # Reply error to all pending requests
    for {_id, from} <- state.pending do
      GenServer.reply(from, {:error, {:server_exit, code}})
    end

    {:stop, {:server_exit, code}, %{state | pending: %{}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  # --- Private ---

  defp do_initialize(state) do
    {id, state} = next_id(state)

    request =
      jsonrpc_request(id, "initialize", %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "ADK Elixir", "version" => "0.1.0"}
      })

    send_line(state.port, request)

    case wait_for_response(state.port, id, 10_000) do
      {:ok, result, state_updates} ->
        # Send initialized notification
        notification =
          Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

        send_line(state.port, notification)

        {:ok,
         state
         |> Map.merge(state_updates)
         |> Map.put(:server_info, result["serverInfo"])
         |> Map.put(:server_capabilities, result["capabilities"])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_response(port, expected_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(port, expected_id, deadline)
  end

  defp do_wait(port, expected_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          case Jason.decode(line) do
            {:ok, %{"id" => ^expected_id, "result" => result}} ->
              {:ok, result, %{}}

            {:ok, %{"id" => ^expected_id, "error" => error}} ->
              {:error, error}

            _ ->
              do_wait(port, expected_id, deadline)
          end

        {^port, {:data, {:noeol, _chunk}}} ->
          do_wait(port, expected_id, deadline)

        {^port, {:exit_status, code}} ->
          {:error, {:server_exit, code}}
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp handle_message(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {from, pending} ->
        GenServer.reply(from, {:ok, result})
        %{state | pending: pending}
    end
  end

  defp handle_message(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {from, pending} ->
        GenServer.reply(from, {:error, error})
        %{state | pending: pending}
    end
  end

  defp handle_message(_msg, state), do: state

  defp send_request(state, id, from, request) do
    send_line(state.port, request)
    %{state | pending: Map.put(state.pending, id, from)}
  end

  defp send_line(port, data) when is_binary(data) do
    Port.command(port, [data, "\n"])
  end

  defp send_line(port, data) when is_map(data) do
    send_line(port, Jason.encode!(data))
  end

  defp next_id(%{request_id: id} = state) do
    {id, %{state | request_id: id + 1}}
  end

  defp jsonrpc_request(id, method, params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> raise "MCP server executable not found: #{command}"
      path -> path
    end
  end
end
