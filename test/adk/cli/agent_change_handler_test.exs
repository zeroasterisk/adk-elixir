defmodule ADK.CLI.AgentChangeHandlerTest do
  use ExUnit.Case, async: true

  alias ADK.CLI.AgentChangeHandler

  # -- should_reload?/1 -------------------------------------------------------

  describe "should_reload?/1 with supported extensions" do
    test ".ex triggers reload" do
      assert AgentChangeHandler.should_reload?("lib/my_agent.ex")
    end

    test ".exs triggers reload" do
      assert AgentChangeHandler.should_reload?("test/my_agent_test.exs")
    end

    test ".yaml triggers reload" do
      assert AgentChangeHandler.should_reload?("config/agent.yaml")
    end

    test ".yml triggers reload" do
      assert AgentChangeHandler.should_reload?("config/agent.yml")
    end
  end

  describe "should_reload?/1 with unsupported extensions" do
    test ".json is ignored" do
      refute AgentChangeHandler.should_reload?("data.json")
    end

    test ".txt is ignored" do
      refute AgentChangeHandler.should_reload?("notes.txt")
    end

    test ".md is ignored" do
      refute AgentChangeHandler.should_reload?("README.md")
    end

    test ".toml is ignored" do
      refute AgentChangeHandler.should_reload?("config.toml")
    end

    test ".gitignore (dot-file) is ignored" do
      refute AgentChangeHandler.should_reload?(".gitignore")
    end

    test "no extension is ignored" do
      refute AgentChangeHandler.should_reload?("Makefile")
    end
  end

  # -- handle_change/3 --------------------------------------------------------

  defmodule MockLoader do
    @moduledoc false
    def remove_from_cache(app_name) do
      send(self(), {:removed, app_name})
      :ok
    end
  end

  describe "handle_change/3" do
    setup do
      state = %{current_app_name: "my_app", runners_to_clean: []}
      {:ok, state: state}
    end

    test "supported extension triggers cache removal and adds to runners_to_clean",
         %{state: state} do
      new_state = AgentChangeHandler.handle_change("lib/agent.ex", MockLoader, state)
      assert_received {:removed, "my_app"}
      assert "my_app" in new_state.runners_to_clean
    end

    test "unsupported extension does not trigger cache removal", %{state: state} do
      new_state = AgentChangeHandler.handle_change("data.json", MockLoader, state)
      refute_received {:removed, _}
      assert new_state.runners_to_clean == []
    end

    test "does not duplicate app_name in runners_to_clean", %{state: state} do
      state = %{state | runners_to_clean: ["my_app"]}
      new_state = AgentChangeHandler.handle_change("lib/agent.exs", MockLoader, state)
      assert_received {:removed, "my_app"}
      assert new_state.runners_to_clean == ["my_app"]
    end
  end
end
