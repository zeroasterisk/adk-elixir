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

defmodule ADK.Flows.LlmFlows.RequestConfirmation do
  @moduledoc """
  Handles tool confirmation information to build the LLM request.

  Mirrors the Python ADK `RequestConfirmationLlmRequestProcessor`.

  When a tool call requires confirmation, the agent triggers an
  `adk_request_confirmation` function call. The user response (in a
  subsequent turn) provides the confirmation (confirmed: bool, hint: str).

  This processor:
  1. Scans session events for the last user-authored event.
  2. Parses `adk_request_confirmation` responses.
  3. Re-executes the original tool call if confirmed.
  """

  alias ADK.Event
  alias ADK.Tool.Confirmation
  

  @request_confirmation_function_call_name "adk_request_confirmation"

  @type process_result ::
          {:ok, Event.t()}
          | :noop

  @doc """
  Run the request confirmation processor.

  Returns `{:ok, event}` with the tool execution result if confirmed,
  or `:noop` if no confirmation found or tool not confirmed.
  """
  @spec run(list(Event.t()), ADK.Agent.t(), ADK.Context.t()) :: process_result()
  def run(events, agent, ctx) do
    case find_confirmations(events) do
      [] -> :noop
      confirmations ->
        case resolve_and_reexecute(events, confirmations, agent, ctx) do
          nil -> :noop
          event -> {:ok, event}
        end
    end
  end

  # 1. Scan for the last user-authored event and parse confirmation responses.
  defp find_confirmations(events) do
    events
    |> Enum.reverse()
    |> Enum.find(fn e -> e.author == "user" end)
    |> case do
      nil -> []
      event ->
        event
        |> Event.function_responses()
        |> Enum.filter(fn fr -> fr["name"] == @request_confirmation_function_call_name end)
        |> Enum.map(fn fr ->
          {fr["id"], parse_confirmation(fr["response"])}
        end)
    end
  end

  defp parse_confirmation(response) when is_map(response) do
    # Handle the ADK {'response': json_string} wrapper if present
    data = if Map.has_key?(response, "response"), do: Jason.decode!(response["response"]), else: response
    Confirmation.from_map(data)
  end

  # 2. Resolve original tool calls and re-execute.
  defp resolve_and_reexecute(events, confirmations, agent, ctx) do
    # Confirmation ID to Confirmation mapping
    confirmation_map = Map.new(confirmations)
    conf_ids = MapSet.new(Map.keys(confirmation_map))

    # Find the original tool call that triggered this confirmation
    target =
      Enum.find_value(events, fn event ->
        Enum.find(Event.function_calls(event), fn fc ->
          fc["id"] in conf_ids
        end)
      end)

    case target do
      nil -> nil
      fc ->
        conf = Map.get(confirmation_map, fc["id"])
        if conf.confirmed do
          # Re-execute the original tool call
          original_fc = fc["args"]["originalFunctionCall"]
          execute_original_tool(original_fc, agent, ctx)
        else
          nil
        end
    end
  end

  defp execute_original_tool(fc, agent, ctx) do
    tools = ADK.Agent.LlmAgent.effective_tools(agent)
    tool = Enum.find(tools, fn t -> t.name == fc["name"] end)

    if tool do
      # Run via ADK.Agent.LlmAgent.execute_tools mechanism
      # Simplified for parity: run the tool directly
      res = ADK.Tool.FunctionTool.run(tool, ADK.ToolContext.new(ctx, fc["id"], tool), fc["args"])

      Event.new(%{
        invocation_id: ctx.invocation_id,
        author: agent.name,
        content: %{
          role: :model,
          parts: [%{
            function_response: %{
              name: tool.name,
              id: fc["id"],
              response: case res do
                {:ok, val} -> val
                {:error, reason} -> %{"error" => inspect(reason)}
              end
            }
          }]
        }
      })
    end
  end
end
