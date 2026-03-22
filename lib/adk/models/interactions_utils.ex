defmodule ADK.Models.InteractionsUtils do
  @moduledoc """
  Utilities for the Interactions API integration.
  
  This module provides conversion utilities between ADK types and
  Interactions API types.
  """

  require Logger

  @doc """
  Convert a Part map to an interaction content map.
  """
  def convert_part_to_interaction_content(part) when is_map(part) do
    cond do
      Map.has_key?(part, :text) and not is_nil(part.text) ->
        %{type: "text", text: part.text}

      Map.has_key?(part, :function_call) and not is_nil(part.function_call) ->
        fc = part.function_call
        result = %{
          type: "function_call",
          id: Map.get(fc, :id, ""),
          name: Map.get(fc, :name),
          arguments: Map.get(fc, :args, %{})
        }
        
        if Map.get(part, :thought_signature) do
          Map.put(result, "thought_signature", Base.encode64(part.thought_signature))
        else
          result
        end

      Map.has_key?(part, :function_response) and not is_nil(part.function_response) ->
        fr = part.function_response
        result_val =
          case Map.get(fr, :response) do
            val when is_map(val) -> Jason.encode!(val)
            val when is_binary(val) -> val
            val -> to_string(val)
          end

        Logger.debug("Converting function_response: name=#{Map.get(fr, :name)}, call_id=#{Map.get(fr, :id)}")

        %{
          type: "function_result",
          name: Map.get(fr, :name, ""),
          call_id: Map.get(fr, :id, ""),
          result: result_val
        }

      Map.has_key?(part, :inline_data) and not is_nil(part.inline_data) ->
        id = part.inline_data
        mime_type = Map.get(id, :mime_type, "")
        data = Map.get(id, :data)

        cond do
          String.starts_with?(mime_type, "image/") ->
            %{type: "image", data: data, mime_type: mime_type}
          String.starts_with?(mime_type, "audio/") ->
            %{type: "audio", data: data, mime_type: mime_type}
          String.starts_with?(mime_type, "video/") ->
            %{type: "video", data: data, mime_type: mime_type}
          true ->
            %{type: "document", data: data, mime_type: mime_type}
        end

      Map.has_key?(part, :file_data) and not is_nil(part.file_data) ->
        fd = part.file_data
        mime_type = Map.get(fd, :mime_type, "")
        uri = Map.get(fd, :file_uri)

        cond do
          String.starts_with?(mime_type, "image/") ->
            %{type: "image", uri: uri, mime_type: mime_type}
          String.starts_with?(mime_type, "audio/") ->
            %{type: "audio", uri: uri, mime_type: mime_type}
          String.starts_with?(mime_type, "video/") ->
            %{type: "video", uri: uri, mime_type: mime_type}
          true ->
            %{type: "document", uri: uri, mime_type: mime_type}
        end

      Map.get(part, :thought) == true ->
        result = %{type: "thought"}
        if Map.get(part, :thought_signature) do
          Map.put(result, "signature", Base.encode64(part.thought_signature))
        else
          result
        end

      Map.has_key?(part, :code_execution_result) and not is_nil(part.code_execution_result) ->
        cer = part.code_execution_result
        outcome = Map.get(cer, :outcome)
        
        is_error = outcome in [:OUTCOME_FAILED, :OUTCOME_DEADLINE_EXCEEDED, "OUTCOME_FAILED", "OUTCOME_DEADLINE_EXCEEDED"]

        %{
          type: "code_execution_result",
          call_id: "",
          result: Map.get(cer, :output, ""),
          is_error: is_error
        }

      Map.has_key?(part, :executable_code) and not is_nil(part.executable_code) ->
        ec = part.executable_code
        %{
          type: "code_execution_call",
          id: "",
          arguments: %{
            code: Map.get(ec, :code, ""),
            language: Map.get(ec, :language, "PYTHON")
          }
        }

      true ->
        nil
    end
  end

  def convert_part_to_interaction_content(_), do: nil

  @doc """
  Convert a Content map to a TurnParam map for interactions API.
  """
  def convert_content_to_turn(content) when is_map(content) do
    parts = Map.get(content, :parts, [])
    
    converted_parts =
      Enum.reduce(parts, [], fn part, acc ->
        case convert_part_to_interaction_content(part) do
          nil -> acc
          res -> [res | acc]
        end
      end)
      |> Enum.reverse()

    %{
      role: Map.get(content, :role, "user"),
      content: converted_parts
    }
  end

  @doc """
  Convert a list of Content maps to interactions API input format.
  """
  def convert_contents_to_turns(contents) when is_list(contents) do
    Enum.reduce(contents, [], fn content, acc ->
      turn = convert_content_to_turn(content)
      if Enum.empty?(turn.content) do
        acc
      else
        [turn | acc]
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Convert tools from GenerateContentConfig to interactions API format.
  """
  def convert_tools_config_to_interactions_format(config) when is_map(config) do
    tools = Map.get(config, :tools, [])
    
    if Enum.empty?(tools) do
      []
    else
      Enum.reduce(tools, [], fn tool, acc ->
        cond do
          Map.has_key?(tool, :function_declarations) ->
            funcs = Enum.map(tool.function_declarations, fn decl ->
              res = %{type: "function", name: decl.name}
              
              res = if Map.get(decl, :description), do: Map.put(res, :description, decl.description), else: res
              
              params = cond do
                Map.get(decl, :parameters) ->
                  # Translate schema map
                  p = decl.parameters
                  p_res = %{type: "object"}
                  
                  p_res = if Map.get(p, :properties) do
                    Map.put(p_res, :properties, p.properties)
                  else
                    p_res
                  end
                  
                  if Map.get(p, :required) do
                    Map.put(p_res, :required, p.required)
                  else
                    p_res
                  end
                Map.get(decl, :parameters_json_schema) ->
                  decl.parameters_json_schema
                true ->
                  nil
              end
              
              if params, do: Map.put(res, :parameters, params), else: res
            end)
            acc ++ funcs
            
          Map.has_key?(tool, :google_search) ->
            acc ++ [%{type: "google_search"}]
            
          Map.has_key?(tool, :code_execution) ->
            acc ++ [%{type: "code_execution"}]
            
          Map.has_key?(tool, :url_context) ->
            acc ++ [%{type: "url_context"}]
            
          Map.has_key?(tool, :computer_use) ->
            acc ++ [%{type: "computer_use"}]
            
          true ->
            acc
        end
      end)
    end
  end
  def convert_tools_config_to_interactions_format(_), do: []

  @doc """
  Convert an interaction output content to a Part map.
  """
  def convert_interaction_output_to_part(output) when is_map(output) do
    output_type = Map.get(output, :type)
    
    case output_type do
      "text" ->
        %{text: Map.get(output, :text, "")}
        
      "function_call" ->
        id = Map.get(output, :id, "")
        name = Map.get(output, :name, "")
        
        Logger.debug("Converting function_call output: name=#{name}, id=#{id}")
        
        fc = %{
          id: id,
          name: name,
          args: Map.get(output, :arguments, %{})
        }
        
        res = %{function_call: fc}
        
        # Decode base64
        sig = Map.get(output, :thought_signature)
        if sig && is_binary(sig) do
          Map.put(res, :thought_signature, Base.decode64!(sig))
        else
          Map.put(res, :thought_signature, nil)
        end
        
      "function_result" ->
        result = Map.get(output, :result)
        
        result_value = cond do
          is_binary(result) -> result
          is_map(result) and Map.has_key?(result, :items) -> result.items
          true -> result
        end
        
        %{
          function_response: %{
            id: Map.get(output, :call_id, ""),
            response: result_value
          }
        }
        
      "image" ->
        cond do
          Map.get(output, :data) ->
            %{inline_data: %{data: output.data, mime_type: Map.get(output, :mime_type, "")}}
          Map.get(output, :uri) ->
            %{file_data: %{file_uri: output.uri, mime_type: Map.get(output, :mime_type, "")}}
          true ->
            nil
        end
        
      "audio" ->
        cond do
          Map.get(output, :data) ->
            %{inline_data: %{data: output.data, mime_type: Map.get(output, :mime_type, "")}}
          Map.get(output, :uri) ->
            %{file_data: %{file_uri: output.uri, mime_type: Map.get(output, :mime_type, "")}}
          true ->
            nil
        end
        
      "thought" ->
        nil
        
      "code_execution_result" ->
        outcome = if Map.get(output, :is_error), do: :OUTCOME_FAILED, else: :OUTCOME_OK
        %{
          code_execution_result: %{
            output: Map.get(output, :result, ""),
            outcome: outcome
          }
        }
        
      "code_execution_call" ->
        args = Map.get(output, :arguments, %{})
        %{
          executable_code: %{
            code: Map.get(args, "code", ""),
            language: Map.get(args, "language", "PYTHON")
          }
        }
        
      "google_search_result" ->
        res = Map.get(output, :result)
        if res do
          text = res |> Enum.reject(&is_nil/1) |> Enum.map(&to_string/1) |> Enum.join("\n")
          %{text: text}
        else
          nil
        end
        
      _ ->
        nil
    end
  end
  def convert_interaction_output_to_part(_), do: nil

  @doc """
  Convert an Interaction response to an LlmResponse map.
  """
  def convert_interaction_to_llm_response(interaction) when is_map(interaction) do
    status = Map.get(interaction, :status, "unknown")
    
    if status == "failed" do
      err = Map.get(interaction, :error, %{})
      %{
        error_code: Map.get(err, :code, "UNKNOWN_ERROR"),
        error_message: Map.get(err, :message, "Unknown error"),
        interaction_id: Map.get(interaction, :id)
      }
    else
      outputs = Map.get(interaction, :outputs, [])
      parts = Enum.reduce(outputs, [], fn out, acc ->
        case convert_interaction_output_to_part(out) do
          nil -> acc
          p -> [p | acc]
        end
      end) |> Enum.reverse()
      
      content = if Enum.empty?(parts), do: nil, else: %{role: "model", parts: parts}
      
      usage = Map.get(interaction, :usage)
      usage_metadata = if usage do
        %{
          prompt_token_count: Map.get(usage, :total_input_tokens, 0),
          candidates_token_count: Map.get(usage, :total_output_tokens, 0),
          total_token_count: Map.get(usage, :total_input_tokens, 0) + Map.get(usage, :total_output_tokens, 0)
        }
      else
        nil
      end
      
      finish_reason = if status in ["completed", "requires_action"], do: :STOP, else: nil
      
      %{
        content: content,
        usage_metadata: usage_metadata,
        finish_reason: finish_reason,
        turn_complete: status in ["completed", "requires_action"],
        interaction_id: Map.get(interaction, :id)
      }
    end
  end

  @doc """
  Convert an InteractionSSEEvent to an LlmResponse for streaming.
  """
  def convert_interaction_event_to_llm_response(event, aggregated_parts \\ [], interaction_id \\ nil) do
    event_type = Map.get(event, :event_type)
    
    case event_type do
      "content.delta" ->
        delta = Map.get(event, :delta)
        if delta do
          delta_type = Map.get(delta, :type)
          
          case delta_type do
            "text" ->
              text = Map.get(delta, :text, "")
              if text != "" do
                part = %{text: text}
                new_parts = aggregated_parts ++ [part]
                {
                  %{
                    content: %{role: "model", parts: [part]},
                    partial: true,
                    turn_complete: false,
                    interaction_id: interaction_id
                  },
                  new_parts
                }
              else
                {nil, aggregated_parts}
              end
              
            "function_call" ->
              name = Map.get(delta, :name)
              if name do
                fc = %{
                  id: Map.get(delta, :id, ""),
                  name: name,
                  args: Map.get(delta, :arguments, %{})
                }
                
                sig = Map.get(delta, :thought_signature)
                part = %{function_call: fc}
                part = if sig && is_binary(sig) do
                  Map.put(part, :thought_signature, Base.decode64!(sig))
                else
                  Map.put(part, :thought_signature, nil)
                end
                
                {nil, aggregated_parts ++ [part]}
              else
                {nil, aggregated_parts}
              end
              
            "image" ->
              part = cond do
                Map.get(delta, :data) ->
                  %{inline_data: %{data: delta.data, mime_type: Map.get(delta, :mime_type, "")}}
                Map.get(delta, :uri) ->
                  %{file_data: %{file_uri: delta.uri, mime_type: Map.get(delta, :mime_type, "")}}
                true ->
                  nil
              end
              
              if part do
                {
                  %{
                    content: %{role: "model", parts: [part]},
                    partial: false,
                    turn_complete: false,
                    interaction_id: interaction_id
                  },
                  aggregated_parts ++ [part]
                }
              else
                {nil, aggregated_parts}
              end
              
            _ ->
              {nil, aggregated_parts}
          end
        else
          {nil, aggregated_parts}
        end
        
      "content.stop" ->
        if not Enum.empty?(aggregated_parts) do
          {
            %{
              content: %{role: "model", parts: aggregated_parts},
              partial: false,
              turn_complete: false,
              interaction_id: interaction_id
            },
            aggregated_parts
          }
        else
          {nil, aggregated_parts}
        end
        
      "interaction" ->
        {convert_interaction_to_llm_response(event), aggregated_parts}
        
      "interaction.status_update" ->
        status = Map.get(event, :status)
        cond do
          status in ["completed", "requires_action"] ->
            content = if Enum.empty?(aggregated_parts), do: nil, else: %{role: "model", parts: aggregated_parts}
            {
              %{
                content: content,
                partial: false,
                turn_complete: true,
                finish_reason: :STOP,
                interaction_id: interaction_id
              },
              aggregated_parts
            }
          status == "failed" ->
            err = Map.get(event, :error, %{})
            {
              %{
                error_code: Map.get(err, :code, "UNKNOWN_ERROR"),
                error_message: Map.get(err, :message, "Unknown error"),
                turn_complete: true,
                interaction_id: interaction_id
              },
              aggregated_parts
            }
          true ->
            {nil, aggregated_parts}
        end
        
      "error" ->
        {
          %{
            error_code: Map.get(event, :code, "UNKNOWN_ERROR"),
            error_message: Map.get(event, :message, "Unknown error"),
            turn_complete: true,
            interaction_id: interaction_id
          },
          aggregated_parts
        }
        
      _ ->
        {nil, aggregated_parts}
    end
  end

  @doc """
  Build generation config dict for interactions API.
  """
  def build_generation_config(config) when is_map(config) do
    keys = [:temperature, :top_p, :top_k, :max_output_tokens, :stop_sequences, :presence_penalty, :frequency_penalty]
    
    Enum.reduce(keys, %{}, fn key, acc ->
      val = Map.get(config, key)
      if val != nil and not (is_list(val) and Enum.empty?(val)) do
        Map.put(acc, key, val)
      else
        acc
      end
    end)
  end

  @doc """
  Extract system instruction as a string from config.
  """
  def extract_system_instruction(config) when is_map(config) do
    instruction = Map.get(config, :system_instruction)
    
    cond do
      is_nil(instruction) -> nil
      is_binary(instruction) -> instruction
      is_map(instruction) and Map.has_key?(instruction, :parts) ->
        parts = Map.get(instruction, :parts, [])
        texts = parts |> Enum.map(fn p -> Map.get(p, :text) end) |> Enum.reject(&is_nil/1)
        if Enum.empty?(texts), do: nil, else: Enum.join(texts, "\n")
      true -> nil
    end
  end

  @doc """
  Extract the latest turn contents for interactions API.
  """
  def get_latest_user_contents(contents) when is_list(contents) do
    if Enum.empty?(contents) do
      []
    else
      # Find latest contiguous user messages from the end
      {latest_user, _} = Enum.reduce(Enum.reverse(contents), {[], true}, fn content, {acc, is_user_block} ->
        if is_user_block do
          if Map.get(content, :role) == "user" do
            {[content | acc], true}
          else
            {acc, false}
          end
        else
          {acc, false}
        end
      end)
      
      # Check if user contents contain a function_result
      has_function_result = Enum.any?(latest_user, fn content ->
        parts = Map.get(content, :parts, [])
        Enum.any?(parts, fn part -> Map.has_key?(part, :function_response) and not is_nil(part.function_response) end)
      end)
      
      if has_function_result and length(contents) > length(latest_user) do
        user_start_idx = length(contents) - length(latest_user)
        preceding = Enum.at(contents, user_start_idx - 1)
        
        if Map.get(preceding, :role) == "model" do
          parts = Map.get(preceding, :parts, [])
          has_fc = Enum.any?(parts, fn p -> Map.has_key?(p, :function_call) and not is_nil(p.function_call) end)
          
          if has_fc do
            [preceding | latest_user]
          else
            latest_user
          end
        else
          latest_user
        end
      else
        latest_user
      end
    end
  end
end
