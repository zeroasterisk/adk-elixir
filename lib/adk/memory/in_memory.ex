defmodule ADK.Memory.InMemory do
  @moduledoc """
  ETS-backed in-memory memory store for development and testing.

  Uses keyword matching (not semantic search). Mirrors Python ADK's
  `InMemoryMemoryService`.

  ## Usage

      ADK.Memory.InMemory.start_link([])

      ADK.Memory.InMemory.add("app", "user1", [
        ADK.Memory.Entry.new(content: "User prefers dark mode")
      ])

      {:ok, results} = ADK.Memory.InMemory.search("app", "user1", "dark mode")
  """

  use GenServer

  @behaviour ADK.Memory.Store

  alias ADK.Memory.Entry

  @table __MODULE__

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # --- Store Behaviour ---

  @impl ADK.Memory.Store
  def search(app_name, user_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    query_words = extract_words(query)

    entries =
      lookup_entries(app_name, user_id)
      |> Enum.map(fn entry ->
        score = relevance_score(entry, query_words, query)
        {score, entry}
      end)
      |> Enum.filter(fn {score, _} -> score > 0 end)
      |> Enum.sort_by(fn {score, _} -> score end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {_score, entry} -> entry end)

    {:ok, entries}
  rescue
    ArgumentError -> {:ok, []}
  end

  @impl ADK.Memory.Store
  def add(app_name, user_id, entries) when is_list(entries) do
    key = user_key(app_name, user_id)
    existing = lookup_entries(app_name, user_id)
    existing_ids = MapSet.new(existing, & &1.id)

    new_entries =
      Enum.reject(entries, fn e -> MapSet.member?(existing_ids, e.id) end)

    :ets.insert(@table, {key, existing ++ new_entries})
    :ok
  rescue
    ArgumentError -> {:error, :table_not_available}
  end

  @impl ADK.Memory.Store
  def add_session(app_name, user_id, _session_id, events) do
    entries =
      events
      |> Enum.filter(&has_text_content?/1)
      |> Enum.map(fn event ->
        Entry.new(
          content: extract_text(event),
          author: event.author,
          timestamp: event.timestamp
        )
      end)

    add(app_name, user_id, entries)
  end

  @impl ADK.Memory.Store
  def delete(app_name, user_id, entry_id) do
    key = user_key(app_name, user_id)
    entries = lookup_entries(app_name, user_id)
    filtered = Enum.reject(entries, fn e -> e.id == entry_id end)
    :ets.insert(@table, {key, filtered})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl ADK.Memory.Store
  def clear(app_name, user_id) do
    :ets.delete(@table, user_key(app_name, user_id))
    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public])
    {:ok, %{table: table}}
  end

  # --- Private ---

  defp user_key(app_name, user_id), do: {app_name, user_id}

  defp lookup_entries(app_name, user_id) do
    case :ets.lookup(@table, user_key(app_name, user_id)) do
      [{_key, entries}] -> entries
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  defp extract_words(text) do
    text
    |> String.downcase()
    |> then(&Regex.scan(~r/[a-zA-Z0-9]+/, &1))
    |> List.flatten()
    |> MapSet.new()
  end

  defp relevance_score(%Entry{content: content}, query_words, query) do
    content_lower = String.downcase(content)
    content_words = extract_words(content)

    # Exact substring match bonus
    substring_bonus = if String.contains?(content_lower, String.downcase(query)), do: 5, else: 0

    # Word overlap score
    overlap = MapSet.intersection(query_words, content_words) |> MapSet.size()
    word_score = if MapSet.size(query_words) > 0, do: overlap / MapSet.size(query_words), else: 0

    substring_bonus + word_score
  end

  defp has_text_content?(%ADK.Event{content: %{text: text}}) when is_binary(text) and text != "",
    do: true

  defp has_text_content?(_), do: false

  defp extract_text(%ADK.Event{content: %{text: text}}), do: text
  defp extract_text(%ADK.Event{content: content}) when is_binary(content), do: content
  defp extract_text(_), do: ""
end
