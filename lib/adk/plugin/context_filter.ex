defmodule ADK.Plugin.ContextFilter do
  @moduledoc """
  A plugin that filters the LLM context to reduce its size.
  """
  @behaviour ADK.Plugin

  @pdict_key {__MODULE__, :config}

  @impl true
  def init(opts) do
    config = %{
      num_invocations_to_keep: Keyword.get(opts, :num_invocations_to_keep),
      custom_filter: Keyword.get(opts, :custom_filter)
    }

    {:ok, config}
  end

  @impl true
  def before_run(context, state) do
    Process.put(@pdict_key, state)
    {:cont, context, state}
  end

  @impl true
  def before_model(_context, request) do
    state = Process.get(@pdict_key)

    if is_nil(state) do
      {:ok, request}
    else
      contents = Map.get(request, :contents, [])

      contents =
        if not is_nil(state.num_invocations_to_keep) and state.num_invocations_to_keep > 0 do
          filter_by_invocations(contents, state.num_invocations_to_keep)
        else
          contents
        end

      contents =
        if is_function(state.custom_filter, 1) do
          try do
            state.custom_filter.(contents)
          rescue
            _ -> contents
          end
        else
          contents
        end

      {:ok, %{request | contents: contents}}
    end
  end

  defp filter_by_invocations(contents, num_to_keep) do
    start_indices = get_invocation_start_indices(contents)

    if length(start_indices) > num_to_keep do
      split_index = Enum.at(start_indices, length(start_indices) - num_to_keep)
      adjusted_index = adjust_split_index_to_avoid_orphaned_responses(contents, split_index)
      Enum.slice(contents, adjusted_index..-1//1)
    else
      contents
    end
  end

  defp get_invocation_start_indices(contents) do
    {indices, _, _} =
      Enum.reduce(contents, {[], false, 0}, fn content, {acc_indices, prev_human, idx} ->
        human = is_human_user_content?(content)

        new_indices =
          if human and not prev_human do
            acc_indices ++ [idx]
          else
            acc_indices
          end

        {new_indices, human, idx + 1}
      end)

    indices
  end

  defp is_human_user_content?(%{role: "user"} = content) do
    not is_function_response_content?(content)
  end

  defp is_human_user_content?(_), do: false

  defp is_function_response_content?(%{parts: parts}) when is_list(parts) do
    Enum.any?(parts, fn part ->
      Map.has_key?(part, :function_response) and not is_nil(part.function_response)
    end)
  end

  defp is_function_response_content?(_), do: false

  defp adjust_split_index_to_avoid_orphaned_responses(contents, split_index) do
    needed_call_ids = MapSet.new()

    # We iterate backwards from the end of the list down to 0
    # We collect function_response ids, and remove them when we see the corresponding function_call.
    # If at `i <= split_index` the needed_call_ids is empty, we return `i`.
    Enum.reduce_while(Enum.reverse(Enum.with_index(contents)), needed_call_ids, fn {content, i},
                                                                                   acc_ids ->
      parts = Map.get(content, :parts, [])

      new_ids =
        Enum.reduce(Enum.reverse(parts), acc_ids, fn part, ids ->
          ids1 =
            if Map.has_key?(part, :function_response) and not is_nil(part.function_response) do
              if Map.has_key?(part.function_response, :id) and
                   not is_nil(part.function_response.id) do
                MapSet.put(ids, part.function_response.id)
              else
                ids
              end
            else
              ids
            end

          ids2 =
            if Map.has_key?(part, :function_call) and not is_nil(part.function_call) do
              if Map.has_key?(part.function_call, :id) and not is_nil(part.function_call.id) do
                MapSet.delete(ids1, part.function_call.id)
              else
                ids1
              end
            else
              ids1
            end

          ids2
        end)

      if i <= split_index and MapSet.size(new_ids) == 0 do
        {:halt, i}
      else
        {:cont, new_ids}
      end
    end)
    |> case do
      i when is_integer(i) -> i
      _ -> 0
    end
  end
end
