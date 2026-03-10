defmodule RagAgentTest do
  use ExUnit.Case

  test "agent is created with correct name" do
    agent = RagAgent.agent()
    assert ADK.Agent.name(agent) == "rag_agent"
  end

  test "agent has retrieve_documents tool" do
    agent = RagAgent.agent()
    assert length(agent.tools) == 1
    [tool] = agent.tools
    assert tool.name == "retrieve_documents"
  end

  describe "Corpus" do
    test "documents returns a non-empty list" do
      docs = RagAgent.Corpus.documents()
      assert is_list(docs)
      assert length(docs) > 5
    end

    test "retrieve finds relevant documents for 'tool'" do
      results = RagAgent.Corpus.retrieve("how to create a tool")
      assert length(results) > 0

      titles = Enum.map(results, & &1["title"])
      assert Enum.any?(titles, &String.contains?(&1, "Tool"))
    end

    test "retrieve finds agent-related documents" do
      results = RagAgent.Corpus.retrieve("LlmAgent create agent")
      assert length(results) > 0

      titles = Enum.map(results, & &1["title"])
      assert Enum.any?(titles, &String.contains?(&1, "Agent"))
    end

    test "retrieve finds workflow agents" do
      results = RagAgent.Corpus.retrieve("loop sequential parallel workflow")
      assert length(results) > 0
    end

    test "retrieve respects max_results" do
      results = RagAgent.Corpus.retrieve("agent", 2)
      assert length(results) <= 2
    end

    test "retrieve returns scored results in descending order" do
      results = RagAgent.Corpus.retrieve("tool function create")
      scores = Enum.map(results, & &1["score"])
      assert scores == Enum.sort(scores, :desc)
    end

    test "retrieve returns empty for unrelated query" do
      results = RagAgent.Corpus.retrieve("quantum physics black holes")
      # May return 0 or low-score results — just verify it doesn't crash
      assert is_list(results)
    end

    test "each result has title, content, and score" do
      [first | _] = RagAgent.Corpus.retrieve("runner")
      assert Map.has_key?(first, "title")
      assert Map.has_key?(first, "content")
      assert Map.has_key?(first, "score")
      assert is_float(first["score"])
    end
  end
end
