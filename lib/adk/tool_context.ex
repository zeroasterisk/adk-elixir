defmodule ADK.ToolContext do
  @moduledoc "Context passed to tool execution, wrapping the invocation context."

  @type t :: %__MODULE__{
          context: ADK.Context.t(),
          function_call_id: String.t(),
          tool_name: String.t(),
          tool_def: map() | nil
        }

  defstruct [:context, :function_call_id, :tool_name, :tool_def]

  @doc "Create a tool context from an invocation context."
  def new(%ADK.Context{} = ctx, call_id, tool) do
    %__MODULE__{
      context: ctx,
      function_call_id: call_id,
      tool_name: tool_name(tool),
      tool_def: tool
    }
  end

  defp tool_name(%{name: n}), do: n
  defp tool_name(m) when is_atom(m), do: m.name()
end
