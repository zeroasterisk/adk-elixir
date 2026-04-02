defmodule ADK.Agent.LlmAgentDedupTest do
  @moduledoc """
  Tests for the user-message dedup logic in LlmAgent.build_messages/1.

  Instead of copying the private `last_user_message_matches?/2` function,
  these tests exercise dedup through the public API: `ADK.Runner.run/5`
  with a mock LLM backend, then inspect the messages sent to the LLM to
  verify correct dedup behaviour.
  """

  use ExUnit.Case, async: false
  use ADK.LLM.TestHelper

  alias ADK.Runner
  alias ADK.Agent.LlmAgent

  setup do
    # Route LLM calls through MockBackend (which records calls) instead of
    # the default ADK.LLM.Mock (which only consumes responses).
    prev = Application.get_env(:adk, :llm_backend)
    Application.put_env(:adk, :llm_backend, ADK.LLM.MockBackend)

    on_exit(fn ->
      if prev, do: Application.put_env(:adk, :llm_backend, prev),
      else: Application.delete_env(:adk, :llm_backend)
    end)

    :ok
  end

  defp build_runner do
    agent = LlmAgent.new(name: "dedup_test", model: "mock", instruction: "You are a test bot.")
    Runner.new(app_name: "dedup_test_app", agent: agent)
  end

  defp user_texts_in_call(call) do
    call.request.messages
    |> Enum.filter(fn msg -> msg.role == :user end)
    |> Enum.flat_map(fn msg ->
      msg.parts
      |> Enum.filter(&Map.has_key?(&1, :text))
      |> Enum.map(& &1.text)
    end)
  end

  # Keep session alive across multiple Runner.run calls so history accumulates.
  @run_opts [stop_session: false]

  describe "dedup through public API" do
    test "first run: user message appears exactly once in LLM call" do
      setup_mock_llm([mock_response("Hello!")])

      runner = build_runner()
      sid = "dedup-first-#{System.unique_integer([:positive])}"
      _events = Runner.run(runner, "user1", sid, "do something", @run_opts)

      call = last_call()
      assert call != nil, "Expected at least one LLM call"
      texts = user_texts_in_call(call)

      assert Enum.count(texts, &(&1 == "do something")) == 1
    end

    test "second run with same text: dedup prevents duplicate in LLM messages" do
      setup_mock_llm([mock_response("First reply"), mock_response("Second reply")])

      runner = build_runner()
      sid = "dedup-same-#{System.unique_integer([:positive])}"

      _events1 = Runner.run(runner, "user1", sid, "do something", @run_opts)
      _events2 = Runner.run(runner, "user1", sid, "do something", @run_opts)

      calls = all_calls()
      assert length(calls) == 2
      second_call = Enum.at(calls, 1)
      texts = user_texts_in_call(second_call)

      # Session history after Run 2 append:
      #   user("do something"), model("First reply"), user("do something")
      # build_messages sees last user = "do something" matches user_content →
      # dedup strips the extra append → LLM sees exactly 2 user messages
      # (both from history), not 3.
      assert Enum.count(texts, &(&1 == "do something")) == 2
    end

    test "second run with different text: new message IS appended (no false dedup)" do
      setup_mock_llm([mock_response("First reply"), mock_response("Second reply")])

      runner = build_runner()
      sid = "dedup-diff-#{System.unique_integer([:positive])}"

      _events1 = Runner.run(runner, "user1", sid, "do something", @run_opts)
      _events2 = Runner.run(runner, "user1", sid, "do something else", @run_opts)

      calls = all_calls()
      assert length(calls) == 2
      second_call = Enum.at(calls, 1)
      texts = user_texts_in_call(second_call)

      # Different text → dedup does NOT strip → both messages present
      assert "do something" in texts
      assert "do something else" in texts
    end

    test "same text earlier but last user msg differs: no false dedup" do
      setup_mock_llm([
        mock_response("Reply 1"),
        mock_response("Reply 2"),
        mock_response("Reply 3")
      ])

      runner = build_runner()
      sid = "dedup-earlier-#{System.unique_integer([:positive])}"

      _events1 = Runner.run(runner, "user1", sid, "repeat me", @run_opts)
      _events2 = Runner.run(runner, "user1", sid, "something new", @run_opts)
      _events3 = Runner.run(runner, "user1", sid, "repeat me", @run_opts)

      calls = all_calls()
      assert length(calls) == 3
      third_call = Enum.at(calls, 2)
      texts = user_texts_in_call(third_call)

      # "repeat me" appears in turns 1 and 3, dedup matches last user msg
      # (which IS "repeat me" from history), so no extra append.
      # History: user(repeat), model, user(new), model, user(repeat)
      assert Enum.count(texts, &(&1 == "repeat me")) == 2
      assert "something new" in texts
    end
  end
end
