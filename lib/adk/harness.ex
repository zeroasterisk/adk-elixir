defmodule ADK.Harness do
  @moduledoc """
  The simplest way to run an agent. Structure around execution:
  budgets, guardrails, hooks, and feedback loops.

  Progressive disclosure: simple thing is simple, complex thing is possible.

  ADK Elixir extension — no Python ADK equivalent exists.

  ## L1 — Simple (5 lines)

      agent = ADK.Agent.LlmAgent.new(name: "helper", model: "gemini-2.5-pro", instruction: "Help")
      {:ok, result} = ADK.Harness.run(agent, "Summarize this document")

  ## L2 — Configured

      {:ok, result} = ADK.Harness.run(agent, task,
        budget: %{max_tokens: 50_000, max_steps: 20},
        guardrails: [ADK.Guardrail.ContentFilter.new(blocked_words: ["password"])],
        hooks: %{before_step: fn step, state -> Logger.info("Step \#{step}"); state end}
      )

  ## L3 — Feedback loops

      {:ok, result} = ADK.Harness.run(agent, task,
        feedback: %ADK.Harness.Feedback{
          verifier: fn output -> if ok?(output), do: :ok, else: {:reject, "bad"} end,
          max_retries: 3
        }
      )

  ## References

    * [OpenAI — Harness Engineering](https://openai.com/index/harness-engineering/)
    * [LangChain — Anatomy of an Agent Harness](https://blog.langchain.com/the-anatomy-of-an-agent-harness/)
  """

  alias ADK.Harness.{Budget, Config, Feedback}

  @type result :: %{
          output: String.t(),
          events: [ADK.Event.t()],
          steps: non_neg_integer(),
          tokens: %{input: non_neg_integer(), output: non_neg_integer()},
          duration_ms: non_neg_integer(),
          status: :ok | :budget_exhausted | :timeout | :guardrail_blocked | :max_steps | :feedback_rejected
        }

  @doc """
  Run an agent on a task. The simplest possible interface.

  Uses `ADK.Runner` internally. Creates a session if not provided.
  Returns `{:ok, result}` or `{:error, reason}`.

  ## Options

  All options are optional for L1 usage:

    * `:budget` — map with `:max_tokens`, `:max_steps`, `:max_duration_ms`
    * `:guardrails` — list of guardrail structs for input/output validation
    * `:hooks` — map of hook callbacks (`:before_step`, `:after_step`, etc.)
    * `:feedback` — `%ADK.Harness.Feedback{}` for self-verification loops
    * `:session` — existing session PID (creates new if omitted)
    * `:priority` — `:interactive` | `:background` | `:batch` (for Gateway.Scheduler)
    * `:app_name` — application name for the Runner (default: "harness")
    * `:user_id` — user ID for session (default: "harness_user")
    * `:session_id` — session ID (default: auto-generated)
  """
  @spec run(struct(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(agent, task, opts \\ []) do
    config = Config.from_opts(opts)
    start_time = System.monotonic_time(:millisecond)

    # Start budget tracker
    {:ok, budget_pid} = Budget.start_link(config.budget)
    telemetry_id = Budget.attach_telemetry(budget_pid)

    try do
      # Run input guardrails
      with :ok <- run_guardrails(:input, task, config) do
        result = execute_loop(agent, task, config, budget_pid, opts)
        elapsed = System.monotonic_time(:millisecond) - start_time
        usage = Budget.usage(budget_pid)

        output = extract_output(result)

        # Run output guardrails
        case run_guardrails(:output, output, config) do
          :ok ->
            # Run feedback loop if configured
            case run_feedback(output, result, agent, config, budget_pid, opts) do
              {:ok, final_output, final_events, status} ->
                {:ok,
                 %{
                   output: final_output,
                   events: final_events,
                   steps: usage.steps,
                   tokens: %{input: usage.input_tokens, output: usage.output_tokens},
                   duration_ms: elapsed,
                   status: status
                 }}

              {:error, _} = err ->
                err
            end

          {:error, _reason} ->
            {:ok,
             %{
               output: output,
               events: elem(result, 1),
               steps: usage.steps,
               tokens: %{input: usage.input_tokens, output: usage.output_tokens},
               duration_ms: elapsed,
               status: :guardrail_blocked
             }}
        end
      else
        {:error, _reason} ->
          {:ok,
           %{
             output: "",
             events: [],
             steps: 0,
             tokens: %{input: 0, output: 0},
             duration_ms: 0,
             status: :guardrail_blocked
           }}
      end
    after
      :telemetry.detach(telemetry_id)
      Agent.stop(budget_pid)
    end
  end

  # --- Private ---

  defp execute_loop(agent, task, config, budget_pid, opts) do
    app_name = opts[:app_name] || "harness"
    user_id = opts[:user_id] || "harness_user"
    session_id = opts[:session_id] || "harness_#{:erlang.unique_integer([:positive])}"

    runner =
      ADK.Runner.new(
        app_name: app_name,
        agent: agent
      )

    Budget.record_step(budget_pid)

    # Call hooks
    config.hooks[:before_step] && config.hooks[:before_step].(1, %{})

    events = ADK.Runner.run(runner, user_id, session_id, %{text: task})

    config.hooks[:after_step] && config.hooks[:after_step].(1, events, %{})

    {:ok, events}
  end

  defp extract_output({:ok, events}) when is_list(events) do
    events
    |> Enum.filter(fn e ->
      is_map(e) and Map.get(e, :author) != nil and Map.get(e, :content) != nil
    end)
    |> List.last()
    |> case do
      nil -> ""
      event -> to_string(Map.get(event, :content, ""))
    end
  end

  defp extract_output(_), do: ""

  defp run_guardrails(_phase, _content, %Config{guardrails: []}), do: :ok

  defp run_guardrails(_phase, content, %Config{guardrails: guardrails}) do
    ADK.Guardrail.run_all(guardrails, content)
  end

  defp run_feedback(_output, result, _agent, %Config{feedback: nil}, _budget_pid, _opts) do
    {:ok, extract_output(result), elem(result, 1), :ok}
  end

  defp run_feedback(output, result, agent, %Config{feedback: %Feedback{} = fb}, budget_pid, opts) do
    case Feedback.verify(fb, output) do
      :ok ->
        {:ok, output, elem(result, 1), :ok}

      {:reject, reason} ->
        retry_feedback(output, result, agent, fb, budget_pid, opts, reason, 1)
    end
  end

  defp run_feedback(output, result, _agent, _config, _budget_pid, _opts) do
    {:ok, output, elem(result, 1), :ok}
  end

  defp retry_feedback(_output, _result, agent, fb, budget_pid, opts, reason, attempt) do
    if not Feedback.retries_remaining?(fb, attempt) do
      {:ok, "", [], :feedback_rejected}
    else
    # Check budget before retrying
    case Budget.check(budget_pid) do
      {:exceeded, _} ->
        {:ok, "", [], :budget_exhausted}

      :ok ->
        retry_msg = Feedback.retry_message(fb, reason, attempt)
        config = Config.from_opts(Keyword.put(opts, :feedback, nil))
        result = execute_loop(agent, retry_msg, config, budget_pid, opts)
        output = extract_output(result)

        case Feedback.verify(fb, output) do
          :ok ->
            {:ok, output, elem(result, 1), :ok}

          {:reject, new_reason} ->
            retry_feedback(output, result, agent, fb, budget_pid, opts, new_reason, attempt + 1)
        end
    end
    end
  end
end
