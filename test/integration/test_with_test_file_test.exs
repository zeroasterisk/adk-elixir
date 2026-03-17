defmodule ADK.Integration.TestWithTestFileTest do
  @moduledoc """
  Port of Python ADK's `tests/integration/test_with_test_file.py`.

  Loads `.test.json` eval files from the home_automation_agent fixture
  and evaluates the agent against them using mock LLM responses derived
  from the eval data itself.
  """
  use ExUnit.Case, async: false

  alias ADK.Eval
  alias ADK.Eval.Case
  alias ADK.Runner

  @fixture_dir Path.join(__DIR__, "fixture/home_automation_agent")

  setup do
    Application.put_env(:adk, :llm_backend, ADK.LLM.Mock)
    on_exit(fn -> Process.put(:adk_mock_responses, nil) end)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp compile_agent_fixture do
    agent_file = Path.join(@fixture_dir, "agent.ex")
    Code.compile_file(agent_file)
    ADK.Integration.Fixture.HomeAutomationAgent.agent()
  end

  defp load_eval_file(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp load_all_eval_files(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".test.json"))
    |> Enum.map(&Path.join(dir, &1))
  end

  # Build mock responses and eval cases from the test.json structure.
  # Each conversation turn produces:
  #   1. A function_call mock response (from tool_uses)
  #   2. A final text mock response (from final_response)
  defp build_cases_from_eval_data(eval_data) do
    Enum.map(eval_data["eval_cases"], fn eval_case ->
      conversation = eval_case["conversation"] || []

      {mock_responses, scorers} =
        Enum.reduce(conversation, {[], []}, fn turn, {resps, scrs} ->
          tool_uses = get_in(turn, ["intermediate_data", "tool_uses"]) || []
          final = turn["final_response"]

          # Build function_call mock responses for each tool use
          tool_resps =
            Enum.map(tool_uses, fn tool_use ->
              %{
                function_call: %{
                  name: tool_use["name"],
                  args: tool_use["args"] || %{},
                  id: tool_use["id"] || "fc-#{System.unique_integer([:positive])}"
                }
              }
            end)

          # Build final text response
          final_text =
            case final do
              %{"parts" => [%{"text" => t} | _]} -> t
              _ -> ""
            end

          final_resp = if final_text != "", do: [final_text], else: []

          # Build ToolUsed scorers for each tool
          tool_scorers =
            Enum.map(tool_uses, fn tool_use ->
              {ADK.Eval.Scorer.ToolUsed, name: tool_use["name"]}
            end)

          {resps ++ tool_resps ++ final_resp, scrs ++ tool_scorers}
        end)

      # Extract the first user message as input
      first_turn = List.first(conversation)

      input =
        case first_turn do
          %{"user_content" => %{"parts" => [%{"text" => t} | _]}} -> t
          _ -> "hello"
        end

      {mock_responses,
       Case.new(
         name: eval_case["eval_id"] || "unnamed",
         input: input,
         scorers: scorers
       )}
    end)
  end

  # ── Tests ────────────────────────────────────────────────────────

  test "test_with_single_test_file — home automation agent evaluated from simple_test.test.json" do
    agent = compile_agent_fixture()
    eval_data = load_eval_file(Path.join(@fixture_dir, "simple_test.test.json"))

    cases_with_mocks = build_cases_from_eval_data(eval_data)

    for {mock_responses, eval_case} <- cases_with_mocks do
      ADK.LLM.Mock.set_responses(mock_responses)

      runner = Runner.new(app_name: "eval_test", agent: agent)
      report = Eval.run(runner, [eval_case])

      assert report.passed == report.total,
             "Failed case #{eval_case.name}: #{inspect(report.results)}"
    end
  end

  test "test_with_folder_of_test_files — loads all .test.json files from fixture dir" do
    agent = compile_agent_fixture()
    eval_files = load_all_eval_files(@fixture_dir)

    assert length(eval_files) >= 1, "Expected at least one .test.json file in fixture dir"

    for eval_file <- eval_files do
      eval_data = load_eval_file(eval_file)
      cases_with_mocks = build_cases_from_eval_data(eval_data)

      for {mock_responses, eval_case} <- cases_with_mocks do
        ADK.LLM.Mock.set_responses(mock_responses)

        runner = Runner.new(app_name: "eval_folder", agent: agent)
        report = Eval.run(runner, [eval_case])

        assert report.passed == report.total,
               "Failed case #{eval_case.name} from #{Path.basename(eval_file)}: #{inspect(report.results)}"
      end
    end
  end
end
