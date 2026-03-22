defmodule ADK.Models.LlmRequest do
  @moduledoc """
  LLM request struct that allows passing in tools, output schema and system
  instructions to the model.
  """

  defstruct model: nil,
            contents: [],
            # Holds generate content config
            config: %{},
            live_connect_config: %{},
            tools_dict: %{},
            cache_config: nil,
            cache_metadata: nil,
            cacheable_contents_token_count: nil,
            previous_interaction_id: nil

  @type t :: %__MODULE__{}

  @doc """
  Appends instructions to the system instruction.
  instructions can be a list of strings or a map representing types.Content.
  Returns a tuple {updated_request, user_contents}
  """
  def append_instructions(%__MODULE__{} = req, instructions) do
    cond do
      is_list(instructions) and Enum.all?(instructions, &is_binary/1) ->
        if Enum.empty?(instructions) do
          {req, []}
        else
          new_text = Enum.join(instructions, "\n\n")
          sys_inst = Map.get(req.config, :system_instruction)

          updated_sys_inst =
            if is_nil(sys_inst) or sys_inst == "" do
              new_text
            else
              "#{sys_inst}\n\n#{new_text}"
            end

          updated_config = Map.put(req.config, :system_instruction, updated_sys_inst)
          {%{req | config: updated_config}, []}
        end

      is_map(instructions) and Map.has_key?(instructions, :parts) ->
        {text_parts, user_contents} = process_content_parts(instructions.parts)

        updated_req =
          if text_parts != [] do
            new_text = Enum.join(text_parts, "\n\n")
            sys_inst = Map.get(req.config, :system_instruction)

            updated_sys_inst =
              if is_nil(sys_inst) or sys_inst == "" do
                new_text
              else
                "#{sys_inst}\n\n#{new_text}"
              end

            %{req | config: Map.put(req.config, :system_instruction, updated_sys_inst)}
          else
            req
          end

        final_req = %{updated_req | contents: updated_req.contents ++ user_contents}
        {final_req, user_contents}

      true ->
        raise ArgumentError, "instructions must be list of strings or a Content map"
    end
  end

  defp process_content_parts(parts) do
    {texts, users, _count} =
      Enum.reduce(parts, {[], [], 0}, fn part, {texts, users, count} ->
        cond do
          Map.has_key?(part, :text) ->
            {texts ++ [part.text], users, count}

          Map.has_key?(part, :inline_data) ->
            ref_id = "inline_data_#{count}"
            display_info = []

            display_info =
              if part.inline_data[:display_name],
                do: display_info ++ ["'#{part.inline_data.display_name}'"],
                else: display_info

            display_info =
              if part.inline_data[:mime_type],
                do: display_info ++ ["type: #{part.inline_data.mime_type}"],
                else: display_info

            display_text =
              if display_info != [], do: " (#{Enum.join(display_info, ", ")})", else: ""

            ref_text = "[Reference to inline binary data: #{ref_id}#{display_text}]"

            user_content = %{
              role: "user",
              parts: [
                %{text: "Referenced inline data: #{ref_id}"},
                %{inline_data: part.inline_data}
              ]
            }

            {texts ++ [ref_text], users ++ [user_content], count + 1}

          Map.has_key?(part, :file_data) ->
            ref_id = "file_data_#{count}"
            display_info = []

            display_info =
              if part.file_data[:display_name],
                do: display_info ++ ["'#{part.file_data.display_name}'"],
                else: display_info

            display_info =
              if part.file_data[:file_uri],
                do: display_info ++ ["URI: #{part.file_data.file_uri}"],
                else: display_info

            display_info =
              if part.file_data[:mime_type],
                do: display_info ++ ["type: #{part.file_data.mime_type}"],
                else: display_info

            display_text =
              if display_info != [], do: " (#{Enum.join(display_info, ", ")})", else: ""

            ref_text = "[Reference to file data: #{ref_id}#{display_text}]"

            user_content = %{
              role: "user",
              parts: [
                %{text: "Referenced file data: #{ref_id}"},
                %{file_data: part.file_data}
              ]
            }

            {texts ++ [ref_text], users ++ [user_content], count + 1}

          true ->
            {texts, users, count}
        end
      end)

    {texts, users}
  end

  @doc """
  Appends tools to the request.
  """
  def append_tools(%__MODULE__{} = req, tools) when is_list(tools) do
    if Enum.empty?(tools) do
      req
    else
      {declarations, new_tools_dict} =
        Enum.reduce(tools, {[], req.tools_dict}, fn tool, {decls, dict} ->
          decl = get_declaration(tool)

          if decl do
            name = get_tool_name(tool)
            {decls ++ [decl], Map.put(dict, name, tool)}
          else
            {decls, dict}
          end
        end)

      if declarations != [] do
        existing_tools = Map.get(req.config, :tools, nil)

        updated_tools =
          if existing_tools do
            case Enum.split_with(existing_tools, fn t ->
                   Map.has_key?(t, :function_declarations) and t.function_declarations != nil
                 end) do
              {[], others} ->
                [%{function_declarations: declarations} | others]

              {[match | rest], others} ->
                updated_match = %{
                  match
                  | function_declarations:
                      Map.get(match, :function_declarations, []) ++ declarations
                }

                [updated_match | rest] ++ others
            end
          else
            [%{function_declarations: declarations}]
          end

        %{req | config: Map.put(req.config, :tools, updated_tools), tools_dict: new_tools_dict}
      else
        req
      end
    end
  end

  defp get_declaration(tool) do
    cond do
      is_map(tool) and Map.has_key?(tool, :_get_declaration) ->
        tool._get_declaration.(tool)

      Code.ensure_loaded?(Map.get(tool, :__struct__)) and
          function_exported?(Map.get(tool, :__struct__), :_get_declaration, 1) ->
        apply(Map.get(tool, :__struct__), :_get_declaration, [tool])

      Map.has_key?(tool, :declaration) ->
        tool.declaration

      true ->
        nil
    end
  end

  defp get_tool_name(tool) do
    cond do
      is_map(tool) and Map.has_key?(tool, :name) ->
        if is_function(tool.name), do: tool.name.(tool), else: tool.name

      Code.ensure_loaded?(Map.get(tool, :__struct__)) and
          function_exported?(Map.get(tool, :__struct__), :name, 1) ->
        apply(Map.get(tool, :__struct__), :name, [tool])

      true ->
        "unknown_tool"
    end
  end

  @doc """
  Sets the output schema for the request.
  """
  def set_output_schema(%__MODULE__{} = req, output_schema \\ nil, base_model \\ nil) do
    schema = output_schema || base_model

    if is_nil(schema) do
      raise ArgumentError, "Either output_schema or base_model must be provided."
    end

    updated_config =
      req.config
      |> Map.put(:response_schema, schema)
      |> Map.put(:response_mime_type, "application/json")

    %{req | config: updated_config}
  end
end
