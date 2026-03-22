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
  @spec generate(String.t(), map()) :: {:ok, map()} | {:error, term()}
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
      nil ->
        body

      config when config == %{} ->
        body

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
    responses = for %{function_response: fr} <- parts, do: fr
    calls = for %{function_call: fc} <- parts, do: fc

    cond do
      responses != [] ->
        %{
          role: "user",
          content: Enum.map(responses, &format_function_response/1)
        }

      calls != [] ->
        content =
          parts
          |> Enum.map(fn
            %{text: t} -> %{type: "text", text: t}
            %{function_call: fc} -> format_function_call(fc)
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        %{role: "assistant", content: content}

      true ->
        role_str = map_role(role)

        content =
          parts
          |> Enum.map(&format_part(&1, role_str))
          |> Enum.reject(&is_nil/1)

        # To maintain exact previous behavior for simple text where possible,
        # if it's just one text block, we can leave it as a string, but Anthropic
        # prefers arrays or strings. Let's just use the array.
        # Wait, Python sends array of blocks. We will too.
        if Enum.all?(content, &is_binary/1) do
          %{role: role_str, content: Enum.join(content, "\n")}
        else
          %{role: role_str, content: content}
        end
    end
  end

  defp format_function_response(%{name: name, response: resp}) do
    # tool_call_id might be under atom or string key
    id_from_resp = Map.get(resp, :tool_call_id, Map.get(resp, "tool_call_id", name))

    content = extract_tool_result_content(resp)

    %{
      type: "tool_result",
      tool_use_id: id_from_resp,
      content: content
    }
  end

  defp extract_tool_result_content(resp) do
    resp_clean = Map.drop(resp, [:tool_call_id, "tool_call_id"])

    cond do
      # If it has "content" as a list
      Map.has_key?(resp_clean, :content) and is_list(resp_clean.content) ->
        resp_clean.content
        |> Enum.map(fn
          %{type: "text", text: t} -> t
          %{"type" => "text", "text" => t} -> t
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      Map.has_key?(resp_clean, "content") and is_list(resp_clean["content"]) ->
        resp_clean["content"]
        |> Enum.map(fn
          %{type: "text", text: t} -> t
          %{"type" => "text", "text" => t} -> t
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      # If it has "result"
      Map.has_key?(resp_clean, :result) ->
        serialize_tool_result(resp_clean.result)

      Map.has_key?(resp_clean, "result") ->
        serialize_tool_result(resp_clean["result"])

      # Otherwise, the whole thing
      true ->
        serialize_tool_result(resp_clean)
    end
  end

  defp serialize_tool_result(val) when is_binary(val), do: val
  defp serialize_tool_result(val), do: Jason.encode!(val)

  defp format_function_call(%{name: name, args: args, id: id}) do
    %{
      type: "tool_use",
      id: Map.get(args, :tool_call_id, Map.get(args, "tool_call_id", id || name)),
      name: name,
      input: Map.drop(args, [:tool_call_id, "tool_call_id"])
    }
  end

  defp format_function_call(%{name: name, args: args}) do
    %{
      type: "tool_use",
      id: Map.get(args, :tool_call_id, Map.get(args, "tool_call_id", name)),
      name: name,
      input: Map.drop(args, [:tool_call_id, "tool_call_id"])
    }
  end

  defp format_part(%{text: t}, _role), do: %{type: "text", text: t}

  defp format_part(%{inline_data: %{mime_type: mime, data: data}}, role) do
    if role == "assistant" do
      require Logger

      cond do
        String.starts_with?(mime, "image/") ->
          Logger.warning("Image data is not supported in Claude for assistant turns.")

        String.starts_with?(mime, "application/pdf") ->
          Logger.warning("PDF data is not supported in Claude for assistant turns.")

        true ->
          Logger.warning("Media data is not supported in Claude for assistant turns.")
      end

      nil
    else
      cond do
        String.starts_with?(mime, "image/") ->
          %{
            type: "image",
            source: %{
              type: "base64",
              media_type: mime,
              data: data
            }
          }

        String.starts_with?(mime, "application/pdf") ->
          %{
            type: "document",
            source: %{
              type: "base64",
              media_type: mime,
              data: data
            }
          }

        true ->
          nil
      end
    end
  end

  defp format_part(_, _), do: nil

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
