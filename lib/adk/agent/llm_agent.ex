# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Agent.LlmAgent do
  @moduledoc """
  An agent that uses an LLM to generate responses.
  """

  defstruct name: nil,
            model: nil,
            tools: [],
            instruction: nil,
            sub_agents: [],
            description: nil,
            global_instruction: nil

  def new(opts) do
    struct(__MODULE__, opts)
  end

  defmacro __using__(opts) do
    quote do
      use ADK.Agent.BaseAgent

      @name Keyword.get(unquote(opts), :name)
      @model Keyword.get(unquote(opts), :model)

      def run(context) do
        # In a real implementation, we would use the model to generate a response.
        # For now, we just return a fixed response.
        {:ok, "response from " <> @name <> " using " <> @model}
      end
    end
  end

  @doc """
  Get all agent names in the agent tree for error reporting.
  Traverses the tree depth-first and collects all agent names.
  """
  def get_available_agent_names(%__MODULE__{} = root_agent) do
    collect_agent_names(root_agent, [])
  end

  defp collect_agent_names(%{name: name, sub_agents: sub_agents}, acc) when is_list(sub_agents) do
    children_names = Enum.flat_map(sub_agents, &collect_agent_names(&1, []))
    acc ++ [name] ++ children_names
  end

  defp collect_agent_names(%{name: name}, acc) do
    acc ++ [name]
  end

  @doc """
  Find an agent by name in the tree rooted at `root_agent`.
  Returns `{:ok, agent}` if found, or raises `ArgumentError` with an enhanced
  error message listing all available agents and suggested fixes.
  """
  def get_agent_to_run(%__MODULE__{} = root_agent, agent_name) do
    case find_agent(root_agent, agent_name) do
      nil ->
        available = get_available_agent_names(root_agent)

        error_msg = """
        Agent '#{agent_name}' not found.
        Available agents: #{Enum.join(available, ", ")}

        Possible causes:
          1. Agent not registered before being referenced
          2. Agent name mismatch (typo or case sensitivity)
          3. Timing issue (agent referenced before creation)

        Suggested fixes:
          - Verify agent is registered with root agent
          - Check agent name spelling and case
          - Ensure agents are created before being referenced\
        """

        raise ArgumentError, error_msg

      agent ->
        {:ok, agent}
    end
  end

  defp find_agent(%{name: name} = agent, name), do: agent

  defp find_agent(%{sub_agents: sub_agents}, target_name) when is_list(sub_agents) do
    Enum.find_value(sub_agents, fn sub ->
      find_agent(sub, target_name)
    end)
  end

  defp find_agent(_, _), do: nil

  defimpl ADK.Agent do
    def run(agent, _context) do
      # In a real implementation, we would use the model to generate a response.
      # For now, we just return a fixed response.
      {:ok, "response from " <> agent.name <> " using " <> agent.model}
    end

    def name(agent), do: agent.name
    def description(agent), do: agent.description
    def sub_agents(agent), do: agent.sub_agents
  end
end
