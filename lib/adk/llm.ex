defmodule ADK.LLM do
  @moduledoc "LLM behaviour and mock implementation for testing."

  @type response :: %{
          content: map(),
          usage_metadata: map() | nil
        }

  @callback generate(model :: String.t(), request :: map()) ::
              {:ok, response()} | {:error, term()}

  @doc "Generate a response using the configured LLM backend."
  @spec generate(String.t(), map()) :: {:ok, response()} | {:error, term()}
  def generate(model, request) do
    backend().generate(model, request)
  end

  defp backend do
    Application.get_env(:adk, :llm_backend, ADK.LLM.Mock)
  end
end

defmodule ADK.LLM.Mock do
  @moduledoc """
  Mock LLM that echoes input or uses pattern matching.

  Configure responses via application env or process dictionary.
  """
  @behaviour ADK.LLM

  @impl true
  def generate(_model, request) do
    case Process.get(:adk_mock_responses) do
      [response | rest] ->
        Process.put(:adk_mock_responses, rest)
        {:ok, to_response(response)}

      [] ->
        {:ok, echo_response(request)}

      nil ->
        {:ok, echo_response(request)}
    end
  end

  @doc "Set mock responses for the current process."
  @spec set_responses([map() | String.t()]) :: :ok
  def set_responses(responses) do
    Process.put(:adk_mock_responses, responses)
    :ok
  end

  defp to_response(text) when is_binary(text) do
    %{content: %{role: :model, parts: [%{text: text}]}, usage_metadata: nil}
  end

  defp to_response(%{text: text}) do
    %{content: %{role: :model, parts: [%{text: text}]}, usage_metadata: nil}
  end

  defp to_response(%{function_call: fc}) do
    %{content: %{role: :model, parts: [%{function_call: fc}]}, usage_metadata: nil}
  end

  defp to_response(%{content: _} = resp), do: resp

  defp echo_response(request) do
    # Extract the user's message and echo it back
    user_text = extract_user_text(request)
    %{content: %{role: :model, parts: [%{text: "Echo: #{user_text}"}]}, usage_metadata: nil}
  end

  defp extract_user_text(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :user, parts: [%{text: t} | _]} -> t
      _ -> nil
    end)
  end

  defp extract_user_text(%{user_message: msg}), do: msg
  defp extract_user_text(_), do: ""
end
