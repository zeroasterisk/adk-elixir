defmodule ADK.Oban.ScheduledJobTest do
  use ExUnit.Case, async: true

  alias ADK.Oban.ScheduledJob

  describe "module availability" do
    test "ScheduledJob module exists when Oban is available" do
      assert Code.ensure_loaded?(ADK.Oban.ScheduledJob)
    end
  end

  describe "new/2 changeset" do
    test "creates a valid changeset with agent_module args" do
      changeset =
        ScheduledJob.new(%{
          "agent_module" => "MyApp.Agents.Cleanup",
          "user_id" => "system",
          "message" => "Run cleanup"
        })

      assert %Oban.Job{} = Ecto.Changeset.apply_changes(changeset)
    end

    test "default queue is :scheduled" do
      changeset =
        ScheduledJob.new(%{
          "agent_module" => "M",
          "user_id" => "system",
          "message" => "run"
        })

      job = Ecto.Changeset.apply_changes(changeset)
      assert job.queue == "scheduled"
    end

    test "default max_attempts is 3" do
      changeset =
        ScheduledJob.new(%{
          "agent_module" => "M",
          "user_id" => "system",
          "message" => "run"
        })

      job = Ecto.Changeset.apply_changes(changeset)
      assert job.max_attempts == 3
    end

    test "creates a valid changeset with inline agent config" do
      changeset =
        ScheduledJob.new(%{
          "agent_name" => "monitor",
          "model" => "gemini-flash-latest",
          "instruction" => "You are a monitoring agent.",
          "message" => "Run health check",
          "user_id" => "system"
        })

      job = Ecto.Changeset.apply_changes(changeset)
      assert %Oban.Job{} = job
      args = job.args
      assert (args["agent_name"] || args[:agent_name]) == "monitor"
    end
  end

  describe "schedule/2 helper" do
    test "builds correct changeset from module atom" do
      changeset = ScheduledJob.schedule(MyApp.Agents.Cleanup)
      job = Ecto.Changeset.apply_changes(changeset)

      args = job.args
      agent_module = args["agent_module"] || args[:agent_module]
      assert agent_module == "MyApp.Agents.Cleanup"
    end

    test "schedule/2 with schedule_in sets scheduled_at" do
      changeset = ScheduledJob.schedule(MyApp.Agents.Cleanup, schedule_in: 60)
      job = Ecto.Changeset.apply_changes(changeset)
      assert %DateTime{} = job.scheduled_at
    end

    test "schedule/2 builds changeset from map args" do
      args = %{
        "agent_name" => "cleanup",
        "model" => "gemini-flash-latest",
        "instruction" => "Clean up stale data.",
        "message" => "Run cleanup",
        "user_id" => "system"
      }

      changeset = ScheduledJob.schedule(args)
      job = Ecto.Changeset.apply_changes(changeset)
      assert %Oban.Job{} = job
    end

    test "schedule/2 with custom queue option" do
      changeset = ScheduledJob.schedule(MyApp.Agents.Cleanup, queue: :cron)
      job = Ecto.Changeset.apply_changes(changeset)
      assert job.queue == "cron"
    end
  end

  describe "perform/1 - agent resolution" do
    test "returns error for unknown agent_module" do
      job = %Oban.Job{
        id: 1,
        args: %{
          "agent_module" => "NonExistent.Module",
          "user_id" => "system",
          "message" => "run"
        }
      }

      assert {:error, reason} = ScheduledJob.perform(job)
      assert reason =~ "Unknown module"
    end

    test "returns error when missing agent config entirely" do
      job = %Oban.Job{
        id: 2,
        args: %{
          "user_id" => "system",
          "message" => "run"
        }
      }

      assert {:error, reason} = ScheduledJob.perform(job)
      assert reason =~ "agent_module" or reason =~ "agent_name"
    end

    test "returns error when missing message for inline config" do
      job = %Oban.Job{
        id: 3,
        args: %{
          "agent_name" => "monitor",
          "model" => "gemini-flash-latest",
          "user_id" => "system"
          # no "message"
        }
      }

      assert {:error, reason} = ScheduledJob.perform(job)
      assert reason =~ "message"
    end
  end

  describe "telemetry events" do
    test "fires :start and :stop telemetry events on perform" do
      test_pid = self()

      :telemetry.attach_many(
        "test-scheduled-job-#{:erlang.unique_integer()}",
        [[:adk, :scheduled_job, :start], [:adk, :scheduled_job, :stop]],
        fn event, measurements, metadata, _cfg ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      job = %Oban.Job{
        id: 99,
        args: %{
          "agent_module" => "NonExistent.TelemetryTest",
          "user_id" => "system",
          "message" => "run"
        }
      }

      # Will error but telemetry should still fire
      ScheduledJob.perform(job)

      assert_receive {:telemetry, [:adk, :scheduled_job, :start], _measurements, metadata}
      assert metadata.job_id == 99

      assert_receive {:telemetry, [:adk, :scheduled_job, :stop], measurements, _metadata}
      assert is_integer(measurements.duration)
    end
  end
end
