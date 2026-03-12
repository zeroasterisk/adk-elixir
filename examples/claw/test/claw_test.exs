defmodule ClawTest do
  use ExUnit.Case

  describe "Claw.Agents" do
    test "router agent has correct structure" do
      agent = Claw.Agents.router()
      assert agent.name == "router"
      assert agent.model == "gemini-2.0-flash-lite"
      # Updated: now includes save_note, list_notes, call_mock_api, research
      assert length(agent.tools) == 8
      assert length(agent.sub_agents) == 2
    end

    test "router agent includes all showcase tools" do
      agent = Claw.Agents.router()
      tool_names = Enum.map(agent.tools, & &1.name)
      assert "datetime" in tool_names
      assert "read_file" in tool_names
      assert "shell_command" in tool_names
      assert "save_note" in tool_names
      assert "list_notes" in tool_names
      assert "call_mock_api" in tool_names
      assert "research" in tool_names
    end

    test "coder agent has shell and file tools" do
      agent = Claw.Agents.coder()
      assert agent.name == "coder"
      tool_names = Enum.map(agent.tools, & &1.name)
      assert "shell_command" in tool_names
      assert "read_file" in tool_names
    end

    test "helper agent has datetime and file tools" do
      agent = Claw.Agents.helper()
      assert agent.name == "helper"
      tool_names = Enum.map(agent.tools, & &1.name)
      assert "datetime" in tool_names
      assert "read_file" in tool_names
    end

    test "runner/0 returns a configured ADK.Runner" do
      runner = Claw.Agents.runner()
      assert %ADK.Runner{} = runner
      assert runner.app_name == "claw"
      assert runner.artifact_service != nil
      assert runner.memory_store != nil
    end

    test "run_config/1 builds valid RunConfig with temperature" do
      config = Claw.Agents.run_config(temperature: 0.5)
      assert %ADK.RunConfig{} = config
      assert config.generate_config.temperature == 0.5
    end

    test "run_config/1 includes max_tokens when provided" do
      config = Claw.Agents.run_config(temperature: 0.3, max_tokens: 512)
      assert config.generate_config.max_output_tokens == 512
    end

    test "run_config/1 uses default temperature when not specified" do
      config = Claw.Agents.run_config()
      assert config.generate_config.temperature == 0.7
    end
  end

  describe "Claw.Tools - basic" do
    test "datetime tool returns current time" do
      tool = Claw.Tools.datetime()
      assert tool.name == "datetime"
      {:ok, result} = tool.func.(nil, %{})
      assert result =~ "Current UTC time:"
    end

    test "read_file tool reads existing file" do
      tool = Claw.Tools.read_file()
      {:ok, result} = tool.func.(nil, %{"path" => "mix.exs"})
      assert result =~ "Claw.MixProject"
    end

    test "read_file tool rejects path traversal" do
      tool = Claw.Tools.read_file()
      {:error, msg} = tool.func.(nil, %{"path" => "/etc/passwd"})
      assert msg =~ "Access denied"
    end

    test "shell_command tool runs allowed commands" do
      tool = Claw.Tools.shell_command()
      {:ok, result} = tool.func.(nil, %{"command" => "echo hello"})
      assert result =~ "hello"
    end

    test "shell_command tool rejects disallowed commands" do
      tool = Claw.Tools.shell_command()
      {:error, msg} = tool.func.(nil, %{"command" => "rm -rf /"})
      assert msg =~ "not allowed"
    end
  end

  describe "Claw.Tools - artifacts" do
    test "save_note tool has correct structure" do
      tool = Claw.Tools.save_note()
      assert tool.name == "save_note"
      assert tool.description =~ "artifact"
      params = tool.parameters
      assert Map.has_key?(params.properties, :title)
      assert Map.has_key?(params.properties, :content)
    end

    test "save_note gracefully handles missing artifact service" do
      tool = Claw.Tools.save_note()
      # nil ctx simulates no artifact service
      {:ok, result} = tool.func.(nil, %{"title" => "Test", "content" => "Hello"})
      # Should either succeed or return a graceful fallback message
      assert is_binary(result)
    end

    test "list_notes tool has correct structure" do
      tool = Claw.Tools.list_notes()
      assert tool.name == "list_notes"
      assert tool.description =~ "artifact"
    end

    test "list_notes gracefully handles nil context" do
      tool = Claw.Tools.list_notes()
      {:ok, result} = tool.func.(nil, %{})
      assert is_binary(result)
    end
  end

  describe "Claw.Tools - auth/credentials" do
    test "call_mock_api tool has correct structure" do
      tool = Claw.Tools.call_mock_api()
      assert tool.name == "call_mock_api"
      assert tool.description =~ "credential"
      params = tool.parameters
      assert Map.has_key?(params.properties, :endpoint)
    end

    test "call_mock_api returns weather data" do
      tool = Claw.Tools.call_mock_api()
      {:ok, result} = tool.func.(nil, %{"endpoint" => "weather"})
      assert result =~ "Weather"
    end

    test "call_mock_api returns news data" do
      tool = Claw.Tools.call_mock_api()
      {:ok, result} = tool.func.(nil, %{"endpoint" => "news"})
      assert result =~ "News"
    end

    test "call_mock_api handles unknown endpoint" do
      tool = Claw.Tools.call_mock_api()
      {:ok, result} = tool.func.(nil, %{"endpoint" => "unknown"})
      assert result =~ "Unknown"
    end
  end

  describe "Claw.Tools - long-running" do
    test "research tool is a LongRunningTool" do
      tool = Claw.Tools.research()
      assert %ADK.Tool.LongRunningTool{} = tool
      assert tool.name == "research"
      assert tool.description =~ "long-running" or tool.description =~ "long running" or
             tool.description =~ "sources"
      assert tool.timeout > 0
    end

    test "research tool function accepts 3 args (ctx, args, send_update)" do
      tool = Claw.Tools.research()
      updates = []
      update_ref = :counters.new(1, [:atomics])

      send_update_fn = fn _msg ->
        :counters.add(update_ref, 1, 1)
        :ok
      end

      {:ok, result} = tool.func.(nil, %{"topic" => "Elixir", "depth" => "quick"}, send_update_fn)
      assert result =~ "Elixir"
      assert result =~ "Research"
      # Should have sent at least one update
      assert :counters.get(update_ref, 1) > 0
      _ = updates
    end
  end

  describe "Claw.Callbacks" do
    test "before_model returns :cont" do
      ctx = %{request: %{model: "test", messages: []}}
      assert {:cont, ^ctx} = Claw.Callbacks.before_model(ctx)
    end

    test "after_model passes through ok results" do
      response = %{content: %{parts: [%{text: "hello"}]}}
      result = {:ok, response}
      assert ^result = Claw.Callbacks.after_model(result, %{})
    end

    test "after_model passes through error results" do
      result = {:error, "something went wrong"}
      assert ^result = Claw.Callbacks.after_model(result, %{})
    end
  end
end
