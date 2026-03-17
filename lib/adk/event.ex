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

defmodule ADK.Event do
  @moduledoc """
  Represents an event in the ADK.
  """

  defstruct type: nil,
            data: nil,
            custom_metadata: %{},
            error: nil,
            content: nil,
            id: nil,
            invocation_id: nil,
            author: nil,
            branch: nil,
            timestamp: nil,
            partial: nil,
            actions: nil

  def new(opts) do
    struct(__MODULE__, opts)
  end

  def text(event) do
    event.content["parts"]
    |> Enum.find_value(fn %{"text" => text} -> text; _ -> nil end)
  end

  def final_response?(event) do
    !event.partial && !event.actions["transfer_to_agent"]
  end

  def error(reason, opts) do
    new(Keyword.merge(opts, error: reason))
  end

  def to_map(event) do
    Map.from_struct(event)
  end

  def function_calls(event) do
    for %{"function_call" => call} <- event.content["parts"], do: call
  end

  def function_responses(event) do
    for %{"function_response" => response} <- event.content["parts"], do: response
  end

  def on_branch?(event, branch) do
    case {event.branch, branch} do
      {nil, _} -> true
      {event_branch, branch} -> String.starts_with?(event_branch, branch)
    end
  end
end
