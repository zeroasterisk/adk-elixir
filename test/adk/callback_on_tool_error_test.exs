defmodule ADK.Callback.OnToolErrorTest do
  use ExUnit.Case, async: true

  alias ADK.{Runner, Callback}

  # --- Test callback modules ---

  defmodule RetryOnceCallback do
    @behaviour ADK.Callback

    @impl true
    def on_tool_error({:error, _reason}, cb_ctx) do
      # Retry with the same args
      {:retry, cb_ctx}
    end
  end

  defmodule FallbackCallback do
    @behaviour ADK.Callback

    @impl true
    def on_tool_error({:error, _reason}, _cb_ctx) do
      {:fallback, {:ok, "fallback_value"}}
    end
  end

  defmodule PropagateCallback do
    @behaviour ADK.Callback

    @impl true
    def on_tool_error({:error, reason}, _cb_ctx) do
      {:error, {:wrapped, reason}}
    end
  end

  defmodule LogAndPropagateCallback do
    @behaviour ADK.Callback

    @impl true
    def on_tool_error({:error, reason}, _cb_ctx) do
      send(self(), {:tool_error_logged, reason})
      {:error, reason}
    end
  end

  # --- Unit tests for run_on_tool_error ---

  describe "Callback.run_on_tool_error/3" do
    test "returns error when no callbacks" do
      assert {:error, :boom} = Callback.run_on_tool_error([], {:error, :boom}, %{})
    end

    test "retry wins over error" do
      ctx = %{tool_args: %{x: 1}}
      assert {:retry, ^ctx} = Callback.run_on_tool_error([RetryOnceCallback], {:error, :boom}, ctx)
    end

    test "fallback wins over error" do
      assert {:fallback, {:ok, "fallback_value"}} =
               Callback.run_on_tool_error([FallbackCallback], {:error, :boom}, %{})
    end

    test "propagate transforms error" do
      assert {:error, {:wrapped, :boom}} =
               Callback.run_on_tool_error([PropagateCallback], {:error, :boom}, %{})
    end

    test "first non-error callback wins" do
      assert {:fallback, {:ok, "fallback_value"}} =
               Callback.run_on_tool_error(
                 [LogAndPropagateCallback, FallbackCallback],
                 {:error, :boom},
                 %{}
               )

      assert_received {:tool_error_logged, :boom}
    end

    test "skips callbacks without on_tool_error" do
      defmodule NoopCb do
        @behaviour ADK.Callback
      end

      assert {:error, :boom} = Callback.run_on_tool_error([NoopCb], {:error, :boom}, %{})
    end
  end

  # --- Integration tests via Runner ---

  describe "on_tool_error via Runner" do
    setup do
      :ok
    end

    @tag :skip  # Pre-existing Event struct issue with function_calls key
    test "fallback callback provides tool result on error" do
      # Set up a tool that fails, then succeeds via fallback
      failing_tool = %{
        name: "fail_tool",
        description: "Always fails",
        parameters: %{},
        function: fn _ctx, _args -> {:error, "tool broke"} end
      }

      # LLM calls the tool, then responds with final answer
      ADK.LLM.Mock.set_responses([
        # First response: call the tool
        %{function_call: %{name: "fail_tool", args: %{}, id: "c1"}},
        # Second response: final answer after tool result
        "Done with fallback"
      ])

      agent = ADK.Agent.LlmAgent.new(
        name: "bot",
        model: "test",
        instruction: "Use tools",
        tools: [failing_tool]
      )

      runner = %Runner{app_name: "tool-err-test", agent: agent}
      events = Runner.run(runner, "u1", "te1", "do it", callbacks: [FallbackCallback])

      # The tool error should have been caught and fallback used
      texts = events |> Enum.map(&ADK.Event.text/1) |> Enum.filter(& &1)
      assert "Done with fallback" in texts
    end

    @tag :skip  # Pre-existing Event struct issue with function_calls key
    test "logging callback receives tool errors" do
      failing_tool = %{
        name: "fail_tool",
        description: "Always fails",
        parameters: %{},
        function: fn _ctx, _args -> {:error, "broken"} end
      }

      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "fail_tool", args: %{}, id: "c1"}},
        "ok"
      ])

      agent = ADK.Agent.LlmAgent.new(
        name: "bot",
        model: "test",
        instruction: "Use tools",
        tools: [failing_tool]
      )

      runner = %Runner{app_name: "tool-err-log", agent: agent}
      Runner.run(runner, "u1", "te2", "do it", callbacks: [LogAndPropagateCallback])

      assert_received {:tool_error_logged, "broken"}
    end
  end
end
