defmodule ADK.Tool.SearchMemoryTool do
  @moduledoc """
  Built-in tool that lets agents search long-term memory.

  Add to an agent's tool list to enable memory search:

      %ADK.Agent.LlmAgent{
        tools: [ADK.Tool.SearchMemoryTool]
      }

  Requires a memory store to be configured in the runner/context.
  """

  @behaviour ADK.Tool

  @impl ADK.Tool
  def name, do: "search_memory"

  @impl ADK.Tool
  def description, do: "Search long-term memory for relevant information from past sessions."

  @impl ADK.Tool
  def parameters do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description: "The search query to find relevant memories."
        }
      },
      required: ["query"]
    }
  end

  @impl ADK.Tool
  def run(%ADK.ToolContext{} = ctx, args) do
    query = Map.get(args, "query", "")
    memory_store = ctx.context && ctx.context.memory_store

    cond do
      is_nil(memory_store) ->
        {:error, "No memory store configured"}

      query == "" ->
        {:error, "Query cannot be empty"}

      true ->
        {mod, _opts} = normalize_store(memory_store)
        app_name = (ctx.context && ctx.context.app_name) || "default"
        user_id = (ctx.context && ctx.context.user_id) || "unknown"

        case mod.search(app_name, user_id, query) do
          {:ok, []} ->
            {:ok, "No relevant memories found."}

          {:ok, entries} ->
            formatted =
              entries
              |> Enum.map_join("\n---\n", fn entry ->
                ts =
                  if entry.timestamp,
                    do: " (#{DateTime.to_iso8601(entry.timestamp)})",
                    else: ""

                author = if entry.author, do: "[#{entry.author}] ", else: ""
                "#{author}#{entry.content}#{ts}"
              end)

            {:ok, formatted}

          {:error, reason} ->
            {:error, "Memory search failed: #{inspect(reason)}"}
        end
    end
  end

  defp normalize_store({mod, opts}) when is_atom(mod), do: {mod, opts}
  defp normalize_store(mod) when is_atom(mod), do: {mod, []}
end
