defmodule ADK.RunnerSessionStoreTest do
  use ExUnit.Case, async: false

  describe "Runner.new/1" do
    test "creates runner with session_store" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")

      runner =
        ADK.Runner.new(
          app_name: "test",
          agent: agent,
          session_store: {ADK.Session.Store.InMemory, []}
        )

      assert runner.session_store == {ADK.Session.Store.InMemory, []}
    end

    test "creates runner without session_store" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = ADK.Runner.new(app_name: "test", agent: agent)
      assert runner.session_store == nil
    end
  end

  describe "session store resolution" do
    test "per-runner store takes precedence over global config" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")

      # Set a global config
      Application.put_env(:adk, :session_store, {ADK.Session.Store.JsonFile, [dir: "/tmp/global"]})

      runner =
        ADK.Runner.new(
          app_name: "test",
          agent: agent,
          session_store: {ADK.Session.Store.InMemory, []}
        )

      # The runner should use its own store, not the global one
      assert runner.session_store == {ADK.Session.Store.InMemory, []}

      # Clean up
      Application.delete_env(:adk, :session_store)
    end

    test "falls back to global config when no per-runner store" do
      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")

      Application.put_env(:adk, :session_store, {ADK.Session.Store.JsonFile, [dir: "/tmp/test"]})

      runner = ADK.Runner.new(app_name: "test", agent: agent)
      assert runner.session_store == nil

      # Clean up
      Application.delete_env(:adk, :session_store)
    end
  end
end
