defmodule RagAgent do
  @moduledoc """
  A retrieval-augmented generation (RAG) agent built with ADK Elixir.

  Demonstrates:
  - In-memory document corpus with keyword-based retrieval
  - A `retrieve_documents` tool the LLM calls to find relevant context
  - Grounded answers based on retrieved documents

  Port of the Python ADK `rag_agent/agent.py` sample, which uses Vertex AI
  RAG. Here we implement a simple in-memory version with no external
  dependencies.

  ## Usage

      RagAgent.chat("How do I create a tool in ADK Elixir?")
      RagAgent.chat("What is a LoopAgent?")
  """

  @doc "Build the RAG agent."
  def agent do
    ADK.Agent.LlmAgent.new(
      name: "rag_agent",
      model: model(),
      instruction: """
      You are a knowledgeable assistant for ADK Elixir (Agent Development Kit).
      When the user asks a question, use the retrieve_documents tool to search
      the documentation corpus for relevant information.

      Rules:
      - Always retrieve documents before answering technical questions.
      - Base your answers on the retrieved content. Cite the document title.
      - If no relevant documents are found, say so honestly.
      - Be concise and give code examples when helpful.
      """,
      tools: [retrieve_documents_tool()],
      description: "An ADK Elixir documentation assistant with RAG"
    )
  end

  @doc """
  Chat with the RAG agent.

  ## Examples

      RagAgent.chat("How do I define an agent?")
      RagAgent.chat("What workflow agents are available?")
  """
  def chat(message, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "default")
    user_id = Keyword.get(opts, :user_id, "user")

    runner = %ADK.Runner{app_name: "rag_app", agent: agent()}
    events = ADK.Runner.run(runner, user_id, session_id, message)

    events
    |> Enum.map(&ADK.Event.text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
    |> tap(&IO.puts/1)
  end

  @doc "Run an interactive session."
  def interactive do
    IO.puts("RAG Agent — type 'quit' to exit")
    IO.puts(String.duplicate("=", 50))
    interactive_loop("user1", "session-#{System.unique_integer([:positive])}")
  end

  defp interactive_loop(user_id, session_id) do
    case IO.gets("\nYou: ") do
      :eof -> :ok
      {:error, _} -> :ok
      input ->
        message = String.trim(input)

        if message in ["quit", "exit", "q"] do
          IO.puts("Goodbye!")
        else
          chat(message, session_id: session_id, user_id: user_id)
          interactive_loop(user_id, session_id)
        end
    end
  end

  defp retrieve_documents_tool do
    ADK.Tool.FunctionTool.new("retrieve_documents",
      description: """
      Search the ADK Elixir documentation corpus for relevant documents.
      Returns matching document snippets based on the query.
      Use this tool to find information before answering technical questions.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Search query — keywords or a natural language question"
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of documents to return (default: 3)"
          }
        },
        "required" => ["query"]
      },
      func: fn _ctx, args ->
        query = args["query"]
        max = args["max_results"] || 3

        results = RagAgent.Corpus.retrieve(query, max)
        {:ok, %{"documents" => results, "count" => length(results)}}
      end
    )
  end

  defp model do
    System.get_env("ADK_MODEL", "gemini-flash-latest")
  end
end
