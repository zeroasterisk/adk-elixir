defmodule ADK.Integration.EvaluateAgentInFixtureTest do
  use ExUnit.Case, async: true
  require Logger

  alias ADK.Eval
  alias ADK.Eval.Case
  alias ADK.Runner

  defmodule EmptyResponseScorer do
    @behaviour ADK.Eval.Scorer

    def score(events, _opts) do
      # The custom agent's run_fn returns [], so the list of events should be empty.
      # In a real-world scenario, we would have a mock LLM that returns canned responses
      # based on the eval file, and we would score the agent's response against those.
      text = ADK.Eval.Scorer.response_text(events)
      if text == "" do
        %{score: 1.0, pass: true, details: "Response is empty as expected."}
      else
        %{score: 0.0, pass: false, details: "Response is not empty."}
      end
    end
  end

  # Helper function to find all test.json files in the fixture directory.
  # Only includes agents that use the EmptyResponseScorer pattern (Custom agents
  # with no-op run_fn). Agents like home_automation_agent have their own
  # dedicated test files.
  @empty_scorer_agents ["hello_world_agent"]

  defp agent_eval_artifacts_in_fixture do
    fixture_dir = Path.join([__DIR__, "fixture"])

    @empty_scorer_agents
    |> Enum.flat_map(fn agent_name ->
      agent_dir = Path.join(fixture_dir, agent_name)
      if File.dir?(agent_dir) do
        # Compile the agent file
        agent_file = Path.join(agent_dir, "agent.ex")
        if File.exists?(agent_file) do
          Code.compile_file(agent_file)
        end

        File.ls!(agent_dir)
        |> Enum.filter(&String.ends_with?(&1, "test.json"))
        |> Enum.map(fn filename ->
          agent_module = Module.concat(["Elixir.ADK.Integration.Fixture", Macro.camelize(agent_name)])
          {agent_module, Path.join(agent_dir, filename)}
        end)
      else
        []
      end
    end)
  end

  test "evaluates agents in fixture" do
    for {agent_module, evalfile} <- agent_eval_artifacts_in_fixture() do
      Logger.info("Evaluating agent #{agent_module} with #{Path.basename(evalfile)}")
      # Load the evaluation data from the evalfile.
      eval_data =
        evalfile
        |> File.read!()
        |> Jason.decode!()

      # Create the eval cases
      cases =
        Enum.map(eval_data["eval_cases"], fn eval_case ->
          # For now, we'll just use the first user message as the input.
          # We will need to implement a more sophisticated scorer to handle multi-turn conversations.
          first_user_message =
            Enum.find(eval_case["conversation"], fn msg ->
              msg["user_content"] != nil
            end)

          input =
            first_user_message["user_content"]["parts"]
            |> Enum.at(0)
            |> Map.get("text")

          scorers = [{EmptyResponseScorer, []}]

          Case.new(
            name: eval_case["eval_id"],
            input: input,
            scorers: scorers
          )
        end)

      # Create a runner for the agent.
      agent = apply(agent_module, :agent, [])
      runner = Runner.new(app_name: "test", agent: agent)

      # Run the evaluation.
      report = Eval.run(runner, cases)

      # Assert that the evaluation was successful.
      assert report.passed == report.total
    end
  end
end
