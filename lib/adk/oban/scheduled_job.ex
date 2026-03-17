if Code.ensure_loaded?(Oban) do
  defmodule ADK.Oban.ScheduledJob do
    @moduledoc """
    Oban worker for recurring/scheduled agent runs via Oban cron.

    A thin convenience wrapper around `ADK.Oban.AgentWorker` that defaults to
    the `:scheduled` queue and is designed for use with the Oban cron plugin.

    ## One-Shot Delayed Scheduling

        # Schedule an agent to run in 60 seconds
        ADK.Oban.ScheduledJob.schedule(MyApp.Agents.Cleanup, schedule_in: 60)

        # Schedule with inline agent config
        ADK.Oban.ScheduledJob.schedule(
          %{
            "agent_name" => "cleanup",
            "model" => "gemini-flash-latest",
            "instruction" => "You are a cleanup agent.",
            "message" => "Run cleanup now",
            "user_id" => "system"
          },
          schedule_in: 3600
        )

    ## Recurring via Oban Cron Plugin

        # config/config.exs
        config :my_app, Oban,
          repo: MyApp.Repo,
          queues: [scheduled: 5],
          plugins: [
            {Oban.Plugins.Cron,
             crontab: [
               # Run cleanup agent every day at midnight
               {"0 0 * * *", ADK.Oban.ScheduledJob,
                args: %{
                  "agent_module" => "MyApp.Agents.Cleanup",
                  "app_name" => "my_app",
                  "user_id" => "system",
                  "message" => "Run daily cleanup"
                }},
               # Run monitoring agent every hour
               {"0 * * * *", ADK.Oban.ScheduledJob,
                args: %{
                  "agent_module" => "MyApp.Agents.Monitor",
                  "app_name" => "my_app",
                  "user_id" => "system",
                  "message" => "Run hourly monitoring check"
                }}
             ]}
          ]

    ## Agent Module

    Define an agent module that exports `agent/0`:

        defmodule MyApp.Agents.Cleanup do
          def agent do
            ADK.Agent.LlmAgent.new(
              name: "cleanup",
              model: "gemini-flash-latest",
              instruction: "You are a cleanup agent. Remove stale data and free resources."
            )
          end
        end

    ## Inline Agent Config

    Alternatively, pass agent config directly in args:

        %{
          "agent_name" => "monitor",
          "model" => "gemini-flash-latest",
          "instruction" => "You are a monitoring agent.",
          "message" => "Run health check",
          "user_id" => "system"
        }
        |> ADK.Oban.ScheduledJob.new()
        |> Oban.insert()

    ## Telemetry

    Emits the following events on job execution:

      * `[:adk, :scheduled_job, :start]` — before agent run, metadata includes `args`
      * `[:adk, :scheduled_job, :stop]` — after agent run, measurements include `duration`
    """

    use Oban.Worker,
      queue: :scheduled,
      max_attempts: 3

    @impl Oban.Worker
    def perform(%Oban.Job{args: args} = job) do
      start_time = System.monotonic_time(:millisecond)

      :telemetry.execute(
        [:adk, :scheduled_job, :start],
        %{system_time: System.system_time()},
        %{job_id: job.id, args: args}
      )

      result =
        with {:ok, agent} <- resolve_agent(args),
             {:ok, message} <- get_message(args),
             {:ok, user_id} <- get_user_id(args) do
          app_name = Map.get(args, "app_name", "adk_scheduled")
          session_id = Map.get(args, "session_id", generate_session_id())

          runner = %ADK.Runner{
            app_name: app_name,
            agent: agent
          }

          events = ADK.Runner.run(runner, user_id, session_id, message, [])

          {:ok, %{event_count: length(events)}}
        end

      duration = System.monotonic_time(:millisecond) - start_time

      :telemetry.execute(
        [:adk, :scheduled_job, :stop],
        %{duration: duration},
        %{job_id: job.id, args: args, result: result}
      )

      case result do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    @doc """
    Build an Oban changeset for a scheduled agent job.

    The first argument can be:
      - A module atom (e.g. `MyApp.Agents.Cleanup`) — resolves via `agent_module`
      - A map of inline agent config args

    ## Options

      * `:schedule_in` - seconds from now to schedule the job
      * `:scheduled_at` - exact `DateTime` for scheduling
      * `:queue` - Oban queue (default: `:scheduled`)
      * `:max_attempts` - max retry count (default: 3)

    """
    @spec schedule(module() | map(), keyword()) :: Ecto.Changeset.t()
    def schedule(agent_or_args, opts \\ [])

    def schedule(agent_module, opts) when is_atom(agent_module) do
      {base_args, oban_opts} = Keyword.split(opts, [:app_name, :user_id, :message, :session_id])

      args =
        %{
          "agent_module" => module_to_string(agent_module),
          "user_id" => Keyword.get(base_args, :user_id, "system"),
          "message" => Keyword.get(base_args, :message, "Run scheduled task"),
          "app_name" => Keyword.get(base_args, :app_name, "adk_scheduled")
        }
        |> maybe_put("session_id", Keyword.get(base_args, :session_id))

      new(args, oban_opts)
    end

    def schedule(args, opts) when is_map(args) do
      new(args, opts)
    end

    # -- Private --

    defp resolve_agent(%{"agent_module" => mod_string}) do
      module = String.to_existing_atom("Elixir." <> mod_string)

      if function_exported?(module, :agent, 0) do
        {:ok, module.agent()}
      else
        {:error, "Module #{mod_string} does not export agent/0"}
      end
    rescue
      ArgumentError ->
        {:error, "Unknown module: #{mod_string}"}
    end

    defp resolve_agent(%{"agent_name" => name, "model" => model} = args) do
      agent =
        ADK.Agent.LlmAgent.new(
          name: name,
          model: model,
          instruction: Map.get(args, "instruction", "You are a helpful assistant.")
        )

      {:ok, agent}
    end

    defp resolve_agent(_args) do
      {:error, "Job args must include either `agent_module` or `agent_name` + `model`"}
    end

    defp get_message(args) do
      case Map.fetch(args, "message") do
        {:ok, msg} -> {:ok, msg}
        :error -> {:error, "Missing required arg: message"}
      end
    end

    defp get_user_id(args) do
      {:ok, Map.get(args, "user_id", "system")}
    end

    defp generate_session_id do
      "scheduled-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    # Strip the "Elixir." prefix so resolve_agent can add it back consistently
    defp module_to_string(module) when is_atom(module) do
      module
      |> to_string()
      |> String.replace_prefix("Elixir.", "")
    end
  end
end
