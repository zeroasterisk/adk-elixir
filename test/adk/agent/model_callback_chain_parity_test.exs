defmodule ADK.Agent.ModelCallbackChainParityTest do
  @moduledoc """
  Parity tests for Python's `test_model_callback_chain.py`.

  The Python test verifies that before_model and after_model callbacks,
  when provided as a list, execute in order with short-circuit semantics:

  - **before_model chain**: callbacks run left-to-right; the first `{:halt, _}`
    stops the chain and the LLM call is skipped.
  - **after_model chain**: callbacks run left-to-right, each transforming the
    response from the previous one.

  Python parameterized scenarios ported:
  1. `middle_async_callback_returns` — second of four before_model callbacks halts
  2. `all_callbacks_return_none`     — all four before_model callbacks continue → LLM runs
  3. `first_sync_callback_returns`   — first of two before_model callbacks halts

  Same three scenarios are mirrored for after_model chains.
  """
  use ExUnit.Case, async: true

  # ── Callback modules ─────────────────────────────────────────────────────
  # Each module represents a callback in the chain. "Noop" continues;
  # "Halt"/"Replace" short-circuits or transforms.

  # -- before_model: continue (noop) --
  defmodule BeforeNoop do
    @behaviour ADK.Callback
    @impl true
    def before_model(ctx), do: {:cont, ctx}
  end

  # -- before_model: halt with specific text --
  defmodule BeforeHaltCb2 do
    @behaviour ADK.Callback
    @impl true
    def before_model(_ctx) do
      {:halt, {:ok, %{content: %{role: :model, parts: [%{text: "callback_2_response"}]}, usage_metadata: nil}}}
    end
  end

  defmodule BeforeHaltCb3 do
    @behaviour ADK.Callback
    @impl true
    def before_model(_ctx) do
      {:halt, {:ok, %{content: %{role: :model, parts: [%{text: "callback_3_response"}]}, usage_metadata: nil}}}
    end
  end

  defmodule BeforeHaltCb1 do
    @behaviour ADK.Callback
    @impl true
    def before_model(_ctx) do
      {:halt, {:ok, %{content: %{role: :model, parts: [%{text: "callback_1_response"}]}, usage_metadata: nil}}}
    end
  end

  # -- after_model: continue (passthrough) --
  defmodule AfterNoop do
    @behaviour ADK.Callback
    # No after_model defined → passthrough via run_after
  end

  # -- after_model: replace with specific text --
  defmodule AfterReplaceCb2 do
    @behaviour ADK.Callback
    @impl true
    def after_model({:ok, _response}, _ctx) do
      {:ok, %{content: %{role: :model, parts: [%{text: "callback_2_response"}]}, usage_metadata: nil}}
    end

    def after_model(err, _ctx), do: err
  end

  defmodule AfterReplaceCb3 do
    @behaviour ADK.Callback
    @impl true
    def after_model({:ok, _response}, _ctx) do
      {:ok, %{content: %{role: :model, parts: [%{text: "callback_3_response"}]}, usage_metadata: nil}}
    end

    def after_model(err, _ctx), do: err
  end

  defmodule AfterReplaceCb1 do
    @behaviour ADK.Callback
    @impl true
    def after_model({:ok, _response}, _ctx) do
      {:ok, %{content: %{role: :model, parts: [%{text: "callback_1_response"}]}, usage_metadata: nil}}
    end

    def after_model(err, _ctx), do: err
  end

  # ── Helper ────────────────────────────────────────────────────────────────

  defp make_response(text) do
    {:ok, %{content: %{role: :model, parts: [%{text: text}]}, usage_metadata: nil}}
  end

  defp response_text({:ok, resp}), do: hd(resp.content.parts).text
  defp response_text({:halt, {:ok, resp}}), do: hd(resp.content.parts).text

  # ── before_model chain tests (mirrors Python's CALLBACK_PARAMS) ──────────

  describe "before_model callback chain" do
    @doc """
    Python: middle_async_callback_returns
    Callbacks: [noop, halt("callback_2_response"), halt("callback_3_response"), noop]
    Expected: "callback_2_response" — second callback halts, third+fourth never run.
    """
    test "middle callback halts — stops chain at second callback" do
      callbacks = [BeforeNoop, BeforeHaltCb2, BeforeHaltCb3, BeforeNoop]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      result = ADK.Callback.run_before(callbacks, :before_model, ctx)

      assert {:halt, {:ok, _}} = result
      assert response_text(result) == "callback_2_response"
    end

    @doc """
    Python: all_callbacks_return_none
    Callbacks: [noop, noop, noop, noop]
    Expected: all continue → {:cont, ctx} (LLM would run).
    """
    test "all noop callbacks continue — LLM would be called" do
      callbacks = [BeforeNoop, BeforeNoop, BeforeNoop, BeforeNoop]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      result = ADK.Callback.run_before(callbacks, :before_model, ctx)

      assert {:cont, _} = result
    end

    @doc """
    Python: first_sync_callback_returns
    Callbacks: [halt("callback_1_response"), halt("callback_2_response")]
    Expected: "callback_1_response" — first callback halts, second never runs.
    """
    test "first callback halts — second never runs" do
      callbacks = [BeforeHaltCb1, BeforeHaltCb2]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      result = ADK.Callback.run_before(callbacks, :before_model, ctx)

      assert {:halt, {:ok, _}} = result
      assert response_text(result) == "callback_1_response"
    end

    test "empty callback list continues" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      result = ADK.Callback.run_before([], :before_model, ctx)

      assert {:cont, ^ctx} = result
    end

    test "single noop callback continues" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      result = ADK.Callback.run_before([BeforeNoop], :before_model, ctx)

      assert {:cont, ^ctx} = result
    end

    test "single halt callback stops immediately" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      result = ADK.Callback.run_before([BeforeHaltCb1], :before_model, ctx)

      assert {:halt, {:ok, _}} = result
      assert response_text(result) == "callback_1_response"
    end

    test "noop then halt — chain runs both, halts at second" do
      callbacks = [BeforeNoop, BeforeHaltCb3]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      result = ADK.Callback.run_before(callbacks, :before_model, ctx)

      assert {:halt, {:ok, _}} = result
      assert response_text(result) == "callback_3_response"
    end

    test "modules without before_model are skipped in chain" do
      callbacks = [AfterNoop, BeforeNoop, AfterNoop, BeforeHaltCb1]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      result = ADK.Callback.run_before(callbacks, :before_model, ctx)

      assert {:halt, {:ok, _}} = result
      assert response_text(result) == "callback_1_response"
    end
  end

  # ── after_model chain tests (mirrors Python's CALLBACK_PARAMS) ───────────

  describe "after_model callback chain" do
    @doc """
    Python: middle_async_callback_returns
    Callbacks: [noop, replace("callback_2_response"), replace("callback_3_response"), noop]
    Expected: "callback_3_response" — after_model chains compose (no short-circuit),
    so callback_3 replaces callback_2's output.

    NOTE: Python's after_model chain short-circuits on first non-None return.
    Elixir's run_after threads through ALL callbacks (no short-circuit).
    This is an intentional divergence — Elixir after_model always composes.
    """
    test "middle callback replaces — subsequent callbacks see replaced response" do
      callbacks = [AfterNoop, AfterReplaceCb2, AfterReplaceCb3, AfterNoop]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      original = make_response("model_response")

      result = ADK.Callback.run_after(callbacks, :after_model, original, ctx)

      # In Elixir, after_model chains compose: cb2 replaces, then cb3 replaces cb2's output
      assert response_text(result) == "callback_3_response"
    end

    @doc """
    Python: all_callbacks_return_none
    All noops → original response passes through.
    """
    test "all noop callbacks pass through original response" do
      callbacks = [AfterNoop, AfterNoop, AfterNoop, AfterNoop]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      original = make_response("model_response")

      result = ADK.Callback.run_after(callbacks, :after_model, original, ctx)

      assert response_text(result) == "model_response"
    end

    @doc """
    Python: first_sync_callback_returns
    First callback replaces → subsequent callbacks see replaced response.
    """
    test "first callback replaces — second sees the replaced value" do
      callbacks = [AfterReplaceCb1, AfterReplaceCb2]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      original = make_response("model_response")

      result = ADK.Callback.run_after(callbacks, :after_model, original, ctx)

      # cb1 replaces with "callback_1_response", cb2 replaces that
      assert response_text(result) == "callback_2_response"
    end

    test "empty callback list returns original" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      original = make_response("model_response")

      result = ADK.Callback.run_after([], :after_model, original, ctx)

      assert response_text(result) == "model_response"
    end

    test "single replace callback transforms response" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      original = make_response("model_response")

      result = ADK.Callback.run_after([AfterReplaceCb1], :after_model, original, ctx)

      assert response_text(result) == "callback_1_response"
    end

    test "single noop callback passes through" do
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      original = make_response("model_response")

      result = ADK.Callback.run_after([AfterNoop], :after_model, original, ctx)

      assert response_text(result) == "model_response"
    end

    test "modules without after_model are skipped in chain" do
      callbacks = [BeforeNoop, AfterReplaceCb1, BeforeNoop]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      original = make_response("model_response")

      result = ADK.Callback.run_after(callbacks, :after_model, original, ctx)

      assert response_text(result) == "callback_1_response"
    end

    test "error propagates through noop chain" do
      callbacks = [AfterNoop, AfterNoop]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      error = {:error, :llm_failed}

      result = ADK.Callback.run_after(callbacks, :after_model, error, ctx)

      assert result == {:error, :llm_failed}
    end
  end

  # ── Cross-cutting chain tests ────────────────────────────────────────────

  describe "callback chain ordering and context threading" do
    defmodule BeforeChainTracker do
      @moduledoc "Tracks execution order via a list in context."
      @behaviour ADK.Callback
      @impl true
      def before_model(ctx) do
        order = Map.get(ctx, :call_order, [])
        {:cont, Map.put(ctx, :call_order, order ++ [:tracker])}
      end
    end

    defmodule BeforeChainTagger do
      @behaviour ADK.Callback
      @impl true
      def before_model(ctx) do
        order = Map.get(ctx, :call_order, [])
        {:cont, Map.put(ctx, :call_order, order ++ [:tagger])}
      end
    end

    defmodule BeforeChainHaltWithOrder do
      @behaviour ADK.Callback
      @impl true
      def before_model(ctx) do
        order = Map.get(ctx, :call_order, []) ++ [:halter]
        {:halt, {:ok, %{content: %{role: :model, parts: [%{text: "halted_at_#{length(order)}"}]}, usage_metadata: nil, call_order: order}}}
      end
    end

    test "before_model callbacks thread context modifications in order" do
      callbacks = [BeforeChainTracker, BeforeChainTagger]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      assert {:cont, result_ctx} = ADK.Callback.run_before(callbacks, :before_model, ctx)

      assert result_ctx[:call_order] == [:tracker, :tagger]
    end

    test "before_model callbacks thread context then halt preserves order" do
      callbacks = [BeforeChainTracker, BeforeChainTagger, BeforeChainHaltWithOrder]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}

      assert {:halt, {:ok, resp}} = ADK.Callback.run_before(callbacks, :before_model, ctx)

      # Halt callback sees the accumulated call_order from tracker + tagger
      assert resp.call_order == [:tracker, :tagger, :halter]
      assert hd(resp.content.parts).text == "halted_at_3"
    end

    defmodule AfterChainAppendA do
      @behaviour ADK.Callback
      @impl true
      def after_model({:ok, response}, _ctx) do
        new_parts =
          Enum.map(response.content.parts, fn part ->
            if Map.has_key?(part, :text), do: %{part | text: part.text <> "+A"}, else: part
          end)

        {:ok, %{response | content: %{response.content | parts: new_parts}}}
      end

      def after_model(err, _ctx), do: err
    end

    defmodule AfterChainAppendB do
      @behaviour ADK.Callback
      @impl true
      def after_model({:ok, response}, _ctx) do
        new_parts =
          Enum.map(response.content.parts, fn part ->
            if Map.has_key?(part, :text), do: %{part | text: part.text <> "+B"}, else: part
          end)

        {:ok, %{response | content: %{response.content | parts: new_parts}}}
      end

      def after_model(err, _ctx), do: err
    end

    defmodule AfterChainAppendC do
      @behaviour ADK.Callback
      @impl true
      def after_model({:ok, response}, _ctx) do
        new_parts =
          Enum.map(response.content.parts, fn part ->
            if Map.has_key?(part, :text), do: %{part | text: part.text <> "+C"}, else: part
          end)

        {:ok, %{response | content: %{response.content | parts: new_parts}}}
      end

      def after_model(err, _ctx), do: err
    end

    test "after_model callbacks compose transformations left-to-right" do
      callbacks = [AfterChainAppendA, AfterChainAppendB, AfterChainAppendC]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      original = make_response("base")

      result = ADK.Callback.run_after(callbacks, :after_model, original, ctx)

      assert response_text(result) == "base+A+B+C"
    end

    test "four-callback after_model chain with mixed replace and append" do
      callbacks = [AfterNoop, AfterReplaceCb2, AfterChainAppendA, AfterNoop]
      ctx = %{agent: %{name: "root_agent"}, context: %{}}
      original = make_response("model_response")

      result = ADK.Callback.run_after(callbacks, :after_model, original, ctx)

      # noop → replace with "callback_2_response" → append "+A" → noop
      assert response_text(result) == "callback_2_response+A"
    end
  end
end
