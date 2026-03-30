defmodule ADK.Integration.Fixture.HelloWorldAgent do
  def roll_die(%{"sides" => sides}) do
    "You rolled a #{Enum.random(1..sides)}"
  end

  def agent do
    ADK.Agent.Custom.new(
      name: "hello_world_agent",
      tools: [
        ADK.Tool.FunctionTool.new(
          "roll_die",
          description: "Roll a die with a given number of sides.",
          func: &roll_die/1,
          parameters: %{
            "type" => "object",
            "properties" => %{
              "sides" => %{
                "type" => "integer",
                "description" => "The number of sides on the die."
              }
            },
            "required" => ["sides"]
          }
        )
      ],
      run_fn: fn _agent, _ctx ->
        []
      end
    )
  end
end
