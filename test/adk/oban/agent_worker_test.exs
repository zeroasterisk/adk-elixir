defmodule ADK.Oban.AgentWorkerTest do
  use ExUnit.Case, async: true

  alias ADK.Oban.AgentWorker

  describe "module loaded" do
    test "AgentWorker module exists when Oban is available" do
      assert Code.ensure_loaded?(ADK.Oban.AgentWorker)
    end

    test "new/2 creates a valid changeset" do
      changeset =
        AgentWorker.new(%{
          agent_module: "MyApp.Agents.Test",
          user_id: "user1",
          session_id: "sess1",
          message: "hello"
        })

      assert %Oban.Job{} = Ecto.Changeset.apply_changes(changeset)
    end

    test "new/2 respects queue and priority options" do
      changeset =
        AgentWorker.new(
          %{agent_module: "Mod", user_id: "u", message: "hi"},
          queue: :critical,
          max_attempts: 10,
          priority: 0
        )

      job = Ecto.Changeset.apply_changes(changeset)
      assert job.queue == "critical"
      assert job.max_attempts == 10
      assert job.priority == 0
    end
  end
end
