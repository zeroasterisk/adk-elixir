defmodule ADK.Planner.BuiltInTest do
  use ExUnit.Case, async: true

  alias ADK.Planner.BuiltIn

  test "apply_thinking_config adds thinking_config to generate_config" do
    planner = %BuiltIn{thinking_config: %{thinking_budget: 1024}}
    request = %{model: "test-model"}

    updated_request = BuiltIn.apply_thinking_config(planner, request)

    assert updated_request.generate_config.thinking_config.thinking_budget == 1024
  end

  test "apply_thinking_config merges into existing generate_config" do
    planner = %BuiltIn{thinking_config: %{thinking_budget: 1024}}
    request = %{model: "test-model", generate_config: %{temperature: 0.5}}

    updated_request = BuiltIn.apply_thinking_config(planner, request)

    assert updated_request.generate_config.temperature == 0.5
    assert updated_request.generate_config.thinking_config.thinking_budget == 1024
  end
end
