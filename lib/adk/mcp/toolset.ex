# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.MCP.Toolset do
  @moduledoc """
  MCP Toolset — connects to an MCP server via stdio and provides its tools
  as ADK `FunctionTool` structs.

  Implements `ADK.Tool.Toolset` so it can be passed directly in an agent's
  `:tools` list (once toolset resolution is wired into the runner).

  Mirrors Python ADK's `McpToolset` with `StdioConnectionParams`.

  ## Examples

      # Start a toolset connected to a stdio MCP server
      {:ok, toolset} = ADK.MCP.Toolset.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-everything"],
        tool_filter: ["echo", "add"]
      )

      # Get ADK-compatible tools
      {:ok, tools} = ADK.MCP.Toolset.get_tools(toolset)

      # Use tools in an agent
      agent = %ADK.Agent.LlmAgent{
        name: "assistant",
        model: "gemini-2.5-flash",
        instruction: "Help the user",
        tools: tools
      }

      # Clean up when done
      ADK.MCP.Toolset.close(toolset)
  """

  use GenServer

  alias ADK.MCP.Client
  alias ADK.MCP.ToolAdapter

  @type filter :: [String.t()] | (map() -> boolean()) | nil

  @type start_opt ::
          {:command, String.t()}
          | {:args, [String.t()]}
          | {:env, [{String.t(), String.t()}]}
          | {:timeout, pos_integer()}
          | {:tool_filter, filter()}
          | {:name, GenServer.name()}

  # --- Public API ---

  @doc """
  Start a Toolset linked to the calling process.

  Options are forwarded to `ADK.MCP.Client.start_link/1` plus:

  - `:tool_filter` — an optional list of tool names to include, or a
    predicate function `(tool_map -> boolean)`.
  """
  @spec start_link([start_opt]) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, toolset_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, toolset_opts, gen_opts)
  end

  @doc """
  Return the list of ADK `FunctionTool` structs provided by the MCP server.

  Applies the configured `:tool_filter` if one was given at start time.
  """
  @spec get_tools(GenServer.server(), map() | nil) :: {:ok, [ADK.Tool.FunctionTool.t()]} | {:error, term()}
  def get_tools(toolset, _context \\ nil) do
    GenServer.call(toolset, :get_tools, 30_000)
  end

  @doc "Return the auth config (always nil for MCP stdio toolsets)."
  @spec get_auth_config(GenServer.server()) :: nil
  def get_auth_config(_toolset), do: nil

  @doc "Return server info from the MCP initialization handshake."
  @spec server_info(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def server_info(toolset) do
    GenServer.call(toolset, :server_info)
  end

  @doc "Stop the toolset and its underlying MCP client."
  @spec close(GenServer.server()) :: :ok
  def close(toolset) do
    GenServer.stop(toolset, :normal)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    {tool_filter, client_opts} = Keyword.pop(opts, :tool_filter, nil)

    case Client.start_link(client_opts) do
      {:ok, client} ->
        {:ok, %{client: client, tool_filter: tool_filter}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_tools, _from, state) do
    case ToolAdapter.to_adk_tools(state.client) do
      {:ok, tools} ->
        filtered = apply_filter(tools, state.tool_filter)
        {:reply, {:ok, filtered}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:server_info, _from, state) do
    reply = Client.server_info(state.client)
    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.client) do
      Client.close(state.client)
    end

    :ok
  rescue
    _ -> :ok
  end

  # --- Private ---

  defp apply_filter(tools, nil), do: tools

  defp apply_filter(tools, names) when is_list(names) do
    name_set = MapSet.new(names)
    Enum.filter(tools, fn tool -> MapSet.member?(name_set, tool.name) end)
  end

  defp apply_filter(tools, pred) when is_function(pred, 1) do
    Enum.filter(tools, pred)
  end
end
