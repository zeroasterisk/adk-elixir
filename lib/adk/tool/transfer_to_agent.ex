defmodule ADK.Tool.TransferToAgent do
  @moduledoc """
  Built-in tool that enables an agent to transfer control to a sub-agent.

  When an LLM agent has sub-agents configured, `transfer_to_agent` tools are
  automatically generated — one per sub-agent. When the LLM calls this tool,
  it produces an event with `actions.transfer_to_agent` set, which the runner
  picks up to hand off execution to the target agent.

  ## How it works

  1. The parent agent's tool list is augmented with one `transfer_to_agent`
     tool per sub-agent (named `transfer_to_agent_<sub_agent_name>`)
  2. When the LLM invokes the tool, it returns a transfer event
  3. The parent agent's run loop detects the transfer and delegates to the
     target sub-agent
  4. The sub-agent runs and its events are returned

  This mirrors Google ADK Python's `transfer_to_agent` pattern.
  """

  @doc """
  Generate transfer tools for a list of target agents.

  Returns a list of `ADK.Tool.FunctionTool` structs, one per target agent.
  Each tool's parameters include an `enum` constraint on the `agent_name`
  field listing all valid target names, preventing the LLM from hallucinating
  non-existent agent names.
  """
  @spec tools_for_sub_agents([ADK.Agent.t()]) :: [ADK.Tool.FunctionTool.t()]
  def tools_for_sub_agents(sub_agents) when is_list(sub_agents) do
    valid_names = Enum.map(sub_agents, &ADK.Agent.name/1)
    Enum.map(sub_agents, &tool_for_agent(&1, valid_names))
  end

  defp tool_for_agent(agent, valid_names) do
    agent_name = ADK.Agent.name(agent)
    agent_desc = ADK.Agent.description(agent)

    description =
      if agent_desc != "" do
        "Transfer to agent '#{agent_name}': #{agent_desc}"
      else
        "Transfer to agent '#{agent_name}' to handle the current task."
      end

    %ADK.Tool.FunctionTool{
      name: "transfer_to_agent_#{agent_name}",
      description: description,
      parameters: %{
        type: "object",
        properties: %{
          "agent_name" => %{
            type: "string",
            description: "Name of the agent to transfer to",
            enum: valid_names
          }
        },
        required: []
      },
      func: fn _ctx, _args ->
        {:transfer_to_agent, agent_name}
      end
    }
  end

  @doc """
  Check if a tool result is a transfer signal.
  """
  @spec transfer?(term()) :: boolean()
  def transfer?({:transfer_to_agent, _name}), do: true
  def transfer?(_), do: false

  @doc """
  Extract the target agent name from a transfer result.
  """
  @spec target_agent({:transfer_to_agent, String.t()}) :: String.t()
  def target_agent({:transfer_to_agent, name}), do: name
end
