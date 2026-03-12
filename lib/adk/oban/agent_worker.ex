if Code.ensure_loaded?(Oban) do
  defmodule ADK.Oban.AgentWorker do
    @moduledoc """
    Oban worker for durable agent execution.

    Runs ADK agents as background jobs with retries, scheduling, and persistence.

    ## Setup

    1. Add `oban` to your deps
    2. Configure Oban in your application (see Oban docs)
    3. Enqueue jobs using `new/2` or the helper `enqueue/4`

    ## Usage

        # Direct Oban usage
        %{
          agent_module: "MyApp.Agents.Helper",
          user_id: "user1",
          session_id: "sess1",
          message: "Hello!",
          app_name: "my_app"
        }
        |> ADK.Oban.AgentWorker.new(queue: :agents, max_attempts: 5)
        |> Oban.insert()

        # Helper function
        ADK.Oban.AgentWorker.enqueue(
          MyApp.Agents.Helper,
          "user1",
          "Hello!",
          app_name: "my_app",
          session_id: "custom-session",
          queue: :agents,
          priority: 1
        )

    ## Agent Resolution

    The worker resolves agents via `agent_module` — a module that implements
    a `agent/0` callback returning an `ADK.Agent.t()` struct:

        defmodule MyApp.Agents.Helper do
          def agent do
            ADK.Agent.LlmAgent.new(
              name: "helper",
              model: "gemini-flash-latest",
              instruction: "You are a helpful assistant."
            )
          end
        end

    Alternatively, pass `agent_config` as a map with `type` and agent params
    for inline agent construction (useful for simple cases):

        %{
          agent_config: %{
            "type" => "llm",
            "name" => "helper",
            "model" => "gemini-flash-latest",
            "instruction" => "Be helpful"
          },
          user_id: "user1",
          message: "Hello!"
        }
        |> ADK.Oban.AgentWorker.new()
        |> Oban.insert()

    ## Result Storage

    By default, results are broadcast via `ADK.Telemetry`:

        :telemetry.execute(
          [:adk, :oban, :job, :complete],
          %{duration: duration_ms},
          %{job_id: id, events: events, args: args}
        )

    Attach a telemetry handler to persist results as needed.

    ## Configuration

        config :adk, ADK.Oban.AgentWorker,
          default_queue: :agents,
          default_max_attempts: 3,
          default_priority: 2
    """

    use Oban.Worker,
      queue: :agents,
      max_attempts: 3,
      priority: 2

    @impl Oban.Worker
    def perform(%Oban.Job{args: args} = job) do
      start_time = System.monotonic_time(:millisecond)

      with {:ok, agent} <- resolve_agent(args),
           {:ok, message} <- get_required(args, "message"),
           {:ok, user_id} <- get_required(args, "user_id") do
        app_name = Map.get(args, "app_name", "adk_oban")
        session_id = Map.get(args, "session_id", generate_session_id())
        runner_opts = decode_runner_opts(Map.get(args, "runner_opts", %{}))

        runner = %ADK.Runner{
          app_name: app_name,
          agent: agent
        }

        events = ADK.Runner.run(runner, user_id, session_id, message, runner_opts)

        duration = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:adk, :oban, :job, :complete],
          %{duration: duration, event_count: length(events)},
          %{job_id: job.id, events: events, args: args}
        )

        {:ok, %{event_count: length(events), duration_ms: duration}}
      end
    end

    @doc """
    Enqueue an agent job with a convenient API.

    ## Options

      * `:app_name` - application name (default: "adk_oban")
      * `:session_id` - session ID (default: auto-generated)
      * `:queue` - Oban queue (default: :agents)
      * `:max_attempts` - max retry attempts (default: 3)
      * `:priority` - job priority, 0-9 (default: 2)
      * `:scheduled_at` - schedule for later execution
      * `:runner_opts` - keyword opts passed to `ADK.Runner.run/5`

    """
    @spec enqueue(module(), String.t(), String.t(), keyword()) ::
            {:ok, Oban.Job.t()} | {:error, term()}
    def enqueue(agent_module, user_id, message, opts \\ []) do
      {oban_opts, job_opts} =
        Keyword.split(opts, [:queue, :max_attempts, :priority, :scheduled_at, :schedule_in])

      args = %{
        agent_module: to_string(agent_module),
        user_id: user_id,
        message: message,
        app_name: Keyword.get(job_opts, :app_name, "adk_oban"),
        session_id: Keyword.get(job_opts, :session_id, generate_session_id())
      }

      args =
        case Keyword.get(job_opts, :runner_opts) do
          nil -> args
          runner_opts -> Map.put(args, :runner_opts, Enum.into(runner_opts, %{}))
        end

      args
      |> new(oban_opts)
      |> Oban.insert()
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

    defp resolve_agent(%{"agent_config" => %{"type" => "llm"} = config}) do
      agent =
        ADK.Agent.LlmAgent.new(
          name: Map.get(config, "name", "oban_agent"),
          model: Map.fetch!(config, "model"),
          instruction: Map.get(config, "instruction", "You are a helpful assistant.")
        )

      {:ok, agent}
    end

    defp resolve_agent(_args) do
      {:error, "Job args must include either `agent_module` or `agent_config`"}
    end

    defp get_required(args, key) do
      case Map.fetch(args, key) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, "Missing required arg: #{key}"}
      end
    end

    defp decode_runner_opts(opts) when is_map(opts) do
      Enum.map(opts, fn {k, v} -> {String.to_existing_atom(k), v} end)
    rescue
      _ -> []
    end

    defp decode_runner_opts(_), do: []

    defp generate_session_id do
      "oban-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
    end
  end
end
