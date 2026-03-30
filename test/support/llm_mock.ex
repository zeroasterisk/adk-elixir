defmodule ADK.LLM.TestHelper do
  @moduledoc """
  Ergonomic test helpers for mocking LLM responses.

  Provides convenience functions for building mock responses and setting up
  the `ADK.LLM.MockBackend` for tests.

  ## Usage in tests

      use ADK.LLM.TestHelper

      test "my agent test" do
        setup_mock_llm([
          mock_response("Hello!"),
          mock_tool_call("search", %{"query" => "elixir"}),
          mock_response("Found it!")
        ])

        # ... run your agent code ...

        assert_called(1)  # at least 1 call made
        assert call_count() == 3
      end
  """

  defmacro __using__(_opts) do
    quote do
      import ADK.LLM.TestHelper

      setup do
        ADK.LLM.TestHelper.init_mock_backend()

        on_exit(fn ->
          ADK.LLM.TestHelper.cleanup_mock_backend()
        end)

        :ok
      end
    end
  end

  # --- Setup ---

  @doc """
  Start the MockBackend agent and configure it as the LLM backend.
  Called automatically when using `use ADK.LLM.TestHelper`.
  """
  def init_mock_backend do
    name = :"llm_mock_#{:erlang.unique_integer([:positive])}"

    {:ok, _pid} = ADK.LLM.MockBackend.start_link(name: name)
    Process.put(:adk_mock_backend_name, name)

    # Also set the process-dict so ADK.LLM.MockBackend.generate/2 finds it
    :ok
  end

  @doc "Clean up the MockBackend agent."
  def cleanup_mock_backend do
    case Process.get(:adk_mock_backend_name) do
      nil ->
        :ok

      name ->
        try do
          ADK.LLM.MockBackend.stop(name)
        catch
          :exit, _ -> :ok
        end
    end
  end

  @doc """
  Set up mock LLM responses for the current test.

  Takes a list of response tuples (as returned by `mock_response/1`,
  `mock_tool_call/2`, `mock_error/1`) and queues them in the MockBackend.

  Also sets responses on `ADK.LLM.Mock` (process dictionary) so tests
  that use the default mock backend also work.
  """
  def setup_mock_llm(responses) do
    name = Process.get(:adk_mock_backend_name, ADK.LLM.MockBackend)
    ADK.LLM.MockBackend.set_responses(responses, name)

    # Also set on the process-dict mock for compatibility
    pd_responses =
      Enum.map(responses, fn
        {:ok, resp} -> resp
        {:error, _} = err -> err
      end)

    ADK.LLM.Mock.set_responses(pd_responses)
  end

  # --- Response builders ---

  @doc "Build a standard text response."
  def mock_response(text) when is_binary(text) do
    {:ok,
     %{
       content: %{role: :model, parts: [%{text: text}]},
       usage_metadata: nil
     }}
  end

  @doc "Build a tool/function call response."
  def mock_tool_call(name, args \\ %{}) do
    {:ok,
     %{
       content: %{
         role: :model,
         parts: [%{function_call: %{name: name, args: args}}]
       },
       usage_metadata: nil
     }}
  end

  @doc "Build an error response."
  def mock_error(reason) do
    {:error, reason}
  end

  @doc "Build a response with custom parts."
  def mock_parts(parts) when is_list(parts) do
    {:ok,
     %{
       content: %{role: :model, parts: parts},
       usage_metadata: nil
     }}
  end

  # --- Assertions ---

  @doc "Assert at least `n` calls were made to the mock backend."
  def assert_called(n \\ 1) do
    name = Process.get(:adk_mock_backend_name, ADK.LLM.MockBackend)
    count = ADK.LLM.MockBackend.call_count(name)

    unless count >= n do
      raise ExUnit.AssertionError,
        message: "Expected at least #{n} call(s) to mock LLM, got #{count}"
    end
  end

  @doc "Return the call count."
  def call_count do
    name = Process.get(:adk_mock_backend_name, ADK.LLM.MockBackend)
    ADK.LLM.MockBackend.call_count(name)
  end

  @doc "Return the last call."
  def last_call do
    name = Process.get(:adk_mock_backend_name, ADK.LLM.MockBackend)
    ADK.LLM.MockBackend.last_call(name)
  end

  @doc "Return all calls."
  def all_calls do
    name = Process.get(:adk_mock_backend_name, ADK.LLM.MockBackend)
    ADK.LLM.MockBackend.calls(name)
  end
end
