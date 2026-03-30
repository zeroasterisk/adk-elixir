defmodule ADK.Memory.InMemoryParityTest do
  use ExUnit.Case, async: false

  alias ADK.Memory.InMemory
  alias ADK.Event

  @app_name "test-app"
  @user_id "test-user"
  @other_user_id "another-user"

  setup do
    InMemory.clear(@app_name, @user_id)
    InMemory.clear(@app_name, @other_user_id)
    :ok
  end

  defp build_event(opts) do
    %Event{
      id: Keyword.fetch!(opts, :id),
      invocation_id: Keyword.get(opts, :invocation_id, "inv-test"),
      author: Keyword.get(opts, :author, "user"),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      content: Keyword.get(opts, :content)
    }
  end

  defp mock_session_1_events do
    [
      build_event(
        id: "event-1a",
        invocation_id: "inv-1",
        content: %{text: "The ADK is a great toolkit."}
      ),
      # Event with no content, should be ignored by the service
      build_event(id: "event-1b", invocation_id: "inv-2"),
      build_event(
        id: "event-1c",
        invocation_id: "inv-3",
        author: "model",
        content: %{text: "I agree. The Agent Development Kit (ADK) rocks!"}
      )
    ]
  end

  defp mock_session_2_events do
    [
      build_event(
        id: "event-2a",
        invocation_id: "inv-4",
        content: %{text: "I like to code in Python."}
      )
    ]
  end

  defp mock_session_different_user_events do
    [
      build_event(id: "event-3a", invocation_id: "inv-5", content: %{text: "This is a secret."})
    ]
  end

  describe "add_session" do
    test "test_add_session_to_memory" do
      # Tests that a session with events is correctly added to memory.
      InMemory.add_session(@app_name, @user_id, "session-1", mock_session_1_events())

      {:ok, results} = InMemory.search(@app_name, @user_id, "ADK")
      assert length(results) == 2
      # Check that the event with no content was filtered out
      texts = Enum.map(results, & &1.content)
      assert "The ADK is a great toolkit." in texts
      assert "I agree. The Agent Development Kit (ADK) rocks!" in texts
    end

    test "test_add_session_with_no_events_to_memory" do
      # Tests that adding a session with no events does not cause an error.
      InMemory.add_session(@app_name, @user_id, "session-no-events", [])
      {:ok, results} = InMemory.search(@app_name, @user_id, "anything")
      assert Enum.empty?(results)
    end
  end

  describe "add_events" do
    test "test_add_events_to_memory_appends_without_replacing" do
      # Tests that add_events_to_memory appends events rather than replacing.
      InMemory.add_session(@app_name, @user_id, "session-1", mock_session_1_events())

      new_event =
        build_event(
          id: "event-1d",
          invocation_id: "inv-6",
          content: %{text: "A new fact."}
        )

      InMemory.add_session(@app_name, @user_id, "session-1", [new_event])

      {:ok, results} = InMemory.search(@app_name, @user_id, "fact")
      assert length(results) == 1
      assert hd(results).content == "A new fact."

      # Original events are still there
      {:ok, adk_results} = InMemory.search(@app_name, @user_id, "ADK")
      assert length(adk_results) == 2
    end

    test "test_add_events_to_memory_deduplicates_event_ids" do
      # Tests that duplicate event IDs are not appended multiple times.
      InMemory.add_session(@app_name, @user_id, "session-1", mock_session_1_events())

      duplicate_event =
        build_event(
          id: "event-1a",
          invocation_id: "inv-7",
          content: %{text: "Updated duplicate text."}
        )

      # Attempt to add an event with an existing ID
      InMemory.add_session(@app_name, @user_id, "session-1", [duplicate_event])

      # We shouldn't find the updated duplicate text because it was discarded due to ID deduplication
      {:ok, duplicate_results} = InMemory.search(@app_name, @user_id, "duplicate")
      assert length(duplicate_results) == 0

      # The original should still be there
      {:ok, original_results} = InMemory.search(@app_name, @user_id, "toolkit")
      assert length(original_results) == 1
      assert hd(original_results).content == "The ADK is a great toolkit."
    end
  end

  describe "search_memory" do
    test "test_search_memory_simple_match" do
      # Tests a simple keyword search that should find a match.
      InMemory.add_session(@app_name, @user_id, "session-1", mock_session_1_events())
      InMemory.add_session(@app_name, @user_id, "session-2", mock_session_2_events())

      {:ok, results} = InMemory.search(@app_name, @user_id, "Python")

      assert length(results) == 1
      assert hd(results).content == "I like to code in Python."
      assert hd(results).author == "user"
    end

    test "test_search_memory_case_insensitive_match" do
      # Tests that search is case-insensitive.
      InMemory.add_session(@app_name, @user_id, "session-1", mock_session_1_events())

      {:ok, results} = InMemory.search(@app_name, @user_id, "development")

      assert length(results) == 1
      assert hd(results).content == "I agree. The Agent Development Kit (ADK) rocks!"
    end

    test "test_search_memory_multiple_matches" do
      # Tests that a query can match multiple events.
      InMemory.add_session(@app_name, @user_id, "session-1", mock_session_1_events())

      {:ok, results} = InMemory.search(@app_name, @user_id, "How about ADK?")

      assert length(results) == 2
      texts = Enum.map(results, & &1.content) |> MapSet.new()
      assert MapSet.member?(texts, "The ADK is a great toolkit.")
      assert MapSet.member?(texts, "I agree. The Agent Development Kit (ADK) rocks!")
    end

    test "test_search_memory_no_match" do
      # Tests a search query that should not match any memories.
      InMemory.add_session(@app_name, @user_id, "session-1", mock_session_1_events())

      {:ok, results} = InMemory.search(@app_name, @user_id, "nonexistent")

      assert Enum.empty?(results)
    end

    test "test_search_memory_is_scoped_by_user" do
      # Tests that search results are correctly scoped to the user_id.
      InMemory.add_session(@app_name, @user_id, "session-1", mock_session_1_events())

      InMemory.add_session(
        @app_name,
        @other_user_id,
        "session-3",
        mock_session_different_user_events()
      )

      # Search for "secret" as user_id
      {:ok, results} = InMemory.search(@app_name, @user_id, "secret")
      assert Enum.empty?(results)

      # Search for "secret" as other_user_id
      {:ok, other_results} = InMemory.search(@app_name, @other_user_id, "secret")
      assert length(other_results) == 1
      assert hd(other_results).content == "This is a secret."
    end
  end
end
