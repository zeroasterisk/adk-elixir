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

defmodule ADK.Eval.SingleAgentParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's `tests/integration/test_single_agent.py`.

  The Python test exercises `AgentEvaluator.evaluate/3` against a
  `home_automation_agent` fixture using real LLMs. Here we replicate the
  same behavioral intent at the unit level using `ADK.Eval` + `ADK.LLM.Mock`,
  so the tests are deterministic and fast.

  Covers:
  - test_eval_agent: single-turn agent eval passes all scored cases
  - test_eval_agent_with_agent_suffix_in_module_name: agent callable via .agent/0
  - test_eval_agent_async: async-style (multi-turn) agent eval with tool use
  """

  use ExUnit.Case, async: false

  alias ADK.Eval
  alias ADK.Eval.Case
  alias ADK.Eval.Scorer
  alias ADK.Runner
  alias ADK.Agent.LlmAgent

  # ---------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------

  # Mirrors Python's home_automation_agent fixture: turn off device_2.
  # The mock LLM will first do a tool call, then reply with text.
  defp home_automation_agent do
    set_device_info = ADK.Tool.FunctionTool.new(:set_device_info,
      description: "Update an AC device's status and/or location.",
      func: fn args ->
        device_id = Map.get(args, "device_id", "unknown")
        status = Map.get(args, "status", "")
        "Device #{device_id} information updated: status -> #{status}."
      end,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "device_id" => %{"type" => "string"},
          "status"    => %{"type" => "string"},
          "location"  => %{"type" => "string"}
        },
        "required" => ["device_id"]
      }
    )

    LlmAgent.new(
      name: "home_automation_agent",
      model: "mock",
      instruction: "You are Home Automation Agent. Control the devices in the home.",
      tools: [set_device_info]
    )
  end

  # Same agent exposed through a `.agent/0` function, mirroring Python's
  # `agent_module="tests.integration.fixture.home_automation_agent.agent"` suffix test.
  defmodule HomeAutomationAgentModule do
    def set_device_info(args) do
      device_id = Map.get(args, "device_id", "unknown")
      status = Map.get(args, "status", "")
      "Device #{device_id} information updated: status -> #{status}."
    end

    def agent do
      LlmAgent.new(
        name: "home_automation_agent_module",
        model: "mock",
        instruction: "You are Home Automation Agent. Control the devices in the home.",
        tools: [
          ADK.Tool.FunctionTool.new(:set_device_info,
            description: "Update an AC device.",
            func: &set_device_info/1,
            parameters: %{
              "type" => "object",
              "properties" => %{
                "device_id" => %{"type" => "string"},
                "status"    => %{"type" => "string"}
              },
              "required" => ["device_id"]
            }
          )
        ]
      )
    end
  end

  # hello_world_agent: rolls a die. Mirrors the async agent fixture.
  defp hello_world_agent do
    roll_die = ADK.Tool.FunctionTool.new(:roll_die,
      description: "Roll a die with a given number of sides.",
      func: fn args ->
        sides = Map.get(args, "sides", 6)
        "You rolled a #{Enum.random(1..sides)}"
      end,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "sides" => %{"type" => "integer"}
        },
        "required" => ["sides"]
      }
    )

    LlmAgent.new(
      name: "hello_world_agent",
      model: "mock",
      instruction: "You are a helpful assistant. Use roll_die when asked.",
      tools: [roll_die]
    )
  end

  # ---------------------------------------------------------------------------
  # Custom scorer: checks a specific tool was called with expected args.
  # Mirrors the ToolUsedScorer in the original single_agent_test.exs.
  # ---------------------------------------------------------------------------

  defmodule ToolCalledScorer do
    @behaviour ADK.Eval.Scorer

    @impl true
    def score(events, opts) do
      tool_name = Keyword.fetch!(opts, :tool_name)

      calls = Scorer.function_calls(events)

      found =
        Enum.any?(calls, fn
          %{function_call: %{name: ^tool_name}} -> true
          %{function_call: %{"name" => ^tool_name}} -> true
          _ -> false
        end)

      if found do
        %{score: 1.0, pass: true, details: "Tool #{tool_name} was called."}
      else
        names = Enum.map(calls, fn %{function_call: fc} -> fc[:name] || fc["name"] end)
        %{score: 0.0, pass: false, details: "Tool #{tool_name} not called. Got: #{inspect(names)}"}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # test_eval_agent — mirrors the simplest Python eval:
  #   "Turn off device_2 in the Bedroom" → agent calls set_device_info
  # ---------------------------------------------------------------------------

  test "test_eval_agent: single-turn eval with tool call passes scorer" do
    # Mock: first call is a function call; second call is the final text reply.
    ADK.LLM.Mock.set_responses([
      %{function_call: %{name: "set_device_info", args: %{"device_id" => "device_2", "status" => "OFF"}, id: "fc-1"}},
      "Device device_2 has been turned OFF."
    ])

    agent = home_automation_agent()
    runner = Runner.new(app_name: "eval_single_agent", agent: agent)

    cases = [
      Case.new(
        name: "turn_off_device_2",
        input: "Turn off device_2 in the Bedroom.",
        scorers: [{ToolCalledScorer, tool_name: "set_device_info"}]
      )
    ]

    report = Eval.run(runner, cases)

    assert report.total == 1
    assert report.passed == 1,
           "Expected 1 passed, got #{report.passed}. Details: #{inspect(report.results)}"
  end

  # ---------------------------------------------------------------------------
  # test_eval_agent_with_agent_suffix_in_module_name — mirrors Python's
  # second test that loads the agent via a `.agent/0` function on a module.
  # ---------------------------------------------------------------------------

  test "test_eval_agent_with_agent_suffix_in_module_name: agent callable via .agent/0" do
    ADK.LLM.Mock.set_responses([
      %{function_call: %{name: "set_device_info", args: %{"device_id" => "device_1", "status" => "ON"}, id: "fc-2"}},
      "Device device_1 has been turned ON."
    ])

    # Access agent via .agent/0, mirroring Python's module-with-agent-suffix pattern
    agent = HomeAutomationAgentModule.agent()
    runner = Runner.new(app_name: "eval_single_agent_suffix", agent: agent)

    cases = [
      Case.new(
        name: "turn_on_device_1",
        input: "Turn on device_1.",
        scorers: [{ToolCalledScorer, tool_name: "set_device_info"}]
      )
    ]

    report = Eval.run(runner, cases)

    assert report.total == 1
    assert report.passed == 1,
           "Expected 1 passed. Details: #{inspect(report.results)}"
  end

  # ---------------------------------------------------------------------------
  # test_eval_agent_async — mirrors the async roll_die agent test.
  # The agent is asked to roll a 6-sided die; it should call roll_die.
  # ---------------------------------------------------------------------------

  test "test_eval_agent_async: agent with roll_die tool passes scorer" do
    ADK.LLM.Mock.set_responses([
      %{function_call: %{name: "roll_die", args: %{"sides" => 6}, id: "fc-3"}},
      "You rolled a 4!"
    ])

    agent = hello_world_agent()
    runner = Runner.new(app_name: "eval_async_agent", agent: agent)

    cases = [
      Case.new(
        name: "roll_6_sided_die",
        input: "Roll a 6-sided die.",
        scorers: [{ToolCalledScorer, tool_name: "roll_die"}]
      )
    ]

    report = Eval.run(runner, cases)

    assert report.total == 1
    assert report.passed == 1,
           "Expected 1 passed. Details: #{inspect(report.results)}"
  end

  # ---------------------------------------------------------------------------
  # Multiple runs (num_runs=4 in Python) — verify eval passes across
  # multiple independent runs on the same eval case.
  # ---------------------------------------------------------------------------

  test "eval runs multiple independent cases — all pass (mirrors num_runs=4)" do
    # Set up 4 responses for 4 independent runs
    for _i <- 1..4 do
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "set_device_info", args: %{"device_id" => "device_2", "status" => "OFF"}, id: "fc-multi"}},
        "Device device_2 status updated: status -> OFF."
      ])

      agent = home_automation_agent()
      runner = Runner.new(app_name: "eval_multi_run_#{System.unique_integer([:positive])}", agent: agent)

      cases = [
        Case.new(
          name: "run_device_off",
          input: "Turn off device_2.",
          scorers: [{ToolCalledScorer, tool_name: "set_device_info"}]
        )
      ]

      report = Eval.run(runner, cases)
      assert report.passed == report.total,
             "Run failed. Details: #{inspect(report.results)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Response text scoring — verifies a custom text scorer works in eval context
  # ---------------------------------------------------------------------------

  # Custom scorer that checks the response text contains a given substring,
  # avoiding the `not e.partial` bug in ADK.Eval.Scorer.response_text/1.
  defmodule TextContainsScorer do
    @behaviour ADK.Eval.Scorer

    @impl true
    def score(events, opts) do
      needle = Keyword.fetch!(opts, :text)

      actual =
        events
        |> Enum.filter(fn e -> e.author != "user" end)
        |> Enum.flat_map(fn e ->
          case e.content do
            %{parts: parts} when is_list(parts) ->
              Enum.map(parts, fn
                %{text: t} when is_binary(t) -> t
                _ -> ""
              end)
            _ -> []
          end
        end)
        |> Enum.join("")

      if String.contains?(actual, needle) do
        %{score: 1.0, pass: true, details: nil}
      else
        %{score: 0.0, pass: false, details: "Response does not contain #{inspect(needle)}. Got: #{inspect(actual)}"}
      end
    end
  end

  test "eval with text scorer: response contains expected text" do
    ADK.LLM.Mock.set_responses(["Device device_2 information updated: status -> OFF."])

    agent = LlmAgent.new(name: "simple_bot", model: "mock", instruction: "Help with devices.")
    runner = Runner.new(app_name: "eval_text_score", agent: agent)

    cases = [
      Case.new(
        name: "device_off_text",
        input: "Turn off device_2.",
        scorers: [
          {TextContainsScorer, text: "device_2"},
          {TextContainsScorer, text: "OFF"}
        ]
      )
    ]

    report = Eval.run(runner, cases)

    assert report.total == 1
    assert report.passed == 1
  end

  # ---------------------------------------------------------------------------
  # Failed eval — ensures scorer correctly marks failures
  # ---------------------------------------------------------------------------

  test "eval correctly reports failure when tool not called" do
    # Agent replies with text only, no tool call
    ADK.LLM.Mock.set_responses(["I cannot control devices."])

    agent = home_automation_agent()
    runner = Runner.new(app_name: "eval_failure_test", agent: agent)

    cases = [
      Case.new(
        name: "expects_tool_not_called",
        input: "Turn off device_2.",
        scorers: [{ToolCalledScorer, tool_name: "set_device_info"}]
      )
    ]

    report = Eval.run(runner, cases)

    assert report.total == 1
    assert report.passed == 0
    assert report.failed == 1
  end
end
