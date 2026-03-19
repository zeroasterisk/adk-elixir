defmodule ADK.Agent.ToolCallbackChainParityTest do
  @moduledoc """
  Parity tests for Python's `test_async_tool_callbacks.py`.

  The Python test verifies that before_tool and after_tool callbacks execute
  correctly when provided individually or as a chain (list), with short-circuit
  semantics for before_tool and composition for after_tool.

  Python scenarios ported:
  - `test_async_before_tool_callback`    — single before_tool halts with mock response
  - `test_async_after_tool_callback`     — single after_tool replaces tool result
  - `test_before_tool_callbacks_chain`   — chained before_tool with parametrized scenarios
  - `test_after_tool_callbacks_chain`    — chained after_tool with parametrized scenarios

  Chain parametrized scenarios (from Python's CALLBACK_PARAMS):
  1. `middle_async_callback_returns` — second of four callbacks returns a value
  2. `all_callbacks_return_none`     — all four callbacks pass through
  3. `first_sync_callback_returns`   — first of two callbacks returns a value
  """
  use ExUnit.Case, async: true

  # ── before_tool callback modules ──────────────────────────────────────────

  defmodule BeforeToolNoop do
    @behaviour ADK.Callback
    @impl true
    def before_tool(ctx), do: {:cont, ctx}
  end

  defmodule BeforeToolHalt1 do
    @behaviour ADK.Callback
    @impl true
    def before_tool(_ctx), do: {:halt, {:ok, %{"test" => "callback_1_response"}}}
  end

  defmodule BeforeToolHalt2 do
    @behaviour ADK.Callback
    @impl true
    def before_tool(_ctx), do: {:halt, {:ok, %{"test" => "callback_2_response"}}}
  end

  defmodule BeforeToolHalt3 do
    @behaviour ADK.Callback
    @impl true
    def before_tool(_ctx), do: {:halt, {:ok, %{"test" => "callback_3_response"}}}
  end

  # ── after_tool callback modules ───────────────────────────────────────────

  defmodule AfterToolNoop do
    @behaviour ADK.Callback
    # No after_tool defined → passthrough via run_after
  end

  defmodule AfterToolReplace1 do
    @behaviour ADK.Callback
    @impl true
    def after_tool(_result, _ctx), do: {:ok, %{"test" => "callback_1_response"}}
  end

  defmodule AfterToolReplace2 do
    @behaviour ADK.Callback
    @impl true
    def after_tool(_result, _ctx), do: {:ok, %{"test" => "callback_2_response"}}
  end

  defmodule AfterToolReplace3 do
    @behaviour ADK.Callback
    @impl true
    def after_tool(_result, _ctx), do: {:ok, %{"test" => "callback_3_response"}}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp tool_result(value), do: {:ok, value}

  defp unwrap_result({:halt, {:ok, val}}), do: val
  defp unwrap_result({:ok, val}), do: val

  # ── Single before_tool callback (mirrors test_async_before_tool_callback) ──

  describe "single before_tool callback" do
    test "halts with mock response — tool execution is skipped" do
      callbacks = [BeforeToolHalt1]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}

      result = ADK.Callback.run_before(callbacks, :before_tool, ctx)

      assert {:halt, {:ok, resp}} = result
      assert resp == %{"test" => "callback_1_response"}
    end

    test "noop continues — tool would execute" do
      callbacks = [BeforeToolNoop]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}

      result = ADK.Callback.run_before(callbacks, :before_tool, ctx)

      assert {:cont, _} = result
    end
  end

  # ── Single after_tool callback (mirrors test_async_after_tool_callback) ───

  describe "single after_tool callback" do
    test "replaces tool result with mock response" do
      callbacks = [AfterToolReplace1]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}
      original = tool_result(%{"initial" => "response"})

      result = ADK.Callback.run_after(callbacks, :after_tool, original, ctx)

      assert {:ok, resp} = result
      assert resp == %{"test" => "callback_1_response"}
    end

    test "noop passes through original tool result" do
      callbacks = [AfterToolNoop]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}
      original = tool_result(%{"initial" => "response"})

      result = ADK.Callback.run_after(callbacks, :after_tool, original, ctx)

      assert {:ok, resp} = result
      assert resp == %{"initial" => "response"}
    end
  end

  # ── before_tool callback chain (mirrors test_before_tool_callbacks_chain) ──

  describe "before_tool callback chain" do
    @doc """
    Python: middle_async_callback_returns
    Callbacks: [noop, halt("callback_2_response"), halt("callback_3_response"), noop]
    Expected: "callback_2_response" — second callback halts, third+fourth never run.
    """
    test "middle callback halts — stops chain at second callback" do
      callbacks = [BeforeToolNoop, BeforeToolHalt2, BeforeToolHalt3, BeforeToolNoop]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}

      result = ADK.Callback.run_before(callbacks, :before_tool, ctx)

      assert {:halt, {:ok, resp}} = result
      assert resp == %{"test" => "callback_2_response"}
    end

    @doc """
    Python: all_callbacks_return_none
    Callbacks: [noop, noop, noop, noop]
    Expected: all continue → {:cont, ctx} (tool would execute normally).
    """
    test "all noop callbacks continue — tool would execute" do
      callbacks = [BeforeToolNoop, BeforeToolNoop, BeforeToolNoop, BeforeToolNoop]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}

      result = ADK.Callback.run_before(callbacks, :before_tool, ctx)

      assert {:cont, _} = result
    end

    @doc """
    Python: first_sync_callback_returns
    Callbacks: [halt("callback_1_response"), halt("callback_2_response")]
    Expected: "callback_1_response" — first callback halts, second never runs.
    """
    test "first callback halts — second never runs" do
      callbacks = [BeforeToolHalt1, BeforeToolHalt2]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}

      result = ADK.Callback.run_before(callbacks, :before_tool, ctx)

      assert {:halt, {:ok, resp}} = result
      assert resp == %{"test" => "callback_1_response"}
    end

    test "empty callback list continues" do
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}

      result = ADK.Callback.run_before([], :before_tool, ctx)

      assert {:cont, ^ctx} = result
    end

    test "modules without before_tool are skipped in chain" do
      callbacks = [AfterToolNoop, BeforeToolNoop, AfterToolNoop, BeforeToolHalt1]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}

      result = ADK.Callback.run_before(callbacks, :before_tool, ctx)

      assert {:halt, {:ok, resp}} = result
      assert resp == %{"test" => "callback_1_response"}
    end
  end

  # ── after_tool callback chain (mirrors test_after_tool_callbacks_chain) ────

  describe "after_tool callback chain" do
    @doc """
    Python: middle_async_callback_returns
    Callbacks: [noop, replace("callback_2_response"), replace("callback_3_response"), noop]

    NOTE: Python's after_tool chain short-circuits on first non-None return.
    Elixir's run_after threads through ALL callbacks (no short-circuit).
    So callback_3 replaces callback_2's output → final is "callback_3_response".
    """
    test "middle callback replaces — subsequent callbacks see replaced response" do
      callbacks = [AfterToolNoop, AfterToolReplace2, AfterToolReplace3, AfterToolNoop]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}
      original = tool_result(%{"initial" => "response"})

      result = ADK.Callback.run_after(callbacks, :after_tool, original, ctx)

      # Elixir after_tool chains compose: cb2 replaces, then cb3 replaces cb2's output
      assert unwrap_result(result) == %{"test" => "callback_3_response"}
    end

    @doc """
    Python: all_callbacks_return_none
    All noops → original tool result passes through.
    """
    test "all noop callbacks pass through original result" do
      callbacks = [AfterToolNoop, AfterToolNoop, AfterToolNoop, AfterToolNoop]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}
      original = tool_result(%{"initial" => "response"})

      result = ADK.Callback.run_after(callbacks, :after_tool, original, ctx)

      assert unwrap_result(result) == %{"initial" => "response"}
    end

    @doc """
    Python: first_sync_callback_returns
    First callback replaces → subsequent callbacks see replaced response.
    """
    test "first callback replaces — second sees the replaced value" do
      callbacks = [AfterToolReplace1, AfterToolReplace2]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}
      original = tool_result(%{"initial" => "response"})

      result = ADK.Callback.run_after(callbacks, :after_tool, original, ctx)

      # cb1 replaces, then cb2 replaces cb1's output
      assert unwrap_result(result) == %{"test" => "callback_2_response"}
    end

    test "empty callback list returns original" do
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}
      original = tool_result(%{"initial" => "response"})

      result = ADK.Callback.run_after([], :after_tool, original, ctx)

      assert unwrap_result(result) == %{"initial" => "response"}
    end

    test "modules without after_tool are skipped in chain" do
      callbacks = [BeforeToolNoop, AfterToolReplace1, BeforeToolNoop]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}
      original = tool_result(%{"initial" => "response"})

      result = ADK.Callback.run_after(callbacks, :after_tool, original, ctx)

      assert unwrap_result(result) == %{"test" => "callback_1_response"}
    end

    test "error propagates through noop chain" do
      callbacks = [AfterToolNoop, AfterToolNoop]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}
      error = {:error, :tool_failed}

      result = ADK.Callback.run_after(callbacks, :after_tool, error, ctx)

      assert result == {:error, :tool_failed}
    end
  end

  # ── Context threading tests ───────────────────────────────────────────────

  describe "before_tool context threading" do
    defmodule BeforeToolTracker do
      @behaviour ADK.Callback
      @impl true
      def before_tool(ctx) do
        order = Map.get(ctx, :call_order, [])
        {:cont, Map.put(ctx, :call_order, order ++ [:tracker])}
      end
    end

    defmodule BeforeToolTagger do
      @behaviour ADK.Callback
      @impl true
      def before_tool(ctx) do
        order = Map.get(ctx, :call_order, [])
        {:cont, Map.put(ctx, :call_order, order ++ [:tagger])}
      end
    end

    defmodule BeforeToolHaltWithOrder do
      @behaviour ADK.Callback
      @impl true
      def before_tool(ctx) do
        order = Map.get(ctx, :call_order, []) ++ [:halter]
        {:halt, {:ok, %{"halted_at" => length(order), "order" => order}}}
      end
    end

    test "callbacks thread context modifications in order" do
      callbacks = [BeforeToolTracker, BeforeToolTagger]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "fn"}, tool_args: %{}}

      assert {:cont, result_ctx} = ADK.Callback.run_before(callbacks, :before_tool, ctx)

      assert result_ctx[:call_order] == [:tracker, :tagger]
    end

    test "callbacks thread context then halt preserves order" do
      callbacks = [BeforeToolTracker, BeforeToolTagger, BeforeToolHaltWithOrder]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "fn"}, tool_args: %{}}

      assert {:halt, {:ok, resp}} = ADK.Callback.run_before(callbacks, :before_tool, ctx)

      assert resp["order"] == [:tracker, :tagger, :halter]
      assert resp["halted_at"] == 3
    end
  end

  describe "after_tool composition" do
    defmodule AfterToolAppendA do
      @behaviour ADK.Callback
      @impl true
      def after_tool({:ok, result}, _ctx) do
        {:ok, Map.update(result, "chain", "A", &(&1 <> "+A"))}
      end

      def after_tool(err, _ctx), do: err
    end

    defmodule AfterToolAppendB do
      @behaviour ADK.Callback
      @impl true
      def after_tool({:ok, result}, _ctx) do
        {:ok, Map.update(result, "chain", "B", &(&1 <> "+B"))}
      end

      def after_tool(err, _ctx), do: err
    end

    defmodule AfterToolAppendC do
      @behaviour ADK.Callback
      @impl true
      def after_tool({:ok, result}, _ctx) do
        {:ok, Map.update(result, "chain", "C", &(&1 <> "+C"))}
      end

      def after_tool(err, _ctx), do: err
    end

    test "after_tool callbacks compose transformations left-to-right" do
      callbacks = [AfterToolAppendA, AfterToolAppendB, AfterToolAppendC]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "fn"}, tool_args: %{}}
      original = tool_result(%{"chain" => "base"})

      result = ADK.Callback.run_after(callbacks, :after_tool, original, ctx)

      assert {:ok, %{"chain" => "base+A+B+C"}} = result
    end

    test "mixed replace and append compose correctly" do
      callbacks = [AfterToolNoop, AfterToolReplace2, AfterToolAppendA, AfterToolNoop]
      ctx = %{agent: %{name: "agent"}, tool: %{name: "fn"}, tool_args: %{}}
      original = tool_result(%{"initial" => "response"})

      result = ADK.Callback.run_after(callbacks, :after_tool, original, ctx)

      # noop → replace with callback_2 map → append "+A" to "chain" key (new key)
      assert {:ok, resp} = result
      assert resp["test"] == "callback_2_response"
      assert resp["chain"] == "A"
    end
  end
end
