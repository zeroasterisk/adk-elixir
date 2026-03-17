defmodule ADK.LLM.Gemma do
  @moduledoc """
  Gemma LLM backend, extending the Gemini backend with Gemma-specific
  preprocessing and postprocessing.

  Gemma models have two important differences from Gemini:

  1. **No native system instructions** — System instructions are converted into
     an initial `user` role message at the start of the conversation.

  2. **No native function calling** — Function declarations are serialized as a
     text system instruction, and function call/response turns in the conversation
     history are converted to plain text. Model responses are scanned for JSON
     that looks like a function call and converted back into structured parts.

  ## Supported models

  Only `gemma-3-*` models are supported. The default is `gemma-3-27b-it`.

  ## Usage

      config :adk, :llm_backend, ADK.LLM.Gemma

      # Or call directly
      ADK.LLM.Gemma.generate("gemma-3-12b-it", %{
        instruction: "You are helpful.",
        messages: [%{role: :user, parts: [%{text: "Hello"}]}]
      })

  ## References

  - https://ai.google.dev/gemma/docs/core/prompt-structure#system-instructions
  """

  @behaviour ADK.LLM

  require Logger

  @default_model "gemma-3-27b-it"

  @doc """
  Returns the list of supported model name patterns.
  """
  @spec supported_models() :: [String.t()]
  def supported_models, do: [~r/^gemma-3.*/]

  @impl true
  @spec generate(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def generate(model, request) do
    model = if model in [nil, ""], do: @default_model, else: model

    unless String.starts_with?(model, "gemma-") do
      raise ArgumentError,
            "Requesting a non-Gemma model (#{model}) with the Gemma LLM is not supported."
    end

    request = preprocess_request(request)

    case ADK.LLM.Gemini.generate(model, request) do
      {:ok, response} -> {:ok, extract_function_calls_from_response(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Preprocesses a request for Gemma model compatibility.

  - Converts function call/response turns in messages to plain text
  - Converts function declarations (tools) to a text system instruction
  - Converts the system instruction to an initial user message (deduped)

  Returns the updated request map.
  """
  @spec preprocess_request(map()) :: map()
  def preprocess_request(request) do
    request
    |> convert_function_turns_to_text()
    |> move_tools_to_instruction()
    |> move_instruction_to_user_message()
  end

  @doc """
  Extracts function calls from a Gemma model response.

  Gemma outputs function calls as JSON text rather than structured parts.
  This function scans the response text for JSON matching a function call
  schema and converts it to a structured function_call part.

  If extraction fails or the content doesn't match, the response is returned
  unchanged.
  """
  @spec extract_function_calls_from_response(map()) :: map()
  def extract_function_calls_from_response(%{content: nil} = response), do: response

  def extract_function_calls_from_response(%{content: %{parts: parts}} = response)
      when parts == [],
      do: response

  def extract_function_calls_from_response(%{content: %{parts: parts}} = response)
      when length(parts) > 1,
      do: response

  def extract_function_calls_from_response(%{content: %{parts: [part]} = content} = response) do
    text = Map.get(part, :text, "")

    if is_nil(text) or text == "" do
      response
    else
      case extract_json_function_call(text) do
        {:ok, function_call} ->
          new_part = %{function_call: function_call}
          %{response | content: %{content | parts: [new_part]}}

        :error ->
          response
      end
    end
  end

  def extract_function_calls_from_response(response), do: response

  # ---------------------------------------------------------------------------
  # Private helpers — preprocessing
  # ---------------------------------------------------------------------------

  # Convert function_call and function_response parts to plain text turns.
  defp convert_function_turns_to_text(%{messages: messages} = request)
       when is_list(messages) do
    new_messages =
      Enum.flat_map(messages, fn msg ->
        {new_parts, has_response?, has_call?} = convert_parts(msg.parts)

        cond do
          has_response? and new_parts != [] ->
            [%{msg | role: :user, parts: new_parts}]

          has_call? and new_parts != [] ->
            [%{msg | role: :model, parts: new_parts}]

          true ->
            [%{msg | parts: new_parts}]
        end
      end)

    %{request | messages: new_messages}
  end

  defp convert_function_turns_to_text(request), do: request

  defp convert_parts(parts) when is_list(parts) do
    Enum.reduce(parts, {[], false, false}, fn part, {acc_parts, has_resp, has_call} ->
      cond do
        match?(%{function_response: _}, part) ->
          fr = part.function_response
          text = "Invoking tool `#{fr.name}` produced: `#{Jason.encode!(fr.response)}`."
          {acc_parts ++ [%{text: text}], true, has_call}

        match?(%{function_call: _}, part) ->
          fc = part.function_call
          text = Jason.encode!(%{name: fc.name, args: fc.args})
          {acc_parts ++ [%{text: text}], has_resp, true}

        true ->
          {acc_parts ++ [part], has_resp, has_call}
      end
    end)
  end

  defp convert_parts(nil), do: {[], false, false}

  # Convert tool function declarations to a system instruction string.
  defp move_tools_to_instruction(%{tools: tools} = request)
       when is_list(tools) and tools != [] do
    fn_decls =
      Enum.flat_map(tools, fn
        %{function_declarations: decls} when is_list(decls) -> decls
        %{name: _} = decl -> [decl]
        _ -> []
      end)

    if fn_decls == [] do
      request
    else
      instruction = build_function_system_instruction(fn_decls)
      existing = Map.get(request, :instruction, "")

      new_instruction =
        if existing && existing != "" do
          existing <> "\n" <> instruction
        else
          instruction
        end

      request
      |> Map.put(:instruction, new_instruction)
      |> Map.put(:tools, [])
    end
  end

  defp move_tools_to_instruction(request), do: request

  # Move system instruction to an initial user message (deduped).
  defp move_instruction_to_user_message(%{instruction: instruction} = request)
       when is_binary(instruction) and instruction != "" do
    messages = Map.get(request, :messages, [])
    instruction_msg = %{role: :user, parts: [%{text: instruction}]}

    new_messages =
      case messages do
        [first | _rest] when first == instruction_msg ->
          # Already prepended — no-op
          messages

        _ ->
          [instruction_msg | messages]
      end

    request
    |> Map.put(:instruction, nil)
    |> Map.put(:messages, new_messages)
  end

  defp move_instruction_to_user_message(request), do: request

  defp build_function_system_instruction(fn_decls) do
    prefix = "You have access to the following functions:\n["

    parts =
      Enum.map(fn_decls, fn decl ->
        Jason.encode!(Map.take(decl, [:name, :description, :parameters]))
      end)

    body = Enum.join(parts, ",\n")

    prefix <>
      body <>
      "\n]\n" <>
      "When you call a function, you MUST respond in the format of: " <>
      ~s({"name": function name, "parameters": dictionary of argument name and its value}\n) <>
      "When you call a function, you MUST NOT include any other text in the response.\n"
  end

  # ---------------------------------------------------------------------------
  # Private helpers — response parsing
  # ---------------------------------------------------------------------------

  defp extract_json_function_call(text) do
    # Try markdown code block first
    case Regex.run(~r/```(?:json|tool_code)?\s*(.*?)\s*```/s, text, capture: :all_but_first) do
      [json_str] ->
        parse_function_call_json(String.trim(json_str))

      nil ->
        # Try finding last valid JSON object in text
        case get_last_valid_json(text) do
          {:ok, json_str} -> parse_function_call_json(json_str)
          :error -> :error
        end
    end
  end

  defp parse_function_call_json(json_str) do
    with {:ok, map} <- Jason.decode(json_str),
         {:ok, name} <- extract_name(map),
         {:ok, params} <- extract_params(map) do
      {:ok, %{name: name, args: params}}
    else
      _ -> :error
    end
  end

  defp extract_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp extract_name(%{"function" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp extract_name(_), do: :error

  defp extract_params(%{"parameters" => params}) when is_map(params), do: {:ok, params}
  defp extract_params(%{"args" => args}) when is_map(args), do: {:ok, args}
  defp extract_params(%{"parameters" => nil}), do: {:ok, %{}}
  defp extract_params(%{"args" => nil}), do: {:ok, %{}}

  # Both keys present but neither maps → error
  defp extract_params(map) do
    if Map.has_key?(map, "parameters") or Map.has_key?(map, "args") do
      :error
    else
      :error
    end
  end

  # Scan text left-to-right for JSON objects, keeping the last valid one.
  defp get_last_valid_json(text) do
    get_last_valid_json(text, 0, nil)
  end

  defp get_last_valid_json(text, start_pos, last_found) do
    case :binary.match(text, "{", scope: {start_pos, byte_size(text) - start_pos}) do
      :nomatch ->
        if last_found, do: {:ok, last_found}, else: :error

      {brace_pos, 1} ->
        substr = binary_part(text, brace_pos, byte_size(text) - brace_pos)

        case decode_prefix(substr) do
          {:ok, end_offset} ->
            json_str = binary_part(text, brace_pos, end_offset)
            get_last_valid_json(text, brace_pos + end_offset, json_str)

          :error ->
            get_last_valid_json(text, brace_pos + 1, last_found)
        end
    end
  end

  # Find the smallest valid JSON object prefix in the string.
  defp decode_prefix(str) do
    # Try progressively longer substrings by scanning for closing braces
    find_json_end(str, 0, 0)
  end

  defp find_json_end(str, pos, depth) do
    if pos >= byte_size(str) do
      :error
    else
      ch = binary_part(str, pos, 1)

      case ch do
        "{" ->
          find_json_end(str, pos + 1, depth + 1)

        "}" ->
          new_depth = depth - 1

          if new_depth == 0 do
            candidate = binary_part(str, 0, pos + 1)

            case Jason.decode(candidate) do
              {:ok, _} -> {:ok, pos + 1}
              {:error, _} -> find_json_end(str, pos + 1, new_depth)
            end
          else
            find_json_end(str, pos + 1, new_depth)
          end

        "\"" ->
          # Skip over string content
          case skip_string(str, pos + 1) do
            {:ok, end_pos} -> find_json_end(str, end_pos, depth)
            :error -> :error
          end

        _ ->
          find_json_end(str, pos + 1, depth)
      end
    end
  end

  defp skip_string(str, pos) do
    if pos >= byte_size(str) do
      :error
    else
      ch = binary_part(str, pos, 1)

      case ch do
        "\"" -> {:ok, pos + 1}
        "\\" -> skip_string(str, pos + 2)
        _ -> skip_string(str, pos + 1)
      end
    end
  end
end
