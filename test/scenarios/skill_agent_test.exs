defmodule ADK.Scenarios.SkillAgentTest do
  @moduledoc """
  Real-world skill integration patterns — skills adding instructions,
  skills providing tools, multiple skills composed together.
  """

  use ExUnit.Case, async: true

  setup do
    ADK.LLM.Mock.set_responses([])
    :ok
  end

  defp make_runner(agent) do
    ADK.Runner.new(app_name: "skill_scenario", agent: agent)
  end

  defp run_turn(runner, session_id, message) do
    ADK.Runner.run(runner, "user1", session_id, %{text: message})
  end

  defp last_text(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn e -> ADK.Event.text(e) end)
  end

  defp create_skill_dir(name, content) do
    dir = Path.join(System.tmp_dir!(), "skill_test_#{name}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), content)
    dir
  end

  describe "skill instructions" do
    test "agent incorporates skill instructions into behavior" do
      skill_dir =
        create_skill_dir("weather", """
        # Weather Skill

        > Provides weather information guidance.

        When asked about weather, always include:
        1. Temperature in Celsius
        2. Wind speed
        3. A fun weather fact
        """)

      {:ok, skill} = ADK.Skill.from_dir(skill_dir)

      agent =
        ADK.Agent.LlmAgent.new(
          name: "weather_bot",
          model: "test",
          instruction: "You are a helpful assistant.",
          skills: [skill]
        )

      # Verify the agent's instruction includes the skill content
      assert agent.instruction =~ "Weather Skill"
      assert agent.instruction =~ "Temperature in Celsius"

      runner = make_runner(agent)
      sid = "skill-inst-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses(["It's 18°C with 15km/h winds. Fun fact: rain smells good because of petrichor!"])
      events = run_turn(runner, sid, "What's the weather like?")
      assert last_text(events) =~ "18°C"

      File.rm_rf!(skill_dir)
    end

    test "multiple skills compose their instructions" do
      weather_dir =
        create_skill_dir("weather2", """
        # Weather

        > Weather info.

        Always report temperature in Celsius.
        """)

      jokes_dir =
        create_skill_dir("jokes", """
        # Jokes

        > Tell jokes.

        End every response with a relevant joke.
        """)

      {:ok, weather_skill} = ADK.Skill.from_dir(weather_dir)
      {:ok, jokes_skill} = ADK.Skill.from_dir(jokes_dir)

      agent =
        ADK.Agent.LlmAgent.new(
          name: "fun_weather_bot",
          model: "test",
          instruction: "You help people.",
          skills: [weather_skill, jokes_skill]
        )

      # Both skill instructions should be merged
      assert agent.instruction =~ "Celsius"
      assert agent.instruction =~ "joke"

      runner = make_runner(agent)
      sid = "multi-skill-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses(["It's 25°C and sunny! Why did the sun go to school? To get a little brighter! ☀️"])
      events = run_turn(runner, sid, "Weather please")
      assert last_text(events) =~ "25°C"

      File.rm_rf!(weather_dir)
      File.rm_rf!(jokes_dir)
    end
  end

  describe "skill with tools" do
    test "skill provides tools that the agent can use" do
      skill_dir =
        create_skill_dir("calculator", """
        # Calculator Skill

        > Math operations.

        Use the calculate tool for math operations.
        """)

      {:ok, skill} = ADK.Skill.from_dir(skill_dir)

      # Add a tool to the skill manually (in real usage, Loader discovers these)
      calc_tool =
        ADK.Tool.FunctionTool.new(:calculate,
          description: "Evaluate a math expression",
          func: fn _ctx, %{"expression" => expr} ->
            # Simple eval for testing
            {result, _} = Code.eval_string(expr)
            {:ok, %{result: result}}
          end,
          parameters: %{}
        )

      skill_with_tools = %{skill | tools: [calc_tool]}

      agent =
        ADK.Agent.LlmAgent.new(
          name: "math_bot",
          model: "test",
          instruction: "You are a calculator.",
          skills: [skill_with_tools]
        )

      # Agent should have the skill's tools
      assert length(agent.tools) >= 1

      runner = make_runner(agent)
      sid = "skill-tools-#{System.unique_integer([:positive])}"

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "calculate", args: %{"expression" => "42 * 3"}, id: "fc-1"}},
        "42 × 3 = 126"
      ])

      events = run_turn(runner, sid, "What's 42 times 3?")
      assert last_text(events) =~ "126"

      File.rm_rf!(skill_dir)
    end
  end

  describe "skill loading" do
    test "load_from_dir scans a directory of skills" do
      root = Path.join(System.tmp_dir!(), "skills_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      for name <- ["coding", "writing", "research"] do
        dir = Path.join(root, name)
        File.mkdir_p!(dir)

        File.write!(Path.join(dir, "SKILL.md"), """
        # #{String.capitalize(name)} Skill

        > #{name} capabilities.

        Help with #{name} tasks.
        """)
      end

      {:ok, skills} = ADK.Skill.load_from_dir(root)
      assert length(skills) == 3

      names = Enum.map(skills, & &1.name)
      assert "Coding Skill" in names
      assert "Writing Skill" in names
      assert "Research Skill" in names

      File.rm_rf!(root)
    end
  end
end
