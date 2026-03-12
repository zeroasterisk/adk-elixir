defmodule ADK.Policy do
  @moduledoc """
  Policy behaviour for agent governance — tool access control, content filtering, etc.

  Policies are checked at key points in the agent pipeline:

  - `authorize_tool/3` — before a tool executes, decides allow/deny
  - `filter_input/2` — filters user input before it reaches the LLM
  - `filter_output/2` — filters agent output events before they're returned

  ## Usage

      defmodule MyPolicy do
        @behaviour ADK.Policy

        @impl true
        def authorize_tool(%{name: "dangerous_tool"}, _args, _ctx), do: {:deny, "forbidden"}
        def authorize_tool(_tool, _args, _ctx), do: :allow

        @impl true
        def filter_input(content, _ctx), do: {:cont, content}

        @impl true
        def filter_output(events, _ctx), do: events
      end

      # Pass policies to Runner.run/5
      ADK.Runner.run(runner, user_id, session_id, message, policies: [MyPolicy])

  ## Composition

  Multiple policies are composed as a chain of responsibility:

  - `authorize_tool` — first `:deny` wins; all must allow
  - `filter_input` — chained sequentially; first `{:halt, events}` short-circuits
  - `filter_output` — chained sequentially, each transforms the events
  """

  @type tool_decision :: :allow | {:deny, String.t()}

  @doc "Authorize a tool call. Return `:allow` or `{:deny, reason}`."
  @callback authorize_tool(tool :: map(), args :: map(), ctx :: ADK.Context.t()) :: tool_decision()

  @doc "Filter user input before the LLM sees it. Return `{:cont, content}` or `{:halt, [ADK.Event.t()]}`."
  @callback filter_input(content :: map(), ctx :: ADK.Context.t()) ::
              {:cont, map()} | {:halt, [ADK.Event.t()]}

  @doc "Filter output events before they're returned. Returns transformed events."
  @callback filter_output([ADK.Event.t()], ADK.Context.t()) :: [ADK.Event.t()]

  @optional_callbacks [authorize_tool: 3, filter_input: 2, filter_output: 2]

  @doc """
  Run `authorize_tool` across a list of policies. First deny wins.

  Supports both module-based policies (atoms implementing the `ADK.Policy` behaviour)
  and struct-based policies (e.g., `%ADK.Policy.HumanApproval{}`). Struct policies
  must implement a `check/4` function for per-instance configuration.
  """
  @spec check_tool_authorization([module() | struct()], map(), map(), ADK.Context.t()) ::
          tool_decision()
  def check_tool_authorization(policies, tool, args, ctx) do
    Enum.reduce_while(policies, :allow, fn policy, :allow ->
      case resolve_policy_decision(policy, tool, args, ctx) do
        :allow -> {:cont, :allow}
        {:deny, _} = deny -> {:halt, deny}
      end
    end)
  end

  # Struct-based policy — dispatch to check/4 if available
  defp resolve_policy_decision(%mod{} = policy, tool, args, ctx) do
    if function_exported?(mod, :check, 4) do
      mod.check(policy, tool, args, ctx)
    else
      :allow
    end
  end

  # Module-based policy — call authorize_tool/3
  defp resolve_policy_decision(mod, tool, args, ctx) when is_atom(mod) do
    if function_exported?(mod, :authorize_tool, 3) do
      mod.authorize_tool(tool, args, ctx)
    else
      :allow
    end
  end

  @doc """
  Run `filter_input` across a list of policies. First halt wins; otherwise content is threaded.
  """
  @spec run_input_filters([module()], map(), ADK.Context.t()) ::
          {:cont, map()} | {:halt, [ADK.Event.t()]}
  def run_input_filters(policies, content, ctx) do
    Enum.reduce_while(policies, {:cont, content}, fn mod, {:cont, c} ->
      if function_exported?(mod, :filter_input, 2) do
        case mod.filter_input(c, ctx) do
          {:cont, new_c} -> {:cont, {:cont, new_c}}
          {:halt, events} -> {:halt, {:halt, events}}
        end
      else
        {:cont, {:cont, c}}
      end
    end)
  end

  @doc """
  Run `filter_output` across a list of policies, threading events through each.
  """
  @spec run_output_filters([module()], [ADK.Event.t()], ADK.Context.t()) :: [ADK.Event.t()]
  def run_output_filters(policies, events, ctx) do
    Enum.reduce(policies, events, fn mod, acc ->
      if function_exported?(mod, :filter_output, 2) do
        mod.filter_output(acc, ctx)
      else
        acc
      end
    end)
  end
end
