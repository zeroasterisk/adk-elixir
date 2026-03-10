defmodule RagAgent.Corpus do
  @moduledoc """
  In-memory document corpus with keyword-based retrieval.

  Stores hardcoded ADK Elixir documentation snippets and provides a simple
  TF-IDF-inspired keyword search. No external dependencies required.

  In a production system, you would replace this with:
  - Vertex AI RAG (as in the Python ADK sample)
  - pgvector / Ecto with embeddings
  - A dedicated search engine (Meilisearch, Elasticsearch)
  """

  @doc """
  Retrieve documents matching the query, ranked by relevance.

  Returns up to `max_results` documents as maps with `:title`, `:content`,
  and `:score` keys.
  """
  def retrieve(query, max_results \\ 3) do
    query_tokens = tokenize(query)

    documents()
    |> Enum.map(fn doc ->
      doc_tokens = tokenize(doc.title <> " " <> doc.content)
      score = score_match(query_tokens, doc_tokens)
      Map.put(doc, :score, score)
    end)
    |> Enum.filter(&(&1.score > 0))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(max_results)
    |> Enum.map(fn doc ->
      %{
        "title" => doc.title,
        "content" => doc.content,
        "score" => Float.round(doc.score, 3)
      }
    end)
  end

  @doc "Return all documents in the corpus."
  def documents do
    [
      %{
        title: "Creating an LlmAgent",
        content: """
        An LlmAgent is the primary agent type in ADK Elixir. Create one with:

            ADK.Agent.LlmAgent.new(
              name: "my_agent",
              model: "gemini-2.0-flash",
              instruction: "You are a helpful assistant.",
              tools: [my_tool]
            )

        Required fields: `name` and `model`. The `instruction` is the system prompt
        that guides the LLM's behavior. Tools are optional.
        """
      },
      %{
        title: "Defining Tools with FunctionTool",
        content: """
        Tools let the LLM call your Elixir functions. Define one with:

            ADK.Tool.FunctionTool.new("tool_name",
              description: "What this tool does",
              parameters: %{
                "type" => "object",
                "properties" => %{
                  "arg1" => %{"type" => "string", "description" => "..."}
                },
                "required" => ["arg1"]
              },
              func: fn ctx, args -> {:ok, %{"result" => "value"}} end
            )

        The `func` receives the tool context and a map of arguments. Return
        `{:ok, result}` where result is a map that gets serialized to JSON.
        You can also use MFA tuples: `{Module, :function}` or
        `{Module, :function, extra_args}`.
        """
      },
      %{
        title: "Running Agents with ADK.Runner",
        content: """
        The Runner executes agent turns. Create and run one:

            runner = %ADK.Runner{app_name: "my_app", agent: my_agent}
            events = ADK.Runner.run(runner, user_id, session_id, "Hello!")

        Events are returned as a list. Extract text with:

            events
            |> Enum.map(&ADK.Event.text/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.join("")

        The session_id enables multi-turn conversations — the runner tracks
        conversation history per session.
        """
      },
      %{
        title: "LoopAgent — Iterative Workflows",
        content: """
        A LoopAgent runs its sub-agents in a loop until an exit condition is met
        or max_iterations is reached:

            ADK.Agent.LoopAgent.new(
              name: "refiner",
              sub_agents: [writer, reviewer],
              max_iterations: 5
            )

        Each iteration runs all sub-agents in sequence. The loop stops when:
        - `max_iterations` is reached
        - A sub-agent sets an `escalate` flag in its event
        - An `exit_condition` function returns true

        Useful for iterative refinement, retry loops, and feedback cycles.
        """
      },
      %{
        title: "SequentialAgent — Pipeline Workflows",
        content: """
        A SequentialAgent runs sub-agents one after another, passing context
        through:

            ADK.Agent.SequentialAgent.new(
              name: "pipeline",
              sub_agents: [researcher, writer, editor]
            )

        Each agent sees the accumulated conversation history. Great for
        multi-step workflows like: research → write → review → publish.
        """
      },
      %{
        title: "ParallelAgent — Concurrent Execution",
        content: """
        A ParallelAgent runs sub-agents concurrently using Elixir's
        Task.async_stream:

            ADK.Agent.ParallelAgent.new(
              name: "parallel_search",
              sub_agents: [web_searcher, db_searcher, cache_checker]
            )

        All sub-agents run at the same time. Results are collected and merged.
        Leverages the BEAM's lightweight processes for true parallelism.
        """
      },
      %{
        title: "Sub-Agent Transfer",
        content: """
        LlmAgents can delegate to sub-agents using transfer tools. When an
        agent has sub_agents defined, ADK automatically creates
        `transfer_to_<agent_name>` tools:

            parent = ADK.Agent.LlmAgent.new(
              name: "router",
              model: "gemini-2.0-flash",
              instruction: "Route to the right specialist.",
              sub_agents: [billing_agent, technical_agent]
            )

        The LLM can call `transfer_to_billing_agent` or
        `transfer_to_technical_agent` to hand off the conversation.
        """
      },
      %{
        title: "Session Management",
        content: """
        ADK manages conversation state through sessions. Each session tracks:
        - Conversation history (user and agent messages)
        - Session state (arbitrary key-value data)
        - The active agent (for multi-agent setups)

        Sessions are identified by a `session_id` string. The default
        `InMemorySessionService` stores sessions in an ETS table. For
        production, use an Ecto-backed session store.
        """
      },
      %{
        title: "RunConfig — Runtime Configuration",
        content: """
        RunConfig lets you override agent settings at runtime:

            config = %ADK.RunConfig{
              max_llm_calls: 10,
              generate_config: %{
                "temperature" => 0.7,
                "max_output_tokens" => 1024
              }
            }

            ADK.Runner.run(runner, user_id, session_id, message, run_config: config)

        The generate_config is merged with the agent's defaults, with RunConfig
        values taking priority. Supports temperature, top_p, max_tokens,
        stop_sequences, and safety settings.
        """
      },
      %{
        title: "Error Handling and Callbacks",
        content: """
        ADK Elixir provides callbacks for error handling:

        - `on_model_error` — called when the LLM returns an error. Can retry,
          fall back to another model, or return a default response.
        - `on_tool_error` — called when a tool function raises. Can return a
          fallback result or propagate the error.

        Example:

            ADK.Agent.LlmAgent.new(
              name: "resilient",
              model: "gemini-2.0-flash",
              on_model_error: fn error, _ctx ->
                {:retry, delay: 1000}
              end,
              ...
            )
        """
      },
      %{
        title: "ADK Web — HTTP API",
        content: """
        ADK includes a Plug-based web router for serving agents over HTTP:

        - `GET /health` — health check
        - `POST /run` — synchronous JSON request/response
        - `POST /run_sse` — Server-Sent Events streaming
        - Session CRUD endpoints

        Add to your Phoenix/Plug app:

            forward "/adk", ADK.Phoenix.WebRouter, agent: MyAgent.agent()

        This is compatible with the Python ADK web interface.
        """
      },
      %{
        title: "LLM Backends",
        content: """
        ADK Elixir supports multiple LLM backends:

        - **Gemini** (default) — Google's Gemini models via the Generative
          Language API. Set `GOOGLE_API_KEY`.
        - **OpenAI** — Any OpenAI-compatible API. Configure with
          `openai_api_key` and `openai_base_url` in the agent.
        - **Anthropic** — Claude models. Configure with the Anthropic API key.

        The backend is selected based on the model name or explicit
        configuration in the agent struct.
        """
      }
    ]
  end

  # --- Private helpers ---

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in stop_words()))
    |> Enum.uniq()
  end

  defp score_match(query_tokens, doc_tokens) do
    doc_set = MapSet.new(doc_tokens)

    # Count matching tokens, weighted by inverse document frequency approximation
    query_tokens
    |> Enum.reduce(0.0, fn token, score ->
      if MapSet.member?(doc_set, token) do
        # Longer tokens are more specific → higher weight
        weight = min(String.length(token) / 4.0, 2.0)
        score + weight
      else
        # Partial match bonus (prefix matching)
        partial =
          Enum.any?(doc_tokens, fn dt ->
            String.starts_with?(dt, token) or String.starts_with?(token, dt)
          end)

        if partial, do: score + 0.3, else: score
      end
    end)
  end

  defp stop_words do
    ~w(the a an is are was were be been being have has had do does did
       will would shall should may might can could in on at to for of
       with by from and or but not no nor so yet both either neither
       each every all any few more most other some such than too very
       it its this that these those what which who whom how when where why)
  end
end
