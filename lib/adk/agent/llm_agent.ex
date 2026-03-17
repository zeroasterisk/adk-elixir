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
