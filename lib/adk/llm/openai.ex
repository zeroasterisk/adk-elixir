defmodule ADK.LLM.OpenAI do
  @moduledoc """
  OpenAI-compatible LLM backend using the chat completions API via Req.

  Works with OpenAI, Ollama, Together, and any OpenAI-compatible provider.

  ## Configuration

      # config/config.exs
      config :adk, :openai_api_key, "sk-..."
      config :adk, :openai_base_url, "https://api.openai.com/v1"  # optional

      # Or via environment variables
      OPENAI_API_KEY=sk-...
      OPENAI_BASE_URL=http://localhost:11434/v1  # e.g. Ollama

  ## Usage

      config :adk, :llm_backend, ADK.LLM.OpenAI

      ADK.LLM.OpenAI.generate("gpt-4o", %{
        instruction: "You are helpful.",
        messages: [%{role: :user, parts: [%{text: "Hello"}]}]
      })
  """

  @behaviour ADK.LLM

  @default_base_url "https://api.openai.com/v1"
  @default_model "gpt-4o"

  @impl true
  @spec generate(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def generate(model, request) do
    model = if model in [nil, ""], do: @default_model, else: model

    case api_key() do
      {:ok, key} -> do_generate(model, key, request)
      {:error, _} = err -> err
    end
  end

  defp do_generate(model, api_key, request) do
    base = Map.get(request, :base_url, base_url())
    url = "#{base}/chat/completions"
    body = build_request_body(model, request)

    custom_headers = Map.get(request, :custom_headers, [])

    req_options = [
      url: url,
      json: body,
      headers: [{"authorization", "Bearer #{api_key}"}] ++ custom_headers
    ]

    req_options = req_options ++ req_test_options()

    case Req.post(Req.new(req_options)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp req_test_options do
    if ADK.Config.openai_test_plug() do
      [plug: {Req.Test, ADK.LLM.OpenAI}]
    else
      []
    end
  end

  defp build_request_body(model, request) do
    messages = build_messages(request)
    body = %{model: model, messages: messages}

    body =
      case Map.get(request, :tools) do
        nil -> body
        [] -> body
        tools -> Map.put(body, :tools, format_tools(tools))
      end

    # Apply generate_config
    case Map.get(request, :generate_config) do
      nil ->
        body

      config when config == %{} ->
        body

      config ->
        gen_config =
          [
            {:temperature, config[:temperature]},
            {:top_p, config[:top_p]},
            {:max_tokens, config[:max_output_tokens]},
            {:stop, config[:stop_sequences]},
            {:n, config[:candidate_count]},
            {:response_format, translate_response_format(config)}
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        Map.merge(body, gen_config)
    end
  end


  defp translate_response_format(config) do
    case config[:response_mime_type] do
      "application/json" ->
        case config[:response_schema] do
          nil -> %{type: "json_object"}
          schema -> %{type: "json_schema", json_schema: schema}
        end

      _ ->
        nil
    end
  end

  defp build_messages(request) do
    system =
      case Map.get(request, :instruction) do
        nil -> []
        "" -> []
        inst -> [%{role: "system", content: inst}]
      end

    msgs =
      request
      |> Map.get(:messages, [])
      |> Enum.flat_map(&format_message/1)

    system ++ msgs
  end

  defp format_message(%{role: role, parts: parts}) do
    role_str = map_role(role)
    text = Enum.map_join(parts, "", fn %{text: t} -> t; _ -> "" end)
    calls = for %{function_call: fc} <- parts, do: fc
    responses = for %{function_response: fr} <- parts, do: fr

    cond do
      responses != [] ->
        # OpenAI expects tool results as separate messages.
        # If there's text, it becomes a preceding message.
        text_msg = if text != "", do: [%{role: "user", content: text}], else: []

        tool_msgs =
          Enum.map(responses, fn fr ->
            resp = fr.response

            # tool_call_id resolution
            id =
              Map.get(fr, :id) ||
                (is_map(resp) && Map.get(resp, :tool_call_id)) ||
                (is_map(resp) && Map.get(resp, "tool_call_id")) ||
                fr.name

            %{
              role: "tool",
              tool_call_id: id,
              content: Jason.encode!(if is_map(resp), do: Map.drop(resp, [:tool_call_id, "tool_call_id"]), else: resp)
            }
          end)

        text_msg ++ tool_msgs

      calls != [] ->
        # Mixed text + tool calls (Assistant turn)
        [
          %{
            role: role_str,
            content: if(text == "", do: nil, else: text),
            tool_calls:
              Enum.map(calls, fn fc ->
                args = fc.args

                # tool_call_id resolution
                id =
                  Map.get(fc, :id) ||
                    (is_map(args) && Map.get(args, :tool_call_id)) ||
                    (is_map(args) && Map.get(args, "tool_call_id")) ||
                    fc.name

                %{
                  id: id,
                  type: "function",
                  function: %{
                    name: fc.name,
                    arguments: Jason.encode!(if is_map(args), do: Map.drop(args, [:tool_call_id, "tool_call_id"]), else: args)
                  }
                }
              end)
          }
        ]

      true ->
        # Simple text message
        [%{role: role_str, content: text}]
    end
  end

  defp map_role(:user), do: "user"
  defp map_role(:model), do: "assistant"
  defp map_role(:assistant), do: "assistant"
  defp map_role(:tool), do: "tool"
  defp map_role(role) when is_binary(role), do: role
  defp map_role(role), do: to_string(role)

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      func = %{name: tool.name, description: Map.get(tool, :description, "")}

      func =
        case Map.get(tool, :parameters) do
          nil -> func
          params -> Map.put(func, :parameters, params)
        end

      %{type: "function", function: func}
    end)
  end

  defp parse_response(%{"choices" => [%{"message" => message} | _]} = body) do
    %{
      content: parse_message(message),
      usage_metadata: Map.get(body, "usage")
    }
  end

  defp parse_response(body) do
    %{
      content: %{role: :model, parts: [%{text: ""}]},
      usage_metadata: Map.get(body, "usage")
    }
  end

  defp parse_message(%{"tool_calls" => tool_calls} = msg) when is_list(tool_calls) do
    parts =
      Enum.map(tool_calls, fn tc ->
        %{
          function_call: %{
            name: tc["function"]["name"],
            args: parse_arguments(tc["function"]["arguments"]),
            id: tc["id"]
          }
        }
      end)

    # Include text content if present alongside tool calls
    parts =
      case msg["content"] do
        nil -> parts
        "" -> parts
        text -> [%{text: text} | parts]
      end

    %{role: :model, parts: parts}
  end

  defp parse_message(%{"content" => content}) do
    %{role: :model, parts: [%{text: content || ""}]}
  end

  defp parse_message(_) do
    %{role: :model, parts: [%{text: ""}]}
  end

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp api_key do
    case ADK.Config.openai_api_key() do
      nil -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end

  defp base_url do
    ADK.Config.openai_base_url() || @default_base_url
  end
end
