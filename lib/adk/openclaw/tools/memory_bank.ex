defmodule ADK.OpenClaw.Tools.MemoryBank do
  @moduledoc """
  Tools for accessing the Memory Bank (long term memory).
  """

  alias ADK.Tool.FunctionTool

  @doc """
  Returns a tool for reading memory from the store.
  """
  def read_memory do
    FunctionTool.new(:read_memory,
      description: "Read memory by querying the Memory Bank.",
      parameters: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Search query."}
        },
        required: ["query"]
      },
      func: fn ctx, %{"query" => query} ->
        memory_store = (ctx.context && ctx.context.memory_store) || ADK.Memory.InMemory
        {mod, _opts} = normalize_store(memory_store)
        app_name = (ctx.context && ctx.context.app_name) || "openclaw"
        user_id = (ctx.context && ctx.context.user_id) || "user"

        case mod.search(app_name, user_id, query, []) do
          {:ok, []} ->
            {:ok, "No relevant memories found."}

          {:ok, entries} ->
            formatted = Enum.map_join(entries, "\n", &"- [#{&1.id}] #{&1.content}")
            {:ok, formatted}

          {:error, reason} ->
            {:error, "Memory search failed: #{inspect(reason)}"}
        end
      end
    )
  end

  @doc """
  Returns a tool for writing a new memory fact.
  """
  def write_memory do
    FunctionTool.new(:write_memory,
      description: "Write a new fact to the Memory Bank.",
      parameters: %{
        type: "object",
        properties: %{
          content: %{type: "string", description: "The fact to remember."}
        },
        required: ["content"]
      },
      func: fn ctx, %{"content" => content} ->
        memory_store = (ctx.context && ctx.context.memory_store) || ADK.Memory.InMemory
        {mod, _opts} = normalize_store(memory_store)
        app_name = (ctx.context && ctx.context.app_name) || "openclaw"
        user_id = (ctx.context && ctx.context.user_id) || "user"

        entry = %ADK.Memory.Entry{
          id: generate_id(),
          content: content,
          timestamp: DateTime.utc_now()
        }

        case mod.add(app_name, user_id, [entry]) do
          :ok -> {:ok, "Successfully added to Memory Bank with id #{entry.id}."}
          {:error, reason} -> {:error, "Failed to write memory: #{inspect(reason)}"}
        end
      end
    )
  end

  @doc """
  Returns a tool for deleting a specific memory by its ID.
  """
  def memory_forget do
    FunctionTool.new(:memory_forget,
      description: "Delete (forget) a specific memory by its ID.",
      parameters: %{
        type: "object",
        properties: %{
          memory_id: %{type: "string", description: "The ID of the memory to forget."}
        },
        required: ["memory_id"]
      },
      func: fn ctx, %{"memory_id" => id} ->
        memory_store = (ctx.context && ctx.context.memory_store) || ADK.Memory.InMemory
        {mod, _opts} = normalize_store(memory_store)
        app_name = (ctx.context && ctx.context.app_name) || "openclaw"
        user_id = (ctx.context && ctx.context.user_id) || "user"

        case mod.delete(app_name, user_id, id) do
          :ok -> {:ok, "Successfully forgot memory #{id}."}
          {:error, reason} -> {:error, "Failed to forget memory: #{inspect(reason)}"}
        end
      end
    )
  end

  @doc """
  Returns a tool for correcting an existing memory.
  """
  def memory_correct do
    FunctionTool.new(:memory_correct,
      description: "Update/correct a memory's fact text. The old memory is replaced.",
      parameters: %{
        type: "object",
        properties: %{
          memory_id: %{type: "string", description: "The ID of the memory to update."},
          new_fact: %{type: "string", description: "The new fact text."}
        },
        required: ["memory_id", "new_fact"]
      },
      func: fn ctx, %{"memory_id" => id, "new_fact" => new_fact} ->
        memory_store = (ctx.context && ctx.context.memory_store) || ADK.Memory.InMemory
        {mod, _opts} = normalize_store(memory_store)
        app_name = (ctx.context && ctx.context.app_name) || "openclaw"
        user_id = (ctx.context && ctx.context.user_id) || "user"

        # We simulate correct by doing a delete and add (with same id if possible, but the store behaviour add/3 handles ID.
        # ADK.Memory.Store.add/3 takes Entry structs, so we can pass the same ID if the store supports upsert, or delete then add.
        # Let's delete and add to be safe.
        _ = mod.delete(app_name, user_id, id)

        entry = %ADK.Memory.Entry{
          id: id,
          content: new_fact,
          timestamp: DateTime.utc_now()
        }

        case mod.add(app_name, user_id, [entry]) do
          :ok -> {:ok, "Successfully updated memory #{id}."}
          {:error, reason} -> {:error, "Failed to correct memory: #{inspect(reason)}"}
        end
      end
    )
  end

  defp normalize_store({mod, opts}) when is_atom(mod), do: {mod, opts}
  defp normalize_store(mod) when is_atom(mod), do: {mod, []}

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
