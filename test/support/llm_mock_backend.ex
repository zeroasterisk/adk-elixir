defmodule ADK.LLM.MockBackend do
  @moduledoc """
  A configurable mock LLM backend for tests.

  Implements the `ADK.LLM` behaviour. Uses an Agent to store predetermined
  responses and record all calls, enabling sequential response playback
  and call assertions.

  ## Usage

      {:ok, pid} = ADK.LLM.MockBackend.start_link(responses: [
        {:ok, %{content: %{role: :model, parts: [%{text: "hi"}]}, usage_metadata: nil}}
      ])

      # Configure as the backend
      Application.put_env(:adk, :llm_backend, ADK.LLM.MockBackend)

      # After calls, assert:
      assert ADK.LLM.MockBackend.call_count(pid) == 1
  """

  @behaviour ADK.LLM

  use Agent

  # --- Agent lifecycle ---

  @doc "Start the mock backend agent with a list of responses."
  def start_link(opts \\ []) do
    responses = Keyword.get(opts, :responses, [])
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(
      fn -> %{responses: responses, calls: []} end,
      name: name
    )
  end

  @doc "Stop the mock backend agent."
  def stop(name \\ __MODULE__) do
    Agent.stop(name)
  end

  @doc "Set new responses (replaces existing queue)."
  def set_responses(responses, name \\ __MODULE__) do
    Agent.update(name, fn state -> %{state | responses: responses} end)
  end

  # --- ADK.LLM behaviour ---

  @impl true
  def generate(model, request) do
    name = Process.get(:adk_mock_backend_name, __MODULE__)

    Agent.get_and_update(name, fn %{responses: responses, calls: calls} = state ->
      call = %{model: model, request: request, timestamp: System.monotonic_time()}
      new_calls = calls ++ [call]

      case responses do
        [response | rest] ->
          {response, %{state | responses: rest, calls: new_calls}}

        [] ->
          # Default echo response when no responses queued
          echo = {:ok, echo_response(request)}
          {echo, %{state | calls: new_calls}}
      end
    end)
  end

  # --- Assertions ---

  @doc "Return the number of calls made."
  def call_count(name \\ __MODULE__) do
    Agent.get(name, fn %{calls: calls} -> length(calls) end)
  end

  @doc "Return all recorded calls."
  def calls(name \\ __MODULE__) do
    Agent.get(name, fn %{calls: calls} -> calls end)
  end

  @doc "Return the last call, or nil."
  def last_call(name \\ __MODULE__) do
    Agent.get(name, fn %{calls: calls} -> List.last(calls) end)
  end

  @doc "Return the number of responses remaining in the queue."
  def responses_remaining(name \\ __MODULE__) do
    Agent.get(name, fn %{responses: r} -> length(r) end)
  end

  @doc "Reset calls and responses."
  def reset(name \\ __MODULE__, responses \\ []) do
    Agent.update(name, fn _state -> %{responses: responses, calls: []} end)
  end

  # --- Private ---

  defp echo_response(request) do
    user_text =
      case request do
        %{messages: [_ | _] = msgs} ->
          msgs
          |> Enum.reverse()
          |> Enum.find_value("", fn
            %{role: :user, parts: [%{text: t} | _]} -> t
            _ -> nil
          end)

        _ ->
          ""
      end

    %{content: %{role: :model, parts: [%{text: "Mock: #{user_text}"}]}, usage_metadata: nil}
  end
end
