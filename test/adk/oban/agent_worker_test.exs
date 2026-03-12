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

    test "new/2 with scheduled_at sets the scheduled time" do
      scheduled = ~U[2026-12-25 09:00:00Z]

      changeset =
        AgentWorker.new(
          %{agent_module: "Mod", user_id: "u", message: "hi"},
          scheduled_at: scheduled
        )

      job = Ecto.Changeset.apply_changes(changeset)
      assert DateTime.compare(job.scheduled_at, scheduled) == :eq
    end

    test "new/2 with inline agent_config includes config in args" do
      changeset =
        AgentWorker.new(%{
          agent_config: %{
            "type" => "llm",
            "name" => "test",
            "model" => "gemini-flash-latest",
            "instruction" => "Be helpful"
          },
          user_id: "user1",
          message: "hello"
        })

      job = Ecto.Changeset.apply_changes(changeset)
      # Oban serializes args through JSON, atom keys become strings
      config = job.args[:agent_config] || job.args["agent_config"]
      assert config["type"] == "llm" || config[:type] == "llm"
    end

    test "new/2 preserves args in the job" do
      args = %{
        agent_module: "MyApp.Agent",
        user_id: "u1",
        message: "test",
        session_id: "s1",
        app_name: "my_app"
      }

      changeset = AgentWorker.new(args)
      job = Ecto.Changeset.apply_changes(changeset)
      job_args = job.args

      # Args may have atom or string keys depending on Oban version
      user_id = job_args[:user_id] || job_args["user_id"]
      assert user_id == "u1"
    end

    test "default queue is :agents" do
      changeset = AgentWorker.new(%{agent_module: "M", user_id: "u", message: "m"})
      job = Ecto.Changeset.apply_changes(changeset)
      assert job.queue == "agents"
    end

    test "default max_attempts is 3" do
      changeset = AgentWorker.new(%{agent_module: "M", user_id: "u", message: "m"})
      job = Ecto.Changeset.apply_changes(changeset)
      assert job.max_attempts == 3
    end
  end
end
