defmodule ADK.Plugin.GlobalInstruction do
  @moduledoc """
  Plugin that provides global instructions functionality at the App level.

  This plugin replaces the deprecated global_instruction field on LlmAgent.
  Global instructions are applied to all agents in the application, providing
  a consistent way to set application-wide instructions, identity, or
  personality.

  The plugin operates through the `before_model` callback, allowing it to modify
  LLM requests before they are sent to the model.
  """
  @behaviour ADK.Plugin

  @impl true
  def init(config) do
    instruction =
      cond do
        is_list(config) -> Keyword.get(config, :instruction)
        is_map(config) -> Map.get(config, :instruction)
        true -> config
      end

    {:ok, %{instruction: instruction}}
  end

  @impl true
  def before_model(context, request) do
    state =
      ADK.Plugin.Registry.list()
      |> Enum.find_value(fn
        {__MODULE__, st} -> st
        _ -> nil
      end)

    if state && state.instruction do
      instruction = resolve_instruction(state.instruction, context)

      if is_nil(instruction) or instruction == "" do
        {:ok, request}
      else
        {:ok, prepend_to_request(request, instruction)}
      end
    else
      {:ok, request}
    end
  end

  defp prepend_to_request(%ADK.Models.LlmRequest{} = req, instruction) do
    config = req.config || %{}
    existing = Map.get(config, :system_instruction)
    new_system_instruction = prepend_instruction(existing, instruction)
    %{req | config: Map.put(config, :system_instruction, new_system_instruction)}
  end

  defp prepend_to_request(req, instruction) when is_map(req) do
    existing = Map.get(req, :system_instruction) || Map.get(req, "system_instruction")
    new_system_instruction = prepend_instruction(existing, instruction)

    if Map.has_key?(req, "system_instruction") do
      Map.put(req, "system_instruction", new_system_instruction)
    else
      Map.put(req, :system_instruction, new_system_instruction)
    end
  end

  defp resolve_instruction(instruction, context) when is_function(instruction, 1) do
    instruction.(context)
  end

  defp resolve_instruction(instruction, _context) when is_function(instruction, 0) do
    instruction.()
  end

  defp resolve_instruction(instruction, context) when is_binary(instruction) do
    inject_session_state(instruction, context)
  end

  defp resolve_instruction(_other, _context), do: nil

  defp inject_session_state(instruction, context) do
    state = get_session_state(context)

    if is_map(state) and map_size(state) > 0 do
      Enum.reduce(state, instruction, fn {k, v}, acc ->
        key_str = to_string(k)
        val_str = if is_binary(v), do: v, else: inspect(v)
        String.replace(acc, "{{#{key_str}}}", val_str)
      end)
    else
      instruction
    end
  end

  defp get_session_state(%ADK.Context{session_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        ADK.Session.get_all_state(pid)
      catch
        :exit, _ -> %{}
      end
    else
      %{}
    end
  end

  defp get_session_state(%ADK.Context{temp_state: ts}) when is_map(ts) do
    ts[:__mock_session_state] || %{}
  end

  defp get_session_state(_), do: %{}

  defp prepend_instruction(nil, new_inst), do: new_inst
  defp prepend_instruction("", new_inst), do: new_inst

  defp prepend_instruction(existing, new_inst) when is_binary(existing) do
    "#{new_inst}\n\n#{existing}"
  end

  defp prepend_instruction(existing, new_inst) when is_list(existing) do
    [new_inst | existing]
  end

  defp prepend_instruction(existing, new_inst) do
    "#{new_inst}\n\n#{inspect(existing)}"
  end
end
