# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Flows.LiveToolCallbacksParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_live_tool_callbacks.py`.

  Python tests "live" (streaming) tool callbacks — in Elixir, the callback
  system is unified (no separate live vs async path), so we test the same
  behavioral contracts through `ADK.Callback.run_before/3`, `run_after/4`,
  and `run_on_tool_error/3`.

  Python scenarios ported:
  - `test_live_async_before_tool_callback`   — before_tool halts with mock response
  - `test_live_async_after_tool_callback`    — after_tool replaces tool result
  - `test_live_sync_before_tool_callback`    — sync before_tool halts
  - `test_live_sync_after_tool_callback`     — sync after_tool replaces
  - `test_live_before_tool_callbacks_chain`  — CALLBACK_PARAMS chain (7 parametrized cases)
  - `test_live_after_tool_callbacks_chain`   — CALLBACK_PARAMS chain (7 parametrized cases)
  - `test_live_mixed_callbacks`              — before lets through, after transforms
  - `test_live_callback_compatibility_with_async` — both paths produce same result
  - `test_live_on_tool_error_callback_tool_not_found_noop` — noop error cb propagates
  - `test_live_on_tool_error_callback_tool_not_found_modify_tool_response` — error cb returns fallback

  Parity divergences:
  - Python distinguishes sync/async callbacks; Elixir callbacks are always
    synchronous modules, so sync vs async is a single before_tool/1 impl.
  - Python's live path is `handle_function_calls_live`; Elixir has one unified
    callback pipeline via `ADK.Callback`.
  """

  use ExUnit.Case, async: true

  alias ADK.Callback

  # ── Callback modules ──────────────────────────────────────────────────────

  # Before-tool: halt with a specific response
  defmodule BeforeToolHaltMock do
    @behaviour ADK.Callback
    @impl true
    def before_tool(_ctx), do: {:halt, {:ok, %{"test" => "before_tool_callback"}}}
  end

  defmodule BeforeToolHaltSync do
    @behaviour ADK.Callback
    @impl true
    def before_tool(_ctx), do: {:halt, {:ok, %{"test" => "sync_before_callback"}}}
  end

  defmodule BeforeToolHaltBypassed do
    @behaviour ADK.Callback
    @impl true
    def before_tool(_ctx), do: {:halt, {:ok, %{"bypassed" => "by_before_callback"}}}
  end

  # Before-tool: noop (continue)
  defmodule BeforeToolCont do
    @behaviour ADK.Callback
    @impl true
    def before_tool(ctx), do: {:cont, ctx}
  end

  # Before-tool: halt with empty map
  defmodule BeforeToolHaltEmpty do
    @behaviour ADK.Callback
    @impl true
    def before_tool(_ctx), do: {:halt, {:ok, %{}}}
  end

  # Before-tool: halt with "second" response
  defmodule BeforeToolHaltSecond do
    @behaviour ADK.Callback
    @impl true
    def before_tool(_ctx), do: {:halt, {:ok, %{"second" => "callback"}}}
  end

  # After-tool: replace with specific response
  defmodule AfterToolReplaceMock do
    @behaviour ADK.Callback
    @impl true
    def after_tool(_result, _ctx), do: {:ok, %{"test" => "after_tool_callback"}}
  end

  defmodule AfterToolReplaceSync do
    @behaviour ADK.Callback
    @impl true
    def after_tool(_result, _ctx), do: {:ok, %{"test" => "sync_after_callback"}}
  end

  # After-tool: noop (pass through)
  defmodule AfterToolNoop do
    @behaviour ADK.Callback
    # No after_tool defined → passthrough
  end

  # After-tool: replace with empty map
  defmodule AfterToolReplaceEmpty do
    @behaviour ADK.Callback
    @impl true
    def after_tool(_result, _ctx), do: {:ok, %{}}
  end

  # After-tool: replace with "second" response
  defmodule AfterToolReplaceSecond do
    @behaviour ADK.Callback
    @impl true
    def after_tool(_result, _ctx), do: {:ok, %{"second" => "callback"}}
  end

  # Before-tool: modifies args in context (lets tool run)
  defmodule BeforeToolModifyArgs do
    @behaviour ADK.Callback
    @impl true
    def before_tool(ctx) do
      updated_args = Map.put(ctx[:tool_args] || %{}, "modified_by_before", true)
      {:cont, Map.put(ctx, :tool_args, updated_args)}
    end
  end

  # After-tool: adds a key to the tool response
  defmodule AfterToolAddKey do
    @behaviour ADK.Callback
    @impl true
    def after_tool({:ok, result}, _ctx) do
      {:ok, Map.put(result, "modified_by_after", true)}
    end

    def after_tool(other, _ctx), do: other
  end

  # on_tool_error: noop (propagate)
  defmodule OnToolErrorNoop do
    @behaviour ADK.Callback
    @impl true
    def on_tool_error({:error, reason}, _cb_ctx), do: {:error, reason}
  end

  # on_tool_error: provide fallback
  defmodule OnToolErrorFallback do
    @behaviour ADK.Callback
    @impl true
    def on_tool_error({:error, _reason}, _cb_ctx) do
      {:fallback, {:ok, %{"result" => "on_tool_error_callback_response"}}}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp initial_response, do: {:ok, %{"initial" => "response"}}

  defp base_ctx do
    %{agent: %{name: "agent"}, tool: %{name: "simple_fn"}, tool_args: %{}}
  end

  # ── test_live_async_before_tool_callback ──────────────────────────────────

  describe "async before_tool callback (mirrors test_live_async_before_tool_callback)" do
    test "halts with mock response — tool execution is skipped" do
      result = Callback.run_before([BeforeToolHaltMock], :before_tool, base_ctx())

      assert {:halt, {:ok, resp}} = result
      assert resp == %{"test" => "before_tool_callback"}
    end
  end

  # ── test_live_async_after_tool_callback ───────────────────────────────────

  describe "async after_tool callback (mirrors test_live_async_after_tool_callback)" do
    test "replaces tool result with mock response" do
      result =
        Callback.run_after([AfterToolReplaceMock], :after_tool, initial_response(), base_ctx())

      assert {:ok, resp} = result
      assert resp == %{"test" => "after_tool_callback"}
    end
  end

  # ── test_live_sync_before_tool_callback ───────────────────────────────────

  describe "sync before_tool callback (mirrors test_live_sync_before_tool_callback)" do
    test "halts with sync response" do
      result = Callback.run_before([BeforeToolHaltSync], :before_tool, base_ctx())

      assert {:halt, {:ok, resp}} = result
      assert resp == %{"test" => "sync_before_callback"}
    end
  end

  # ── test_live_sync_after_tool_callback ────────────────────────────────────

  describe "sync after_tool callback (mirrors test_live_sync_after_tool_callback)" do
    test "replaces tool result with sync response" do
      result =
        Callback.run_after([AfterToolReplaceSync], :after_tool, initial_response(), base_ctx())

      assert {:ok, resp} = result
      assert resp == %{"test" => "sync_after_callback"}
    end
  end

  # ── test_live_before_tool_callbacks_chain (CALLBACK_PARAMS) ───────────────

  describe "before_tool callback chain (mirrors test_live_before_tool_callbacks_chain)" do
    @doc """
    Python CALLBACK_PARAMS[0]: single callback returns None → tool executes.
    """
    test "single cont callback — tool would execute (returns initial response)" do
      result = Callback.run_before([BeforeToolCont], :before_tool, base_ctx())

      assert {:cont, _ctx} = result
    end

    @doc """
    Python CALLBACK_PARAMS[1]: single async callback returns None → tool executes.
    (Elixir: same as above — no sync/async distinction.)
    """
    test "single cont callback (async equivalent) — tool would execute" do
      result = Callback.run_before([BeforeToolCont], :before_tool, base_ctx())

      assert {:cont, _ctx} = result
    end

    @doc """
    Python CALLBACK_PARAMS[2]: single callback returns {} → skips tool.
    """
    test "single halt-empty callback — tool skipped with empty map" do
      result = Callback.run_before([BeforeToolHaltEmpty], :before_tool, base_ctx())

      assert {:halt, {:ok, resp}} = result
      assert resp == %{}
    end

    @doc """
    Python CALLBACK_PARAMS[3]: single async callback returns {} → skips tool.
    """
    test "single halt-empty callback (async equivalent) — tool skipped" do
      result = Callback.run_before([BeforeToolHaltEmpty], :before_tool, base_ctx())

      assert {:halt, {:ok, resp}} = result
      assert resp == %{}
    end

    @doc """
    Python CALLBACK_PARAMS[4]: chain [halt_empty, halt_second].
    Python: first returns {} (doesn't stop chain), second returns {"second": "callback"}.
    Elixir: first halt stops the chain → result is empty map.

    NOTE: Python's before_tool chain treats {} as "not None" but continues chain.
    Elixir's run_before halts on ANY {:halt, _}. This is a known divergence.
    """
    test "chain — first halt stops chain (Elixir halt semantics)" do
      result =
        Callback.run_before(
          [BeforeToolHaltEmpty, BeforeToolHaltSecond],
          :before_tool,
          base_ctx()
        )

      # Elixir: first halt wins — second callback never runs
      assert {:halt, {:ok, resp}} = result
      assert resp == %{}
    end

    @doc """
    Python CALLBACK_PARAMS[5]: chain [cont(None), halt_empty].
    First returns None → continues, second returns {} → halts.
    """
    test "chain — first cont then second halt" do
      result =
        Callback.run_before(
          [BeforeToolCont, BeforeToolHaltEmpty],
          :before_tool,
          base_ctx()
        )

      assert {:halt, {:ok, resp}} = result
      assert resp == %{}
    end

    @doc """
    Python CALLBACK_PARAMS[6]: chain [cont(None), cont(None)] → tool executes.
    """
    test "chain — all cont callbacks let tool execute" do
      result =
        Callback.run_before(
          [BeforeToolCont, BeforeToolCont],
          :before_tool,
          base_ctx()
        )

      assert {:cont, _ctx} = result
    end
  end

  # ── test_live_after_tool_callbacks_chain (CALLBACK_PARAMS) ────────────────

  describe "after_tool callback chain (mirrors test_live_after_tool_callbacks_chain)" do
    @doc """
    Python CALLBACK_PARAMS[0]: single noop → original response passes through.
    """
    test "single noop callback — original response passes through" do
      result =
        Callback.run_after([AfterToolNoop], :after_tool, initial_response(), base_ctx())

      assert {:ok, resp} = result
      assert resp == %{"initial" => "response"}
    end

    @doc """
    Python CALLBACK_PARAMS[2]: single callback returns {} → replaces response.
    """
    test "single replace-empty callback — response is empty map" do
      result =
        Callback.run_after([AfterToolReplaceEmpty], :after_tool, initial_response(), base_ctx())

      assert {:ok, resp} = result
      assert resp == %{}
    end

    @doc """
    Python CALLBACK_PARAMS[4]: chain [replace_empty, replace_second].
    Elixir: both compose — first replaces with {}, second replaces with {"second": "callback"}.
    """
    test "chain — both callbacks compose, last wins" do
      result =
        Callback.run_after(
          [AfterToolReplaceEmpty, AfterToolReplaceSecond],
          :after_tool,
          initial_response(),
          base_ctx()
        )

      assert {:ok, resp} = result
      assert resp == %{"second" => "callback"}
    end

    @doc """
    Python CALLBACK_PARAMS[5]: chain [noop, replace_empty].
    First passes through, second replaces with {}.
    """
    test "chain — noop then replace" do
      result =
        Callback.run_after(
          [AfterToolNoop, AfterToolReplaceEmpty],
          :after_tool,
          initial_response(),
          base_ctx()
        )

      assert {:ok, resp} = result
      assert resp == %{}
    end

    @doc """
    Python CALLBACK_PARAMS[6]: chain [noop, noop] → original passes through.
    """
    test "chain — all noop callbacks pass through original" do
      result =
        Callback.run_after(
          [AfterToolNoop, AfterToolNoop],
          :after_tool,
          initial_response(),
          base_ctx()
        )

      assert {:ok, resp} = result
      assert resp == %{"initial" => "response"}
    end
  end

  # ── test_live_mixed_callbacks ─────────────────────────────────────────────

  describe "mixed before + after callbacks (mirrors test_live_mixed_callbacks)" do
    test "before modifies context args, after modifies response" do
      ctx = base_ctx()

      # Simulate: before_tool modifies args and continues
      {:cont, modified_ctx} = Callback.run_before([BeforeToolModifyArgs], :before_tool, ctx)

      # Verify before_tool modified the args
      assert modified_ctx[:tool_args]["modified_by_before"] == true

      # Simulate: tool runs and returns initial response, then after_tool transforms it
      result =
        Callback.run_after([AfterToolAddKey], :after_tool, initial_response(), modified_ctx)

      assert {:ok, resp} = result
      assert resp["modified_by_after"] == true
      # Original response still present
      assert resp["initial"] == "response"
    end

    test "before halts — after never needed (tool was skipped)" do
      ctx = base_ctx()

      # before_tool halts — tool doesn't run
      {:halt, {:ok, before_resp}} =
        Callback.run_before([BeforeToolHaltMock], :before_tool, ctx)

      # In this scenario, the before_tool result IS the final response
      # (after_tool would not be called since tool execution was skipped)
      assert before_resp == %{"test" => "before_tool_callback"}
    end
  end

  # ── test_live_callback_compatibility_with_async ───────────────────────────

  describe "callback compatibility (mirrors test_live_callback_compatibility_with_async)" do
    test "same callback produces same result regardless of context" do
      # In Elixir, there is only one callback pipeline (no separate live vs async).
      # Verify that invoking the same callback from different "contexts" yields
      # identical results — this is trivially true but mirrors the Python assertion.

      ctx1 = %{agent: %{name: "agent_1"}, tool: %{name: "fn"}, tool_args: %{}}
      ctx2 = %{agent: %{name: "agent_2"}, tool: %{name: "fn"}, tool_args: %{}}

      result1 = Callback.run_before([BeforeToolHaltBypassed], :before_tool, ctx1)
      result2 = Callback.run_before([BeforeToolHaltBypassed], :before_tool, ctx2)

      assert {:halt, {:ok, resp1}} = result1
      assert {:halt, {:ok, resp2}} = result2
      assert resp1 == resp2
      assert resp1 == %{"bypassed" => "by_before_callback"}
    end
  end

  # ── test_live_on_tool_error_callback_tool_not_found_noop ──────────────────

  describe "on_tool_error noop (mirrors test_live_on_tool_error_callback_tool_not_found_noop)" do
    test "noop callback propagates the error" do
      error = {:error, {:tool_not_found, "nonexistent_function"}}
      ctx = base_ctx()

      result = Callback.run_on_tool_error([OnToolErrorNoop], error, ctx)

      # Noop just propagates — the error is returned unchanged
      assert {:error, {:tool_not_found, "nonexistent_function"}} = result
    end

    test "no callbacks at all propagates the error" do
      error = {:error, {:tool_not_found, "nonexistent_function"}}
      result = Callback.run_on_tool_error([], error, %{})

      assert {:error, {:tool_not_found, "nonexistent_function"}} = result
    end
  end

  # ── test_live_on_tool_error_callback_tool_not_found_modify_tool_response ──

  describe "on_tool_error fallback (mirrors test_live_on_tool_error_callback_tool_not_found_modify_tool_response)" do
    test "fallback callback provides custom response on tool-not-found error" do
      error = {:error, {:tool_not_found, "nonexistent_function"}}
      ctx = base_ctx()

      result = Callback.run_on_tool_error([OnToolErrorFallback], error, ctx)

      assert {:fallback, {:ok, resp}} = result
      assert resp == %{"result" => "on_tool_error_callback_response"}
    end

    test "fallback callback provides custom response on generic tool error" do
      error = {:error, :tool_execution_failed}
      ctx = base_ctx()

      result = Callback.run_on_tool_error([OnToolErrorFallback], error, ctx)

      assert {:fallback, {:ok, resp}} = result
      assert resp == %{"result" => "on_tool_error_callback_response"}
    end
  end

  # ── Chain ordering with mixed callbacks ───────────────────────────────────

  describe "chain ordering with mixed before/after in same module" do
    defmodule FullLifecycleCallback do
      @behaviour ADK.Callback

      @impl true
      def before_tool(ctx) do
        updated_args = Map.put(ctx[:tool_args] || %{}, "before_ran", true)
        {:cont, Map.put(ctx, :tool_args, updated_args)}
      end

      @impl true
      def after_tool({:ok, result}, _ctx) do
        {:ok, Map.put(result, "after_ran", true)}
      end

      def after_tool(other, _ctx), do: other
    end

    test "single module with both before_tool and after_tool" do
      ctx = base_ctx()

      # before_tool continues
      {:cont, modified_ctx} =
        Callback.run_before([FullLifecycleCallback], :before_tool, ctx)

      assert modified_ctx[:tool_args]["before_ran"] == true

      # Simulate tool execution, then after_tool transforms
      result =
        Callback.run_after(
          [FullLifecycleCallback],
          :after_tool,
          initial_response(),
          modified_ctx
        )

      assert {:ok, resp} = result
      assert resp["after_ran"] == true
      assert resp["initial"] == "response"
    end

    test "multiple lifecycle modules compose correctly" do
      defmodule LifecycleA do
        @behaviour ADK.Callback

        @impl true
        def before_tool(ctx) do
          order = Map.get(ctx, :before_order, [])
          {:cont, Map.put(ctx, :before_order, order ++ [:a])}
        end

        @impl true
        def after_tool({:ok, result}, _ctx) do
          chain = Map.get(result, "after_order", [])
          {:ok, Map.put(result, "after_order", chain ++ [:a])}
        end

        def after_tool(other, _ctx), do: other
      end

      defmodule LifecycleB do
        @behaviour ADK.Callback

        @impl true
        def before_tool(ctx) do
          order = Map.get(ctx, :before_order, [])
          {:cont, Map.put(ctx, :before_order, order ++ [:b])}
        end

        @impl true
        def after_tool({:ok, result}, _ctx) do
          chain = Map.get(result, "after_order", [])
          {:ok, Map.put(result, "after_order", chain ++ [:b])}
        end

        def after_tool(other, _ctx), do: other
      end

      ctx = base_ctx()
      callbacks = [LifecycleA, LifecycleB]

      # Both before_tool callbacks run in order
      {:cont, modified_ctx} = Callback.run_before(callbacks, :before_tool, ctx)
      assert modified_ctx[:before_order] == [:a, :b]

      # Both after_tool callbacks run in order
      result = Callback.run_after(callbacks, :after_tool, initial_response(), modified_ctx)
      assert {:ok, resp} = result
      assert resp["after_order"] == [:a, :b]
      assert resp["initial"] == "response"
    end
  end

  # ── on_tool_error chain ordering ──────────────────────────────────────────

  describe "on_tool_error chain ordering" do
    defmodule OnToolErrorLog do
      @behaviour ADK.Callback
      @impl true
      def on_tool_error({:error, reason}, _cb_ctx) do
        send(self(), {:tool_error_seen, reason})
        {:error, reason}
      end
    end

    test "first fallback wins — second callback never runs" do
      error = {:error, :broken}

      result =
        Callback.run_on_tool_error(
          [OnToolErrorFallback, OnToolErrorNoop],
          error,
          base_ctx()
        )

      assert {:fallback, {:ok, resp}} = result
      assert resp == %{"result" => "on_tool_error_callback_response"}
    end

    test "propagating callback followed by fallback — fallback wins" do
      error = {:error, :broken}

      result =
        Callback.run_on_tool_error(
          [OnToolErrorNoop, OnToolErrorFallback],
          error,
          base_ctx()
        )

      assert {:fallback, {:ok, resp}} = result
      assert resp == %{"result" => "on_tool_error_callback_response"}
    end

    test "logging callback runs then fallback wins" do
      error = {:error, :broken}

      result =
        Callback.run_on_tool_error(
          [OnToolErrorLog, OnToolErrorFallback],
          error,
          base_ctx()
        )

      # Log callback ran and propagated error, then fallback won
      assert_received {:tool_error_seen, :broken}
      assert {:fallback, {:ok, _resp}} = result
    end

    test "modules without on_tool_error are skipped" do
      error = {:error, :broken}

      result =
        Callback.run_on_tool_error(
          [BeforeToolCont, AfterToolNoop, OnToolErrorFallback],
          error,
          base_ctx()
        )

      assert {:fallback, {:ok, resp}} = result
      assert resp == %{"result" => "on_tool_error_callback_response"}
    end
  end
end
