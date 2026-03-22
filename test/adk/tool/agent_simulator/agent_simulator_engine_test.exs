defmodule ADK.Tool.AgentSimulator.AgentSimulatorEngineTest do
  use ExUnit.Case, async: true

  @moduletag :skip # Parity gap: missing feature AgentSimulator

  describe "simulate/3" do
    test "simulate returns nil for a tool not in the config" do
      # config = %ADK.Tool.AgentSimulator.Config{
      #   tool_simulation_configs: [
      #     %ADK.Tool.AgentSimulator.ToolConfig{
      #       tool_name: "configured_tool",
      #       mock_strategy_type: :tool_spec
      #     }
      #   ],
      #   simulation_model: "test-model"
      # }
      # engine = ADK.Tool.AgentSimulator.Engine.new(config)
      # mock_tool = %{name: "unconfigured_tool"}
      #
      # result = ADK.Tool.AgentSimulator.Engine.simulate(engine, mock_tool, %{}, %{})
      # assert result == nil
      flunk("Parity gap: missing feature")
    end

    test "injection is applied when match_args match" do
      # config = %ADK.Tool.AgentSimulator.Config{
      #   tool_simulation_configs: [
      #     %ADK.Tool.AgentSimulator.ToolConfig{
      #       tool_name: "test_tool",
      #       injection_configs: [
      #         %ADK.Tool.AgentSimulator.InjectionConfig{
      #           match_args: %{"param" => "value"},
      #           injected_response: %{"injected" => true}
      #         }
      #       ]
      #     }
      #   ],
      #   simulation_model: "test-model"
      # }
      # engine = ADK.Tool.AgentSimulator.Engine.new(config)
      # mock_tool = %{name: "test_tool"}
      #
      # result = ADK.Tool.AgentSimulator.Engine.simulate(engine, mock_tool, %{"param" => "value"}, %{})
      # assert result == %{"injected" => true}
      flunk("Parity gap: missing feature")
    end

    test "injection is not applied when match_args do not match" do
      # config = %ADK.Tool.AgentSimulator.Config{
      #   tool_simulation_configs: [
      #     %ADK.Tool.AgentSimulator.ToolConfig{
      #       tool_name: "test_tool",
      #       injection_configs: [
      #         %ADK.Tool.AgentSimulator.InjectionConfig{
      #           match_args: %{"param" => "value"},
      #           injected_response: %{"injected" => true}
      #         }
      #       ],
      #       mock_strategy_type: :tool_spec
      #     }
      #   ],
      #   simulation_model: "test-model"
      # }
      # engine = ADK.Tool.AgentSimulator.Engine.new(config)
      # mock_tool = %{name: "test_tool"}
      #
      # result = ADK.Tool.AgentSimulator.Engine.simulate(engine, mock_tool, %{"param" => "different_value"}, %{})
      # assert result == %{"mocked" => true}
      flunk("Parity gap: missing feature")
    end

    test "no-op and warning when no injection hits and mock strategy is unspecified" do
      # config = %ADK.Tool.AgentSimulator.Config{
      #   tool_simulation_configs: [
      #     %ADK.Tool.AgentSimulator.ToolConfig{
      #       tool_name: "test_tool",
      #       injection_configs: [
      #         %ADK.Tool.AgentSimulator.InjectionConfig{
      #           match_args: %{"param" => "value"},
      #           injected_response: %{"injected" => true}
      #         }
      #       ],
      #       mock_strategy_type: :unspecified
      #     }
      #   ],
      #   simulation_model: "test-model"
      # }
      # engine = ADK.Tool.AgentSimulator.Engine.new(config)
      # mock_tool = %{name: "test_tool"}
      #
      # result = ADK.Tool.AgentSimulator.Engine.simulate(engine, mock_tool, %{"param" => "different_value"}, %{})
      # assert result == nil
      flunk("Parity gap: missing feature")
    end

    test "injection with a random_seed is deterministic" do
      # config_mocked = %ADK.Tool.AgentSimulator.Config{
      #   tool_simulation_configs: [
      #     %ADK.Tool.AgentSimulator.ToolConfig{
      #       tool_name: "test_tool",
      #       injection_configs: [
      #         %ADK.Tool.AgentSimulator.InjectionConfig{
      #           injection_probability: 0.5,
      #           random_seed: 42,
      #           injected_response: %{"injected" => true}
      #         }
      #       ],
      #       mock_strategy_type: :tool_spec
      #     }
      #   ],
      #   simulation_model: "test-model"
      # }
      # engine_mocked = ADK.Tool.AgentSimulator.Engine.new(config_mocked)
      # mock_tool = %{name: "test_tool"}
      # result1 = ADK.Tool.AgentSimulator.Engine.simulate(engine_mocked, mock_tool, %{}, %{})
      # assert result1 == %{"mocked" => true}
      #
      # config_injected = %ADK.Tool.AgentSimulator.Config{
      #   tool_simulation_configs: [
      #     %ADK.Tool.AgentSimulator.ToolConfig{
      #       tool_name: "test_tool",
      #       injection_configs: [
      #         %ADK.Tool.AgentSimulator.InjectionConfig{
      #           injection_probability: 0.5,
      #           random_seed: 100,
      #           injected_response: %{"injected" => true}
      #         }
      #       ],
      #       mock_strategy_type: :tool_spec
      #     }
      #   ],
      #   simulation_model: "test-model"
      # }
      # engine_injected = ADK.Tool.AgentSimulator.Engine.new(config_injected)
      # result2 = ADK.Tool.AgentSimulator.Engine.simulate(engine_injected, mock_tool, %{}, %{})
      # assert result2 == %{"injected" => true}
      flunk("Parity gap: missing feature")
    end
  end
end
