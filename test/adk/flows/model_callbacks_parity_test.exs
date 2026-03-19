defmodule ADK.Flows.ModelCallbacksParityTest do
  @moduledoc """
  Parity tests for Python's `tests/unittests/flows/llm_flows/test_model_callbacks.py`.

  The Python test verifies before_model, after_model, and on_model_error callbacks
  at the Runner integration level (InMemoryRunner → Agent → LLM pipeline).

  In Elixir ADK, before_model/after_model callbacks are defined on `ADK.Callback`
  and used via `run_before/3`, `run_after/4`, and `run_on_error/3`. These tests
  mirror the Python tests at the callback module level, verifying the same
  behavioral contracts:

  1. `test_before_model_callback` — halts and returns canned response (LLM skipped)
  2. `test_before_model_callback_noop` — continues, LLM runs
  3. `test_before_model_callback_end` — halts (same as #1 in Python)
  4. `test_after_model_callback` — replaces LLM response
  5. `test_after_model_callback_noop` — passes through original response
  6. `test_on_model_callback_model_error_noop` — error propagates (re-raises)
  7. `test_on_model_callback_model_error_modify_model_response` — fallback response
  """
  use ExUnit.Case, async: true

  # ── Callback Modules (mirrors Python's MockBeforeModelCallback etc.) ───

  defmodule MockBeforeModelCallback do
    @moduledoc """
    Mirrors Python's `MockBeforeModelCallback` — halts before_model and returns
    a canned "before_model_callback" response, bypassing the LLM.
    """
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

  defmodule MockAfterModelCallback do
    @moduledoc """
    Mirrors Python's `MockAfterModelCallback` — replaces the LLM response
    with "after_model_callback".
    """
    @behaviour ADK.Callback

    @impl true
    def after_model({:ok, _response}, _ctx) do
      {:ok,
       %{
         content: %{role: :model, parts: [%{text: "after_model_callback"}]},
         usage_metadata: nil
       }}
    end

    def after_model({:error, _} = err, _ctx), do: err
  end

  defmodule MockOnModelCallback do
    @moduledoc """
    Mirrors Python's `MockOnModelCallback` — on model error, returns a fallback
    response instead of propagating the error.
    """
    @behaviour ADK.Callback

    @impl true
    def on_model_error({:error, _reason}, _ctx) do
      {:fallback,
       {:ok,
        %{
          content: %{role: :model, parts: [%{text: "on_model_error_callback_response"}]},
          usage_metadata: nil
        }}}
    end
  end

  defmodule NoopCallback do
    @moduledoc """
    Mirrors Python's `noop_callback` — all hooks continue/pass through.
    """
    @behaviour ADK.Callback

    @impl true
    def before_model(ctx), do: {:cont, ctx}

    @impl true
    def after_model(response, _ctx), do: response

    @impl true
    def on_model_error(err, _ctx), do: err
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp make_ctx do
    %{agent: %{name: "root_agent"}, context: %{}}
  end

  defp make_response(text) do
    {:ok, %{content: %{role: :model, parts: [%{text: text}]}, usage_metadata: nil}}
  end

  defp response_text({:ok, resp}), do: hd(resp.content.parts).text
  defp response_text({:halt, {:ok, resp}}), do: hd(resp.content.parts).text

  # ── Tests: before_model (mirrors Python test_before_model_callback*) ───

  describe "before_model callback (Python: test_before_model_callback)" do
    @doc """
    Python: test_before_model_callback

    When before_model_callback returns a response, the LLM call is skipped
    and the callback's response is used directly.

    Python asserts: simplify_events == [('root_agent', 'before_model_callback')]
    """
    test "halts and returns canned response — LLM would be skipped" do
      result = ADK.Callback.run_before([MockBeforeModelCallback], :before_model, make_ctx())

      assert {:halt, {:ok, _response}} = result
      assert response_text(result) == "before_model_callback"
    end

    @doc """
    Python: test_before_model_callback_noop

    When before_model_callback returns None, the LLM call proceeds normally
    and the model's response is used.

    Python asserts: simplify_events == [('root_agent', 'model_response')]
    """
    test "noop continues — LLM would be called" do
      result = ADK.Callback.run_before([NoopCallback], :before_model, make_ctx())

      assert {:cont, _ctx} = result
      # In Python, LLM would run and return "model_response"
      # Here we verify the callback doesn't halt, so LLM would proceed
    end

    @doc """
    Python: test_before_model_callback_end

    Identical to test_before_model_callback — before_model halts with response.

    Python asserts: simplify_events == [('root_agent', 'before_model_callback')]
    """
    test "halt ends execution — same as before_model_callback test" do
      result = ADK.Callback.run_before([MockBeforeModelCallback], :before_model, make_ctx())

      assert {:halt, {:ok, _}} = result
      assert response_text(result) == "before_model_callback"
    end
  end

  # ── Tests: after_model (mirrors Python test_after_model_callback*) ─────

  describe "after_model callback (Python: test_after_model_callback)" do
    @doc """
    Python: test_after_model_callback

    When after_model_callback returns a new response, the original model
    response is replaced with the callback's response.

    Python asserts: simplify_events == [('root_agent', 'after_model_callback')]
    """
    test "replaces model response with callback response" do
      model_response = make_response("model_response")
      result = ADK.Callback.run_after([MockAfterModelCallback], :after_model, model_response, make_ctx())

      assert response_text(result) == "after_model_callback"
    end

    @doc """
    Python: test_after_model_callback_noop

    When after_model_callback returns None (noop), the original model response
    passes through unchanged.

    Python asserts: simplify_events == [('root_agent', 'model_response')]
    """
    test "noop passes through original model response" do
      model_response = make_response("model_response")
      result = ADK.Callback.run_after([NoopCallback], :after_model, model_response, make_ctx())

      assert response_text(result) == "model_response"
    end
  end

  # ── Tests: on_model_error (mirrors Python test_on_model_callback*) ─────

  describe "on_model_error callback (Python: test_on_model_callback_model_error*)" do
    @doc """
    Python: test_on_model_callback_model_error_noop

    When on_model_error_callback is noop (returns None), the original error
    propagates and is re-raised. Python raises SystemError.

    Python asserts: pytest.raises(SystemError)
    """
    test "noop propagates the error" do
      error = {:error, %RuntimeError{message: "error"}}
      result = ADK.Callback.run_on_error([NoopCallback], error, make_ctx())

      # Noop on_model_error returns the error unchanged → it would re-raise
      assert {:error, %RuntimeError{message: "error"}} = result
    end

    @doc """
    Python: test_on_model_callback_model_error_modify_model_response

    When on_model_error_callback returns a response, the error is swallowed
    and the callback's response is used as a fallback.

    Python asserts: simplify_events == [('root_agent', 'on_model_error_callback_response')]
    """
    test "returns fallback response instead of error" do
      error = {:error, %RuntimeError{message: "error"}}
      result = ADK.Callback.run_on_error([MockOnModelCallback], error, make_ctx())

      assert {:fallback, {:ok, response}} = result
      assert hd(response.content.parts).text == "on_model_error_callback_response"
    end
  end

  # ── Integration: before_model halt through Runner (via before_agent) ───

  describe "integration — before_model halt bypasses LLM via Runner pipeline" do
    @doc """
    Since before_model isn't wired into LlmAgent.do_run yet, we test the
    equivalent pattern through before_agent (which IS wired into Runner).
    This mirrors how the Python test verifies the LLM is skipped when
    before_model returns a response.
    """

    defmodule BeforeAgentHaltWithModelResponse do
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

    defmodule AfterAgentReplaceResponse do
      @behaviour ADK.Callback

      @impl true
      def after_agent(_events, _ctx) do
        event =
          ADK.Event.new(%{
            author: "agent",
            content: %{"parts" => [%{"text" => "after_model_callback"}]}
          })

        [event]
      end
    end

    test "before_agent halt produces callback response, LLM not called" do
      agent =
        ADK.Agent.LlmAgent.new(
          model: "gemini-1.5-flash",
          name: "root_agent",
          instruction: "Say hello"
        )

      runner = ADK.Runner.new(app_name: "test", agent: agent)

      # LLM.Mock has no responses queued — if LLM were called it would echo
      events =
        ADK.Runner.run(runner, "user1", "before_model_halt_session", "test",
          callbacks: [BeforeAgentHaltWithModelResponse]
        )

      assert length(events) == 1

      text =
        events
        |> hd()
        |> Map.get(:content)
        |> Map.get("parts")
        |> hd()
        |> Map.get("text")

      assert text == "before_model_callback"
    end

    test "before_agent noop lets LLM run, returns model response" do
      ADK.LLM.Mock.set_responses(["model_response"])

      agent =
        ADK.Agent.LlmAgent.new(
          model: "gemini-1.5-flash",
          name: "root_agent",
          instruction: "Say hello"
        )

      runner = ADK.Runner.new(app_name: "test", agent: agent)

      events =
        ADK.Runner.run(runner, "user1", "before_model_noop_session", "test",
          callbacks: [NoopCallback]
        )

      assert length(events) >= 1

      # The LLM was called and returned "model_response"
      text =
        events
        |> hd()
        |> Map.get(:content)
        |> get_in([:parts, Access.at(0), :text])

      assert text == "model_response"
    end

    test "after_agent replaces all events with callback response" do
      ADK.LLM.Mock.set_responses(["model_response"])

      agent =
        ADK.Agent.LlmAgent.new(
          model: "gemini-1.5-flash",
          name: "root_agent",
          instruction: "Say hello"
        )

      runner = ADK.Runner.new(app_name: "test", agent: agent)

      events =
        ADK.Runner.run(runner, "user1", "after_model_replace_session", "test",
          callbacks: [AfterAgentReplaceResponse]
        )

      assert length(events) == 1

      text =
        events
        |> hd()
        |> Map.get(:content)
        |> Map.get("parts")
        |> hd()
        |> Map.get("text")

      assert text == "after_model_callback"
    end
  end

  # ── Edge cases not in Python but valuable for parity ───────────────────

  describe "edge cases" do
    test "before_model with empty callback list continues" do
      result = ADK.Callback.run_before([], :before_model, make_ctx())
      assert {:cont, _} = result
    end

    test "after_model with empty callback list returns original" do
      original = make_response("model_response")
      result = ADK.Callback.run_after([], :after_model, original, make_ctx())
      assert response_text(result) == "model_response"
    end

    test "on_model_error with empty callback list returns error" do
      error = {:error, :system_error}
      result = ADK.Callback.run_on_error([], error, make_ctx())
      assert result == {:error, :system_error}
    end

    test "after_model error passthrough when callback handles errors" do
      error = {:error, :llm_failure}
      result = ADK.Callback.run_after([MockAfterModelCallback], :after_model, error, make_ctx())
      # MockAfterModelCallback returns error unchanged for {:error, _}
      assert result == {:error, :llm_failure}
    end

    test "on_model_error with multiple callbacks — first fallback wins" do
      error = {:error, :system_error}
      result = ADK.Callback.run_on_error([NoopCallback, MockOnModelCallback], error, make_ctx())

      # NoopCallback passes error through, MockOnModelCallback returns fallback
      assert {:fallback, {:ok, response}} = result
      assert hd(response.content.parts).text == "on_model_error_callback_response"
    end

    test "on_model_error noop followed by noop propagates error" do
      error = {:error, :system_error}
      result = ADK.Callback.run_on_error([NoopCallback, NoopCallback], error, make_ctx())
      assert {:error, :system_error} = result
    end
  end
end
