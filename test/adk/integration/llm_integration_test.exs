defmodule ADK.Integration.LLMIntegrationTest do
  @moduledoc """
  Real integration tests against live LLM APIs.

  These tests hit actual Gemini and Anthropic endpoints. They require API keys
  and are excluded from normal `mix test` runs via the `:integration` tag.

  Run with: mix test --only integration
  Or specific provider: mix test --only integration:gemini

  Models tested (when keys available):
  - Gemini 2.5 Flash (gemini-2.5-flash-preview-05-20)
  - Gemini 2.0 Flash (gemini-2.0-flash)
  - Claude Sonnet 4.6 (claude-sonnet-4-6) — when ANTHROPIC_API_KEY set
  - Claude Haiku 3.5 (claude-3-5-haiku-latest) — when ANTHROPIC_API_KEY set

  Each test records the API response to test/support/fixtures/recordings/
  for future replay tests. Set RECORD=1 to update recordings.
  """

  use ExUnit.Case, async: false

  alias ADK.Runner
  alias ADK.Agent.LlmAgent
  alias ADK.Tool.FunctionTool

  @gemini_models [
    "gemini-2.5-flash",
    "gemini-3-flash-preview"
  ]

  @anthropic_models [
    "claude-sonnet-4-6",
    "claude-haiku-4-5"
  ]

  @recordings_dir Path.join([__DIR__, "..", "..", "support", "fixtures", "recordings"])

  # ── Setup: disable test mocks, use real backends ────────────────────────

  setup do
    # Save previous config — we'll restore on exit
    prev_gemini_plug = Application.get_env(:adk, :gemini_test_plug)
    prev_anthropic_plug = Application.get_env(:adk, :anthropic_test_plug)
    prev_backend = Application.get_env(:adk, :llm_backend)

    # Disable test plugs/stubs so we hit real APIs
    Application.delete_env(:adk, :gemini_test_plug)
    Application.delete_env(:adk, :anthropic_test_plug)
    # Don't set llm_backend here — we set it per-test via set_backend_for_model/1

    on_exit(fn ->
      if prev_gemini_plug, do: Application.put_env(:adk, :gemini_test_plug, prev_gemini_plug),
        else: Application.delete_env(:adk, :gemini_test_plug)
      if prev_anthropic_plug, do: Application.put_env(:adk, :anthropic_test_plug, prev_anthropic_plug),
        else: Application.delete_env(:adk, :anthropic_test_plug)
      if prev_backend, do: Application.put_env(:adk, :llm_backend, prev_backend),
        else: Application.delete_env(:adk, :llm_backend)
    end)

    :ok
  end

  defp set_backend_for_model(model) do
    cond do
      String.starts_with?(model, "gemini") ->
        Application.put_env(:adk, :llm_backend, ADK.LLM.Gemini)
      String.starts_with?(model, "claude") ->
        Application.put_env(:adk, :llm_backend, ADK.LLM.Anthropic)
        # OAuth tokens have lower rate limits — add delay between Anthropic calls
        Process.sleep(5_000)
      true ->
        raise "Unknown model provider for: #{model}"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp gemini_key do
    case System.get_env("GEMINI_API_KEY") do
      v when v in [nil, ""] -> nil
      key -> key
    end
  end

  defp anthropic_key do
    case System.get_env("ANTHROPIC_API_KEY") || System.get_env("ANTHROPIC_OAUTH_TOKEN") do
      v when v in [nil, ""] -> nil
      key -> key
    end
  end

  defp recording?, do: System.get_env("RECORD") == "1"

  defp save_recording(name, data) do
    if recording?() do
      File.mkdir_p!(@recordings_dir)
      path = Path.join(@recordings_dir, "#{name}.json")
      File.write!(path, Jason.encode!(data, pretty: true))
    end
  end

  defp extract_texts(events) do
    events
    |> Enum.filter(fn e -> e.content && e.content.role == :model end)
    |> Enum.flat_map(fn e ->
      e.content.parts
      |> Enum.filter(&Map.has_key?(&1, :text))
      |> Enum.map(& &1.text)
    end)
  end

  defp extract_tool_calls(events) do
    events
    |> Enum.filter(fn e -> e.content && e.content.role == :model end)
    |> Enum.flat_map(fn e ->
      e.content.parts
      |> Enum.filter(&Map.has_key?(&1, :function_call))
      |> Enum.map(& &1.function_call)
    end)
  end

  defp run_agent(model, instruction, user_msg, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])

    agent =
      LlmAgent.new(
        name: "integration_test",
        model: model,
        instruction: instruction,
        tools: tools
      )

    runner = Runner.new(app_name: "integration_test", agent: agent)
    session_id = "integ-#{System.unique_integer([:positive])}"
    events = Runner.run(runner, "test_user", session_id, user_msg)

    %{
      events: events,
      texts: extract_texts(events),
      tool_calls: extract_tool_calls(events)
    }
  end

  # ── Tool definitions ────────────────────────────────────────────────────

  defp get_capital_tool do
    FunctionTool.new(:get_capital,
      description: "Get the capital city of a country.",
      parameters: %{
        type: "object",
        properties: %{
          country: %{type: "string", description: "The country name"}
        },
        required: ["country"]
      },
      func: fn _ctx, %{"country" => country} ->
        capitals = %{
          "france" => "Paris",
          "France" => "Paris",
          "japan" => "Tokyo",
          "Japan" => "Tokyo",
          "brazil" => "Brasília",
          "Brazil" => "Brasília"
        }

        case Map.get(capitals, country) do
          nil -> {:ok, %{error: "Unknown country: #{country}"}}
          capital -> {:ok, %{capital: capital, country: country}}
        end
      end
    )
  end

  defp add_numbers_tool do
    FunctionTool.new(:add_numbers,
      description: "Add two numbers together and return the sum.",
      parameters: %{
        type: "object",
        properties: %{
          a: %{type: "number", description: "First number"},
          b: %{type: "number", description: "Second number"}
        },
        required: ["a", "b"]
      },
      func: fn _ctx, %{"a" => a, "b" => b} ->
        {:ok, %{result: a + b}}
      end
    )
  end

  # ── Test: Simple text response ──────────────────────────────────────────

  describe "simple text response" do
    for model <- @gemini_models do
      @tag :integration
      @tag integration: :gemini
      @tag timeout: 30_000
      test "#{model} returns coherent text" do
        if is_nil(gemini_key()), do: flunk("GEMINI_API_KEY not set")
        set_backend_for_model(unquote(model))

        result =
          run_agent(
            unquote(model),
            "You are a helpful assistant. Be very concise — one sentence max.",
            "What is 2+2?"
          )

        assert length(result.texts) > 0, "Expected at least one text response, got events: #{inspect(result.events)}"
        combined = Enum.join(result.texts, " ")
        assert String.contains?(combined, "4") or String.contains?(String.downcase(combined), "four"), "Expected answer to contain '4' or 'four', got: #{combined}"

        save_recording("simple_text_#{String.replace(unquote(model), "/", "_")}", %{
          model: unquote(model),
          texts: result.texts,
          event_count: length(result.events)
        })
      end
    end

    for model <- @anthropic_models do
      @tag :integration
      @tag integration: :anthropic
      @tag timeout: 30_000
      test "#{model} returns coherent text" do
        if is_nil(anthropic_key()), do: flunk("ANTHROPIC_API_KEY not set")
        set_backend_for_model(unquote(model))

        result =
          run_agent(
            unquote(model),
            "You are a helpful assistant. Be very concise — one sentence max.",
            "What is 2+2?"
          )

        assert length(result.texts) > 0, "Expected at least one text response"
        combined = Enum.join(result.texts, " ")
        assert String.contains?(combined, "4") or String.contains?(String.downcase(combined), "four"), "Expected answer to contain '4' or 'four', got: #{combined}"
      end
    end
  end

  # ── Test: Tool use round-trip ───────────────────────────────────────────

  describe "tool use — single tool call" do
    for model <- @gemini_models do
      @tag :integration
      @tag integration: :gemini
      @tag timeout: 60_000
      test "#{model} calls get_capital tool and uses result" do
        if is_nil(gemini_key()), do: flunk("GEMINI_API_KEY not set")
        set_backend_for_model(unquote(model))

        result =
          run_agent(
            unquote(model),
            "You are a helpful assistant. Always use available tools to answer questions. Be concise.",
            "What is the capital of France?",
            tools: [get_capital_tool()]
          )

        capital_calls = Enum.filter(result.tool_calls, &(&1.name == "get_capital"))

        assert length(capital_calls) > 0,
               "Expected get_capital tool call, got tool_calls: #{inspect(result.tool_calls)}, texts: #{inspect(result.texts)}"

        combined = Enum.join(result.texts, " ")

        assert String.contains?(String.downcase(combined), "paris"),
               "Expected final response to mention Paris, got: #{combined}"

        save_recording("tool_single_#{String.replace(unquote(model), "/", "_")}", %{
          model: unquote(model),
          tool_calls: result.tool_calls,
          texts: result.texts
        })
      end
    end

    for model <- @anthropic_models do
      @tag :integration
      @tag integration: :anthropic
      @tag timeout: 60_000
      test "#{model} calls get_capital tool and uses result" do
        if is_nil(anthropic_key()), do: flunk("ANTHROPIC_API_KEY not set")
        set_backend_for_model(unquote(model))

        result =
          run_agent(
            unquote(model),
            "You are a helpful assistant. Always use available tools to answer questions. Be concise.",
            "What is the capital of France?",
            tools: [get_capital_tool()]
          )

        capital_calls = Enum.filter(result.tool_calls, &(&1.name == "get_capital"))

        assert length(capital_calls) > 0,
               "Expected get_capital tool call, got tool_calls: #{inspect(result.tool_calls)}, texts: #{inspect(result.texts)}"

        combined = Enum.join(result.texts, " ")

        assert String.contains?(String.downcase(combined), "paris"),
               "Expected final response to mention Paris, got: #{combined}"
      end
    end
  end

  # ── Test: Correct tool selection from multiple ──────────────────────────

  describe "tool use — correct selection from multiple tools" do
    for model <- @gemini_models do
      @tag :integration
      @tag integration: :gemini
      @tag timeout: 60_000
      test "#{model} selects add_numbers over get_capital for math" do
        if is_nil(gemini_key()), do: flunk("GEMINI_API_KEY not set")
        set_backend_for_model(unquote(model))

        result =
          run_agent(
            unquote(model),
            "You are a helpful assistant. Use tools when available. Be concise.",
            "What is 17 + 25?",
            tools: [get_capital_tool(), add_numbers_tool()]
          )

        add_calls = Enum.filter(result.tool_calls, &(&1.name == "add_numbers"))

        assert length(add_calls) > 0,
               "Expected add_numbers call, got: #{inspect(result.tool_calls)}, texts: #{inspect(result.texts)}"

        combined = Enum.join(result.texts, " ")

        assert String.contains?(combined, "42"),
               "Expected answer to contain 42, got: #{combined}"
      end
    end
  end

  # ── Test: Multi-turn with tool use ──────────────────────────────────────

  describe "multi-turn conversation with tools" do
    for model <- @gemini_models do
      @tag :integration
      @tag integration: :gemini
      @tag timeout: 120_000
      test "#{model} maintains context across 3 turns with tool use" do
        if is_nil(gemini_key()), do: flunk("GEMINI_API_KEY not set")
        set_backend_for_model(unquote(model))

        agent =
          LlmAgent.new(
            name: "multi_turn_test",
            model: unquote(model),
            instruction: "You are a helpful assistant. Use the get_capital tool to look up capitals. Be concise.",
            tools: [get_capital_tool()]
          )

        runner = Runner.new(app_name: "multi_turn_test", agent: agent)
        sid = "multi-turn-#{System.unique_integer([:positive])}"

        # Turn 1: ask about France
        events1 = Runner.run(runner, "user1", sid, "What is the capital of France?", stop_session: false)
        texts1 = extract_texts(events1)
        combined1 = Enum.join(texts1, " ")
        assert String.contains?(String.downcase(combined1), "paris"), "Turn 1 should mention Paris, got: #{combined1}"

        # Turn 2: follow-up (should understand context)
        events2 = Runner.run(runner, "user1", sid, "What about Japan?", stop_session: false)
        texts2 = extract_texts(events2)
        combined2 = Enum.join(texts2, " ")
        assert String.contains?(String.downcase(combined2), "tokyo"), "Turn 2 should mention Tokyo, got: #{combined2}"

        # Turn 3: verify context retention — references previous turns
        events3 = Runner.run(runner, "user1", sid, "Which of those two cities did I ask about first?")
        texts3 = extract_texts(events3)
        combined3 = Enum.join(texts3, " ")
        assert String.contains?(String.downcase(combined3), "paris"),
               "Turn 3 should reference Paris (asked first), got: #{combined3}"

        save_recording("multi_turn_#{String.replace(unquote(model), "/", "_")}", %{
          model: unquote(model),
          turn1: texts1,
          turn2: texts2,
          turn3: texts3
        })
      end
    end
  end

  # ── Test: No hallucinated tool calls ────────────────────────────────────

  describe "no tool hallucination" do
    for model <- @gemini_models do
      @tag :integration
      @tag integration: :gemini
      @tag timeout: 30_000
      test "#{model} does NOT call tools when unnecessary" do
        if is_nil(gemini_key()), do: flunk("GEMINI_API_KEY not set")
        set_backend_for_model(unquote(model))

        result =
          run_agent(
            unquote(model),
            "You are a helpful assistant. Use tools only when needed. Be concise.",
            "Say hello.",
            tools: [get_capital_tool(), add_numbers_tool()]
          )

        assert length(result.tool_calls) == 0,
               "Expected no tool calls for 'say hello', got: #{inspect(result.tool_calls)}"

        assert length(result.texts) > 0, "Expected a text response"
      end
    end
  end

  # ── Test: Anthropic tool selection from multiple ────────────────────────

  describe "tool use — Anthropic correct selection from multiple tools" do
    for model <- @anthropic_models do
      @tag :integration
      @tag integration: :anthropic
      @tag timeout: 60_000
      test "#{model} selects add_numbers over get_capital for math" do
        if is_nil(anthropic_key()), do: flunk("ANTHROPIC_API_KEY not set")
        set_backend_for_model(unquote(model))

        result =
          run_agent(
            unquote(model),
            "You are a helpful assistant. Use tools when available. Be concise.",
            "What is 17 + 25?",
            tools: [get_capital_tool(), add_numbers_tool()]
          )

        add_calls = Enum.filter(result.tool_calls, &(&1.name == "add_numbers"))

        assert length(add_calls) > 0,
               "Expected add_numbers call, got: #{inspect(result.tool_calls)}, texts: #{inspect(result.texts)}"

        combined = Enum.join(result.texts, " ")

        assert String.contains?(combined, "42"),
               "Expected answer to contain 42, got: #{combined}"
      end
    end
  end

  # ── Test: Anthropic multi-turn with tool use ────────────────────────────

  describe "Anthropic multi-turn conversation with tools" do
    for model <- @anthropic_models do
      @tag :integration
      @tag integration: :anthropic
      @tag timeout: 120_000
      test "#{model} maintains context across 3 turns with tool use" do
        if is_nil(anthropic_key()), do: flunk("ANTHROPIC_API_KEY not set")
        set_backend_for_model(unquote(model))

        agent =
          LlmAgent.new(
            name: "multi_turn_test",
            model: unquote(model),
            instruction: "You are a helpful assistant. Use the get_capital tool to look up capitals. Be concise.",
            tools: [get_capital_tool()]
          )

        runner = Runner.new(app_name: "multi_turn_test", agent: agent)
        sid = "multi-turn-anthropic-#{System.unique_integer([:positive])}"

        # Turn 1: ask about France
        events1 = Runner.run(runner, "user1", sid, "What is the capital of France?", stop_session: false)
        texts1 = extract_texts(events1)
        combined1 = Enum.join(texts1, " ")
        assert String.contains?(String.downcase(combined1), "paris"), "Turn 1 should mention Paris, got: #{combined1}"

        # Anthropic rate limit buffer
        Process.sleep(5_000)

        # Turn 2: follow-up (should understand context)
        events2 = Runner.run(runner, "user1", sid, "What about Japan?", stop_session: false)
        texts2 = extract_texts(events2)
        combined2 = Enum.join(texts2, " ")
        assert String.contains?(String.downcase(combined2), "tokyo"), "Turn 2 should mention Tokyo, got: #{combined2}"

        # Anthropic rate limit buffer
        Process.sleep(5_000)

        # Turn 3: verify context retention — references previous turns
        events3 = Runner.run(runner, "user1", sid, "Which of those two cities did I ask about first?")
        texts3 = extract_texts(events3)
        combined3 = Enum.join(texts3, " ")
        assert String.contains?(String.downcase(combined3), "paris"),
               "Turn 3 should reference Paris (asked first), got: #{combined3}"

        save_recording("multi_turn_anthropic_#{String.replace(unquote(model), "/", "_")}", %{
          model: unquote(model),
          turn1: texts1,
          turn2: texts2,
          turn3: texts3
        })
      end
    end
  end

  # ── Test: Error handling — bad model name ───────────────────────────────

  describe "error handling — bad model name" do
    @tag :integration
    @tag integration: :error_handling
    @tag timeout: 30_000
    test "Gemini with nonexistent model returns error or raises" do
      if is_nil(gemini_key()), do: flunk("GEMINI_API_KEY not set")
      Application.put_env(:adk, :llm_backend, ADK.LLM.Gemini)

      try do
        result =
          run_agent(
            "gemini-nonexistent-model-999",
            "You are a helpful assistant.",
            "Hello"
          )

        # If it didn't raise, check for error events or empty texts
        error_events =
          result.events
          |> Enum.filter(fn e ->
            (e.content && e.content.role == :error) or
              Map.get(e, :error, false)
          end)

        assert length(error_events) > 0 or length(result.texts) == 0,
               "Expected error events or no text for bad model, got texts: #{inspect(result.texts)}"
      rescue
        e ->
          # Any exception is acceptable — the point is it doesn't silently succeed
          assert Exception.message(e) != "",
                 "Expected a meaningful error message, got empty"
      end
    end

    @tag :integration
    @tag integration: :error_handling
    @tag timeout: 30_000
    test "Anthropic with nonexistent model returns error or raises" do
      if is_nil(anthropic_key()), do: flunk("ANTHROPIC_API_KEY not set")
      Application.put_env(:adk, :llm_backend, ADK.LLM.Anthropic)

      try do
        result =
          run_agent(
            "claude-nonexistent-model-999",
            "You are a helpful assistant.",
            "Hello"
          )

        error_events =
          result.events
          |> Enum.filter(fn e ->
            (e.content && e.content.role == :error) or
              Map.get(e, :error, false)
          end)

        assert length(error_events) > 0 or length(result.texts) == 0,
               "Expected error events or no text for bad model, got texts: #{inspect(result.texts)}"
      rescue
        e ->
          assert Exception.message(e) != "",
                 "Expected a meaningful error message, got empty"
      end
    end
  end

  # ── Test: Edge case — empty tool result ─────────────────────────────────

  describe "edge case — empty tool result" do
    @tag :integration
    @tag integration: :edge_case
    @tag timeout: 60_000
    test "Gemini handles tool returning empty map gracefully" do
      if is_nil(gemini_key()), do: flunk("GEMINI_API_KEY not set")
      set_backend_for_model("gemini-2.5-flash")

      empty_tool =
        FunctionTool.new(:lookup_info,
          description: "Look up information about a topic. Always use this tool when asked about any topic.",
          parameters: %{
            type: "object",
            properties: %{
              topic: %{type: "string", description: "The topic to look up"}
            },
            required: ["topic"]
          },
          func: fn _ctx, _args -> {:ok, %{}} end
        )

      result =
        run_agent(
          "gemini-2.5-flash",
          "You are a helpful assistant. Always use the lookup_info tool when asked about topics. If the tool returns empty results, say you couldn't find information.",
          "Look up information about dolphins.",
          tools: [empty_tool]
        )

      # Should not crash — agent should handle empty result gracefully
      assert length(result.events) > 0, "Expected at least one event"
      assert length(result.texts) > 0, "Expected a text response even with empty tool result"
    end
  end

  # ── Test: Edge case — large tool result ─────────────────────────────────

  describe "edge case — large tool result" do
    @tag :integration
    @tag integration: :edge_case
    @tag timeout: 60_000
    test "Gemini handles 50KB tool result without crashing" do
      if is_nil(gemini_key()), do: flunk("GEMINI_API_KEY not set")
      set_backend_for_model("gemini-2.5-flash")

      large_tool =
        FunctionTool.new(:get_data,
          description: "Get a large dataset. Always use this tool when asked for data.",
          parameters: %{
            type: "object",
            properties: %{
              query: %{type: "string", description: "What data to retrieve"}
            },
            required: ["query"]
          },
          func: fn _ctx, _args ->
            {:ok, %{data: String.duplicate("x", 50_000), status: "complete"}}
          end
        )

      result =
        run_agent(
          "gemini-2.5-flash",
          "You are a helpful assistant. Use the get_data tool when asked for data. Summarize what you got back briefly.",
          "Get me some data please.",
          tools: [large_tool]
        )

      # Should not crash — ResultGuard should cap at 50KB
      assert length(result.events) > 0, "Expected at least one event"
      assert length(result.texts) > 0, "Expected a text response even with large tool result"
    end
  end
end
