defmodule ADK.Tool.TransferTool do
  @moduledoc """
  Auto-generated tool for transferring control to a sub-agent.

  When an agent has `sub_agents`, this tool is automatically injected
  into its available tools. The LLM calls `transfer_to_agent(agent_name)`
  to hand off execution to a sub-agent.

  This mirrors Python ADK's `transfer_to_agent` auto-tool.
  """

  @tool_name "transfer_to_agent"

  @doc "Build a transfer tool for the given list of sub-agents."
  @spec new([ADK.Agent.t()]) :: ADK.Tool.FunctionTool.t()
  def new(sub_agents) when is_list(sub_agents) do
    agent_names = Enum.map(sub_agents, &ADK.Agent.name/1)

    ADK.Tool.FunctionTool.new(@tool_name,
      description:
        "Transfer control to another agent. Available agents: #{Enum.join(agent_names, ", ")}",
      func: fn ctx, args -> execute(ctx, args, sub_agents) end,
      parameters: %{
        type: "object",
        properties: %{
          agent_name: %{
            type: "string",
            description: "Name of the agent to transfer to",
            enum: agent_names
          }
        },
        required: ["agent_name"]
      }
    )
  end

  @doc "The canonical tool name."
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  defp execute(ctx, %{"agent_name" => agent_name}, sub_agents) do
    case Enum.find(sub_agents, fn sa -> ADK.Agent.name(sa) == agent_name end) do
      nil ->
        {:error,
         "Unknown agent: #{agent_name}. Available: #{Enum.map_join(sub_agents, ", ", &ADK.Agent.name/1)}"}

      target_agent ->
        # Run the target agent with a child context
        child_ctx = ADK.Context.for_child(ctx.context, target_agent)
        events = ADK.Agent.run(target_agent, child_ctx)

        # Extract the final text from the sub-agent's events
        final_text =
          events
          |> Enum.reverse()
          |> Enum.find_value(fn event -> ADK.Event.text(event) end)

        # Store transfer events in session
        if ctx.context.session_pid do
          Enum.each(events, fn event ->
            ADK.Session.append_event(ctx.context.session_pid, event)
          end)
        end

        {:ok, %{transferred_to: agent_name, result: final_text || "Transfer complete."}}
    end
  end

  defp execute(_ctx, args, _sub_agents) do
    {:error, "Missing agent_name parameter. Got: #{inspect(args)}"}
  end
end
