defmodule ADK.Agent.LlmAgentCallbacksParityTest do
  @moduledoc """
  Parity tests for Python's `test_llm_agent_callbacks.py`.

  The Python test verifies before_model and after_model callbacks at the
  agent-runner integration level. In Elixir, callback hooks are defined in
  `ADK.Callback` and wired through `ADK.Callback.run_before/3` and
  `ADK.Callback.run_after/4`.

  These tests verify:
  - before_model callback that halts (short-circuits the LLM call)
  - before_model callback that continues (noop — LLM is still called)
  - after_model callback that transforms the LLM response
  - Callback chaining (multiple before_model / after_model callbacks)
  - Mixed halt/noop callback chains
  """
  use ExUnit.Case, async: true

  # ── before_model callbacks ──────────────────────────────────────────────

  defmodule BeforeModelHalt do
    @moduledoc "before_model that halts with a canned response."
    @behaviour ADK.Callback

    @impl true
    def before_model(_ctx) do
      {:halt,
       {:ok,
        %{
          content: %{role: :model, parts: [%{text: "before_model_callback"}]},
          usage_metadata: nil
        }}}
    end
  end

  defmodule BeforeModelNoop do
    @moduledoc "before_model that continues (noop — lets the LLM call proceed)."
    @behaviour ADK.Callback

    @impl true
    def before_model(ctx), do: {:cont, ctx}
  end

  defmodule BeforeModelHaltAsync do
    @moduledoc "Simulates an async before_model callback (Elixir doesn't need async, but tests the pattern)."
    @behaviour ADK.Callback

    @impl true
    def before_model(_ctx) do
      {:halt,
       {:ok,
        %{
          content: %{role: :model, parts: [%{text: "async_before_model_callback"}]},
          usage_metadata: nil
        }}}
    end
  end

  # ── after_model callbacks ───────────────────────────────────────────────

  defmodule AfterModelReplace do
    @moduledoc "after_model that replaces the response entirely."
    @behaviour ADK.Callback

    @impl true
    def after_model({:ok, _response}, _ctx) do
      {:ok,
       %{content: %{role: :model, parts: [%{text: "after_model_callback"}]}, usage_metadata: nil}}
    end

    def after_model({:error, _} = err, _ctx), do: err
  end

  defmodule AfterModelAppend do
    @moduledoc "after_model that appends text to the response."
    @behaviour ADK.Callback

    @impl true
    def after_model({:ok, response}, _ctx) do
      new_parts =
        Enum.map(response.content.parts, fn part ->
          if Map.has_key?(part, :text) do
            %{part | text: part.text <> "_appended"}
          else
            part
          end
        end)

      {:ok, %{response | content: %{response.content | parts: new_parts}}}
    end

    def after_model({:error, _} = err, _ctx), do: err
  end

  defmodule AfterModelAsyncReplace do
    @moduledoc "Simulates async after_model callback."
    @behaviour ADK.Callback

    @impl true
    def after_model({:ok, _response}, _ctx) do
      {:ok,
       %{
         content: %{role: :model, parts: [%{text: "async_after_model_callback"}]},
         usage_metadata: nil
       }}
    end

    def after_model({:error, _} = err, _ctx), do: err
  end

  # ── Chaining helpers ────────────────────────────────────────────────────

  defmodule BeforeModelChainA do
    @behaviour ADK.Callback
    @impl true
    def before_model(ctx) do
      # Tag the context to prove chaining
      {:cont, Map.put(ctx, :chain_a, true)}
    end
  end

  defmodule BeforeModelChainB do
    @behaviour ADK.Callback
    @impl true
    def before_model(ctx) do
      # Second in chain — verify A ran first
      {:cont, Map.put(ctx, :chain_b, true)}
    end
  end

  defmodule AfterModelChainA do
    @behaviour ADK.Callback
    @impl true
    def after_model({:ok, response}, _ctx) do
      new_parts =
        Enum.map(response.content.parts, fn part ->
          if Map.has_key?(part, :text), do: %{part | text: part.text <> "_A"}, else: part
        end)

      {:ok, %{response | content: %{response.content | parts: new_parts}}}
    end

    def after_model(err, _ctx), do: err
  end

  defmodule AfterModelChainB do
    @behaviour ADK.Callback
    @impl true
    def after_model({:ok, response}, _ctx) do
      new_parts =
        Enum.map(response.content.parts, fn part ->
          if Map.has_key?(part, :text), do: %{part | text: part.text <> "_B"}, else: part
        end)

      {:ok, %{response | content: %{response.content | parts: new_parts}}}
    end

    def after_model(err, _ctx), do: err
  end

  defmodule NoCallbacks do
    @moduledoc "Callback module that defines no model hooks."
    @behaviour ADK.Callback
    # No before_model or after_model implemented — all optional
  end

  # ── Tests ───────────────────────────────────────────────────────────────

  describe "before_model callback" do
    test "halts and returns canned response (bypasses LLM)" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      assert {:halt, {:ok, response}} =
               ADK.Callback.run_before([BeforeModelHalt], :before_model, ctx)

      assert hd(response.content.parts).text == "before_model_callback"
    end

    test "noop continues execution" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      assert {:cont, ^ctx} =
               ADK.Callback.run_before([BeforeModelNoop], :before_model, ctx)
    end

    test "async-style halt returns canned response" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      assert {:halt, {:ok, response}} =
               ADK.Callback.run_before([BeforeModelHaltAsync], :before_model, ctx)

      assert hd(response.content.parts).text == "async_before_model_callback"
    end

    test "noop with no before_model defined continues" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      assert {:cont, ^ctx} =
               ADK.Callback.run_before([NoCallbacks], :before_model, ctx)
    end
  end

  describe "after_model callback" do
    test "replaces response entirely" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      original =
        {:ok,
         %{content: %{role: :model, parts: [%{text: "model_response"}]}, usage_metadata: nil}}

      result = ADK.Callback.run_after([AfterModelReplace], :after_model, original, ctx)
      assert {:ok, response} = result
      assert hd(response.content.parts).text == "after_model_callback"
    end

    test "appends to response text" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      original =
        {:ok,
         %{content: %{role: :model, parts: [%{text: "model_response"}]}, usage_metadata: nil}}

      result = ADK.Callback.run_after([AfterModelAppend], :after_model, original, ctx)
      assert {:ok, response} = result
      assert hd(response.content.parts).text == "model_response_appended"
    end

    test "async-style replaces response" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      original =
        {:ok,
         %{content: %{role: :model, parts: [%{text: "model_response"}]}, usage_metadata: nil}}

      result = ADK.Callback.run_after([AfterModelAsyncReplace], :after_model, original, ctx)
      assert {:ok, response} = result
      assert hd(response.content.parts).text == "async_after_model_callback"
    end

    test "no after_model defined passes through" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      original =
        {:ok,
         %{content: %{role: :model, parts: [%{text: "model_response"}]}, usage_metadata: nil}}

      result = ADK.Callback.run_after([NoCallbacks], :after_model, original, ctx)
      assert {:ok, response} = result
      assert hd(response.content.parts).text == "model_response"
    end

    test "propagates error without after_model" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      error = {:error, :some_error}

      result = ADK.Callback.run_after([NoCallbacks], :after_model, error, ctx)
      assert result == {:error, :some_error}
    end
  end

  describe "callback chaining" do
    test "before_model chain — all noop callbacks continue in order" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      assert {:cont, result_ctx} =
               ADK.Callback.run_before([BeforeModelChainA, BeforeModelChainB], :before_model, ctx)

      assert result_ctx[:chain_a] == true
      assert result_ctx[:chain_b] == true
    end

    test "before_model chain — first halt stops the chain" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      assert {:halt, {:ok, response}} =
               ADK.Callback.run_before([BeforeModelHalt, BeforeModelChainA], :before_model, ctx)

      assert hd(response.content.parts).text == "before_model_callback"
    end

    test "before_model chain — noop then halt" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      assert {:halt, {:ok, response}} =
               ADK.Callback.run_before([BeforeModelNoop, BeforeModelHalt], :before_model, ctx)

      assert hd(response.content.parts).text == "before_model_callback"
    end

    test "after_model chain — transformations compose in order" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      original = {:ok, %{content: %{role: :model, parts: [%{text: "base"}]}, usage_metadata: nil}}

      result =
        ADK.Callback.run_after([AfterModelChainA, AfterModelChainB], :after_model, original, ctx)

      assert {:ok, response} = result
      # A runs first, then B
      assert hd(response.content.parts).text == "base_A_B"
    end

    test "after_model chain — replace then append" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      original =
        {:ok, %{content: %{role: :model, parts: [%{text: "ignored"}]}, usage_metadata: nil}}

      result =
        ADK.Callback.run_after([AfterModelReplace, AfterModelAppend], :after_model, original, ctx)

      assert {:ok, response} = result
      assert hd(response.content.parts).text == "after_model_callback_appended"
    end

    test "mixed callbacks — modules without hooks are skipped" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      assert {:cont, _} =
               ADK.Callback.run_before(
                 [NoCallbacks, BeforeModelNoop, NoCallbacks],
                 :before_model,
                 ctx
               )
    end
  end

  # Helper: wraps before_model halt as a before_agent halt for runner integration
  defmodule BeforeModelHaltAsAgent do
    @behaviour ADK.Callback

    @impl true
    def before_agent(_ctx) do
      event =
        ADK.Event.new(%{
          author: "agent",
          content: %{"parts" => [%{"text" => "before_model_callback"}]}
        })

      {:halt, [event]}
    end
  end

  describe "integration — before_model halt bypasses LLM in runner" do
    test "before_agent halt produces event with callback response (mirrors before_model pattern)" do
      agent =
        ADK.Agent.LlmAgent.new(
          model: "gemini-1.5-flash",
          name: "root_agent",
          instruction: "Say hello"
        )

      runner = ADK.Runner.new(app_name: "test", agent: agent)

      # In Elixir, before_model isn't wired into Runner/LlmAgent yet.
      # We test the pattern via before_agent which IS wired into Runner.
      events =
        ADK.Runner.run(runner, "user1", "cb_halt_session", "test",
          callbacks: [BeforeModelHaltAsAgent]
        )

      assert length(events) == 1
      # Event uses string keys for content
      assert events |> hd() |> Map.get(:content) |> Map.get("parts") |> hd() |> Map.get("text") ==
               "before_model_callback"
    end
  end
end
