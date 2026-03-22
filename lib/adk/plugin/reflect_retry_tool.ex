defmodule ADK.Plugin.ReflectRetryTool do
  @moduledoc """
  Provides self-healing, concurrent-safe error recovery for tool failures.
  """

  @behaviour ADK.Plugin

  @response_type "ERROR_HANDLED_BY_REFLECT_AND_RETRY_PLUGIN"
  @default_max_retries 3

  @impl true
  def init(opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    throw_exception = Keyword.get(opts, :throw_exception_if_retry_exceeded, true)
    extract_error = Keyword.get(opts, :extract_error_from_result)

    {:ok,
     %{
       max_retries: max_retries,
       throw_exception_if_retry_exceeded: throw_exception,
       extract_error_from_result: extract_error
     }}
  end

  @impl true
  def before_run(context, state) do
    # Scoped to invocation_id to allow concurrent runners in the same process
    # Though usually Runners run in their own process, this makes it safer.
    scope = get_scope_key(context)
    Process.put({__MODULE__, :config, scope}, state)
    Process.put({__MODULE__, :retry_counts, scope}, %{})
    {:cont, context, state}
  end

  @impl true
  def after_run(events, context, state) do
    scope = get_scope_key(context)
    Process.delete({__MODULE__, :config, scope})
    Process.delete({__MODULE__, :retry_counts, scope})
    {events, state}
  end

  @impl true
  def after_tool(ctx, tool_name, result) do
    scope = get_scope_key(ctx)
    config = Process.get({__MODULE__, :config, scope})

    # In ADK Elixir, result is {:ok, val} or {:error, val}.
    # Wait, the tool has succeeded if we are in after_tool, but sometimes people return {:error, _} from tools.
    # The Runner intercepts {:error, _} in execute_tools and calls `on_tool_error` callback BEFORE `after_tool`.
    # So if `after_tool` is called with `{:ok, val}`, it means it was a success.
    # We should unpack `{:ok, val}` for `extract_error_from_result`.
    unwrapped =
      case result do
        {:ok, val} -> val
        other -> other
      end

    if is_map(unwrapped) and Map.get(unwrapped, "response_type") == @response_type do
      result
    else
      error =
        if config && is_function(config.extract_error_from_result, 3) do
          config.extract_error_from_result.(ctx, tool_name, unwrapped)
        else
          nil
        end

      if error do
        handle_tool_error(ctx, tool_name, error, config)
      else
        reset_failures(scope, tool_name)
        result
      end
    end
  end

  @impl true
  def on_tool_error(ctx, tool_name, {:error, error}) do
    scope = get_scope_key(ctx)
    config = Process.get({__MODULE__, :config, scope})

    if config do
      handle_tool_error(ctx, tool_name, error, config)
    else
      {:error, error}
    end
  end

  def get_scope_key(ctx) do
    ctx.invocation_id || "global"
  end

  defp handle_tool_error(ctx, tool_name, error, config) do
    scope = get_scope_key(ctx)

    if config.max_retries == 0 do
      if config.throw_exception_if_retry_exceeded do
        do_raise(error)
      else
        {:ok, build_exceeded_msg(tool_name, error, config.max_retries)}
      end
    else
      counts = Process.get({__MODULE__, :retry_counts, scope}) || %{}
      current = Map.get(counts, tool_name, 0) + 1
      Process.put({__MODULE__, :retry_counts, scope}, Map.put(counts, tool_name, current))

      if current <= config.max_retries do
        {:ok, build_reflection_msg(tool_name, error, current, config.max_retries)}
      else
        if config.throw_exception_if_retry_exceeded do
          do_raise(error)
        else
          {:ok, build_exceeded_msg(tool_name, error, config.max_retries)}
        end
      end
    end
  end

  defp reset_failures(scope, tool_name) do
    counts = Process.get({__MODULE__, :retry_counts, scope}) || %{}
    Process.put({__MODULE__, :retry_counts, scope}, Map.delete(counts, tool_name))
  end

  defp do_raise(error) when is_exception(error), do: raise(error)
  defp do_raise(error), do: raise(RuntimeError, inspect(error))

  defp build_reflection_msg(tool_name, error, current_retry, max_retries) do
    error_str = format_error(error)

    guidance =
      """
      The call to tool `#{tool_name}` failed.

      **Error Details:**
      ```
      #{error_str}
      ```

      **Reflection Guidance:**
      This is retry attempt **#{current_retry} of #{max_retries}**. Analyze the error and the arguments you provided. Do not repeat the exact same call. Consider the following before your next attempt:

      1.  **Invalid Parameters**: Does the error suggest that one or more arguments are incorrect, badly formatted, or missing? Review the tool's schema and your arguments.
      2.  **State or Preconditions**: Did a previous step fail or not produce the necessary state/resource for this tool to succeed?
      3.  **Alternative Approach**: Is this the right tool for the job? Could another tool or a different sequence of steps achieve the goal?
      4.  **Simplify the Task**: Can you break the problem down into smaller, simpler steps?
      5.  **Wrong Function Name**: Does the error indicates the tool is not found? Please check again and only use available tools.

      Formulate a new plan based on your analysis and try a corrected or different approach.
      """
      |> String.trim()

    %{
      "response_type" => @response_type,
      "error_type" => error_type(error),
      "error_details" => error_str,
      "retry_count" => current_retry,
      "reflection_guidance" => guidance
    }
  end

  defp build_exceeded_msg(tool_name, error, max_retries) do
    error_str = format_error(error)

    guidance =
      """
      The tool `#{tool_name}` has failed consecutively #{max_retries} times and the retry limit has been exceeded.

      **Last Error:**
      ```
      #{error_str}
      ```

      **Final Instruction:**
      **Do not attempt to use the `#{tool_name}` tool again for this task.** You must now try a different approach. Acknowledge the failure and devise a new strategy, potentially using other available tools or informing the user that the task cannot be completed.
      """
      |> String.trim()

    %{
      "response_type" => @response_type,
      "error_type" => error_type(error),
      "error_details" => error_str,
      "retry_count" => max_retries,
      "reflection_guidance" => guidance
    }
  end

  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp error_type(error) when is_exception(error), do: inspect(error.__struct__)
  defp error_type(_error), do: "ToolError"
end
