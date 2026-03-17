defmodule ADK.Integration.SingleAgentTest do
  use ExUnit.Case, async: true
  require Logger

  alias ADK.Eval
  alias ADK.Eval.Case
  alias ADK.Runner

  defmodule ToolUsedScorer do
    @behaviour ADK.Eval.Scorer

    def score(events, opts) do
      IO.inspect(events, label: "Scorer Events")
      tool_name = Keyword.fetch!(opts, :tool_name)
      args = Keyword.fetch!(opts, :args)

      tool_call =
        Enum.find(events, fn
          %{content: %{parts: [%{function_call: %{name: ^tool_name, args: ^args}}]}} -> true
          _ -> false
        end)

      if tool_call do
        %{score: 1.0, pass: true, details: "Tool #{tool_name} was called with correct arguments."}
      else
        %{score: 0.0, pass: false, details: "Tool #{tool_name} was not called with correct arguments."}
      end
    end
  end

  test "eval_agent" do
    agent_module = ADK.Integration.Fixture.HomeAutomationAgent

    eval_file = Path.join([__DIR__, "fixture", "home_automation_agent", "simple_test.test.json"])

    eval_data =
      eval_file
      |> File.read!()
      |> Jason.decode!()

    cases =
      Enum.map(eval_data["eval_cases"], fn eval_case ->
        first_user_message =
          Enum.find(eval_case["conversation"], &Map.has_key?(&1, "user_content"))

        input =
          first_user_message["user_content"]["parts"]
          |> Enum.at(0)
          |> Map.get("text")

        scorers = [{ToolUsedScorer, [tool_name: "set_device_info", args: %{"device_id" => "device_2", "status" => "OFF"}]}]

        Case.new(
          name: eval_case["eval_id"],
          input: input,
          scorers: scorers
        )
      end)

    runner = Runner.new(app_name: "test", agent: agent_module)

    report = Eval.run(runner, cases)

    assert report.passed == report.total
  end
end
