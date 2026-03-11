defmodule ADK.LLM.Anthropic do
  @moduledoc """
  Anthropic Claude LLM backend using the Messages API via Req.

  ## Configuration

      config :adk, :anthropic_api_key, "sk-ant-..."

      # Or via environment variable
      ANTHROPIC_API_KEY=sk-ant-...

  ## Usage

      config :adk, :llm_backend, ADK.LLM.Anthropic

      ADK.LLM.Anthropic.generate("claude-sonnet-4-20250514", %{
        instruction: "You are helpful.",
        messages: [%{role: :user, parts: [%{text: "Hello"}]}]
      })
  """

  @behaviour ADK.LLM

  @base_url "https://api.anthropic.com/v1"
  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 4096
  @anthropic_version "2023-06-01"

  @impl true
  def generate(model, request) do
    model = if model in [nil, ""], do: @default_model, else: model

    case api_key() do
      {:ok, key} -> do_generate(model, key, request)
      {:error, _} = err -> err
    end
  end

  defp do_generate(model, api_key, request) do
    url = "#{@base_url}/messages"
    body = build_request_body(model, request)

    req_options = [
      url: url,
      json: body,
      headers: [
        {"x-api-key", api_key},
        {"anthropic-version", @anthropic_version}
      ]
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
    if Application.get_env(:adk, :anthropic_test_plug) do
      [plug: {Req.Test, ADK.LLM.Anthropic}]
    else
      []
    end
  end

  defp build_request_body(model, request) do
    max_tokens = Map.get(request, :max_tokens, @default_max_tokens)
    messages = build_messages(request)

    body = %{model: model, max_tokens: max_tokens, messages: messages}

    # System goes as top-level param, not in messages
    body =
      case Map.get(request, :instruction) do
        nil -> body
        "" -> body
        inst -> Map.put(body, :system, inst)
      end

    body =
      case Map.get(request, :tools) do
        nil -> body
        [] -> body
        tools -> Map.put(body, :tools, format_tools(tools))
      end

    # Apply generate_config
    case Map.get(request, :generate_config) do
      nil -> body
      config when config == %{} -> body
      config ->
        body
        |> put_if(:temperature, config[:temperature])
        |> put_if(:top_p, config[:top_p])
        |> put_if(:top_k, config[:top_k])
        |> put_if(:stop_sequences, config[:stop_sequences])
        |> then(fn b ->
          case config[:max_output_tokens] do
            nil -> b
            max -> %{b | max_tokens: max}
          end
        end)
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp build_messages(request) do
    request
    |> Map.get(:messages, [])
    |> Enum.map(&format_message/1)
  end

  defp format_message(%{role: role, parts: parts}) do
    case classify_parts(parts) do
      {:function_response, responses} ->
        %{
          role: "user",
          content:
            Enum.map(responses, fn %{name: name, response: resp} ->
              %{
                type: "tool_result",
                tool_use_id: Map.get(resp, :tool_call_id, name),
                content: Jason.encode!(Map.delete(resp, :tool_call_id))
              }
            end)
        }

      {:function_calls, calls} ->
        %{
          role: "assistant",
          content:
            Enum.map(calls, fn %{name: name, args: args} ->
              %{
                type: "tool_use",
                id: Map.get(args, :tool_call_id, name),
                name: name,
                input: Map.delete(args, :tool_call_id)
              }
            end)
        }

      {:text, text} ->
        %{role: map_role(role), content: text}
    end
  end

  defp classify_parts(parts) do
    responses = for %{function_response: fr} <- parts, do: fr
    calls = for %{function_call: fc} <- parts, do: fc

    cond do
      responses != [] -> {:function_response, responses}
      calls != [] -> {:function_calls, calls}
      true ->
        text =
          parts
          |> Enum.map_join("", fn
            %{text: t} -> t
            _ -> ""
          end)

        {:text, text}
    end
  end

  defp map_role(:user), do: "user"
  defp map_role(:model), do: "assistant"
  defp map_role(:assistant), do: "assistant"
  defp map_role(role) when is_binary(role), do: role
  defp map_role(role), do: to_string(role)

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      t = %{name: tool.name, description: Map.get(tool, :description, "")}

      case Map.get(tool, :parameters) do
        nil -> Map.put(t, :input_schema, %{type: "object"})
        params -> Map.put(t, :input_schema, params)
      end
    end)
  end

  # --- Response parsing ---

  defp parse_response(%{"content" => content} = body) do
    %{
      content: parse_content(content),
      usage_metadata: Map.get(body, "usage")
    }
  end

  defp parse_response(body) do
    %{
      content: %{role: :model, parts: [%{text: ""}]},
      usage_metadata: Map.get(body, "usage")
    }
  end

  defp parse_content(blocks) when is_list(blocks) do
    parts = Enum.map(blocks, &parse_block/1)
    %{role: :model, parts: parts}
  end

  defp parse_block(%{"type" => "text", "text" => text}), do: %{text: text}

  defp parse_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}) do
    %{function_call: %{name: name, args: input, id: id}}
  end

  defp parse_block(other), do: other

  defp api_key do
    case Application.get_env(:adk, :anthropic_api_key) do
      nil ->
        case System.get_env("ANTHROPIC_API_KEY") do
          nil -> {:error, :missing_api_key}
          key -> {:ok, key}
        end

      key ->
        {:ok, key}
    end
  end
end
