defmodule ADK.MCP.ToolAdapter do
  @moduledoc """
  Converts MCP server tools into ADK `FunctionTool` structs.

  Connect to an MCP server, list its tools, and get back ADK-compatible
  tools ready to pass to `LlmAgent`.

  ## Examples

      {:ok, client} = ADK.MCP.Client.start_link(command: "my-mcp-server")
      {:ok, tools} = ADK.MCP.ToolAdapter.to_adk_tools(client)
      # tools are FunctionTool structs — pass them to LlmAgent
      agent = LlmAgent.new(name: "bot", model: "gpt-4", instruction: "Help", tools: tools)
  """

  alias ADK.Tool.FunctionTool

  @doc """
  Fetch tools from an MCP client and convert them to ADK FunctionTools.
  """
  @spec to_adk_tools(GenServer.server()) :: {:ok, [FunctionTool.t()]} | {:error, term()}
  def to_adk_tools(client) do
    case ADK.MCP.Client.list_tools(client) do
      {:ok, %{"tools" => tools}} ->
        {:ok, Enum.map(tools, &to_function_tool(client, &1))}

      {:ok, other} ->
        # Some servers return tools directly as a list
        if is_list(other),
          do: {:ok, Enum.map(other, &to_function_tool(client, &1))},
          else: {:error, {:unexpected, other}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Convert a single MCP tool definition to an ADK FunctionTool.
  """
  @spec to_function_tool(GenServer.server(), map()) :: FunctionTool.t()
  def to_function_tool(client, %{"name" => name} = tool) do
    FunctionTool.new(name,
      description: tool["description"] || "",
      parameters: tool["inputSchema"] || %{},
      func: fn _ctx, args -> call_mcp(client, name, args) end
    )
  end

  defp call_mcp(client, tool_name, args) do
    case ADK.MCP.Client.call_tool(client, tool_name, args) do
      {:ok, %{"isError" => true} = result} ->
        {:error, extract_text(result["content"] || [])}

      {:ok, %{"content" => content}} ->
        {:ok, extract_text(content)}

      {:ok, result} ->
        {:ok, inspect(result)}

      {:error, _} = err ->
        err
    end
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp extract_text(other), do: inspect(other)
end
