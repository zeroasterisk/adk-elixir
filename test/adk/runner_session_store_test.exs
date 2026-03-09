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

  describe "session store integration" do
    test "run saves session to store" do
      ADK.LLM.Mock.set_responses(["Hello!"])

      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      store = {ADK.Session.Store.InMemory, []}

      runner = ADK.Runner.new(app_name: "store_test", agent: agent, session_store: store)

      events = ADK.Runner.run(runner, "user1", "sess1", "Hi")
      assert length(events) >= 1

      # Session should be persisted in the store
      assert {:ok, data} = ADK.Session.Store.InMemory.load("store_test", "user1", "sess1")
      assert data.id == "sess1"
      assert data.app_name == "store_test"
      assert data.user_id == "user1"
      # Should have user event + agent event(s)
      assert length(data.events) >= 2
    end

    test "run loads existing session from store on second call" do
      ADK.LLM.Mock.set_responses(["First reply", "Second reply"])

      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      store = {ADK.Session.Store.InMemory, []}

      runner = ADK.Runner.new(app_name: "store_test2", agent: agent, session_store: store)

      # First run
      ADK.Runner.run(runner, "user1", "sess1", "Hello")

      # Second run — should load session from store (session process was stopped)
      ADK.Runner.run(runner, "user1", "sess1", "Follow up")

      {:ok, data} = ADK.Session.Store.InMemory.load("store_test2", "user1", "sess1")
      # Should have events from both runs: 2 user + 2 agent = 4
      assert length(data.events) >= 4
    end

    test "two runners with different stores work independently" do
      ADK.LLM.Mock.set_responses(["Reply A", "Reply B"])

      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")

      # Runner 1: uses InMemory store
      runner1 =
        ADK.Runner.new(
          app_name: "multi_store_1",
          agent: agent,
          session_store: {ADK.Session.Store.InMemory, []}
        )

      # Runner 2: uses JsonFile store
      runner2 =
        ADK.Runner.new(
          app_name: "multi_store_2",
          agent: agent,
          session_store: {ADK.Session.Store.JsonFile, []}
        )

      # Run both
      events1 = ADK.Runner.run(runner1, "user1", "sess1", "Hello from runner 1")
      events2 = ADK.Runner.run(runner2, "user1", "sess1", "Hello from runner 2")

      assert length(events1) >= 1
      assert length(events2) >= 1

      # Runner 1's session is in InMemory, NOT in JsonFile
      assert {:ok, data1} = ADK.Session.Store.InMemory.load("multi_store_1", "user1", "sess1")
      assert data1.app_name == "multi_store_1"

      assert {:error, :not_found} =
               ADK.Session.Store.InMemory.load("multi_store_2", "user1", "sess1")

      # Runner 2's session is in JsonFile, NOT in InMemory
      assert {:ok, data2} = ADK.Session.Store.JsonFile.load("multi_store_2", "user1", "sess1")
      assert data2.app_name == "multi_store_2"

      # Cleanup JsonFile artifacts
      File.rm_rf!(Path.join(["priv/sessions", "multi_store_2"]))
    end

    test "nil session_store preserves backward compatibility" do
      ADK.LLM.Mock.set_responses(["OK"])

      agent = ADK.Agent.LlmAgent.new(name: "bot", model: "test", instruction: "Help")
      runner = %ADK.Runner{app_name: "compat_test", agent: agent}

      # Should work fine without a store
      events = ADK.Runner.run(runner, "user1", "sess1", "Hi")
      assert length(events) >= 1

      # Nothing in the store
      assert {:error, :not_found} =
               ADK.Session.Store.InMemory.load("compat_test", "user1", "sess1")
    end
  end
end
