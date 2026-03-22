defmodule ADK.Models.LlmRequestTest do
  use ExUnit.Case, async: true
  alias ADK.Models.LlmRequest

  defmodule DummyTool do
    defstruct [:name, :description, :declaration]

    def _get_declaration(%{declaration: decl}), do: decl
    def name(%{name: n}), do: n
  end

  defp create_dummy_tool(name \\ "dummy_tool") do
    %DummyTool{
      name: name,
      description: "A dummy tool for testing.",
      declaration: %{name: name, description: "A dummy tool for testing.", parameters: %{}}
    }
  end

  test "append_tools initializes config.tools when it's None" do
    request = %LlmRequest{}
    assert request.config[:tools] == nil

    tool = create_dummy_tool()
    request = LlmRequest.append_tools(request, [tool])

    assert request.config.tools != nil
    assert length(request.config.tools) == 1
    assert length(hd(request.config.tools).function_declarations) == 1
    assert hd(hd(request.config.tools).function_declarations).name == "dummy_tool"

    assert Map.has_key?(request.tools_dict, "dummy_tool")
    assert request.tools_dict["dummy_tool"] == tool
  end

  test "append_tools with existing tools" do
    existing_declaration = %{
      name: "existing_tool",
      description: "An existing tool",
      parameters: %{}
    }

    request = %LlmRequest{config: %{tools: [%{function_declarations: [existing_declaration]}]}}

    tool = create_dummy_tool()
    request = LlmRequest.append_tools(request, [tool])

    assert length(request.config.tools) == 1
    assert length(hd(request.config.tools).function_declarations) == 2

    decl_names =
      hd(request.config.tools).function_declarations
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert decl_names == ["dummy_tool", "existing_tool"]
  end

  test "append_tools empty list" do
    request = %LlmRequest{}
    request = LlmRequest.append_tools(request, [])

    assert request.config[:tools] == nil
    assert map_size(request.tools_dict) == 0
  end

  defmodule NoDeclarationTool do
    defstruct [:name, :description]
    def _get_declaration(_), do: nil
    def name(%{name: n}), do: n
  end

  test "append_tools tool with no declaration" do
    request = %LlmRequest{}
    tool = %NoDeclarationTool{name: "no_decl_tool", description: "A tool with no declaration"}

    request = LlmRequest.append_tools(request, [tool])

    assert request.config[:tools] == nil
  end

  test "append_tools consolidates declarations in single tool" do
    request = %LlmRequest{}
    tool1 = create_dummy_tool("tool1")
    tool2 = create_dummy_tool("tool2")

    request = LlmRequest.append_tools(request, [tool1, tool2])

    assert length(request.config.tools) == 1
    assert length(hd(request.config.tools).function_declarations) == 2
  end

  test "append_instructions with string list" do
    request = %LlmRequest{}

    {request, user_contents} =
      LlmRequest.append_instructions(request, ["Instruction 1", "Instruction 2"])

    assert request.config.system_instruction == "Instruction 1\n\nInstruction 2"
    assert user_contents == []
    assert request.contents == []
  end

  test "append_instructions with string list multiple calls" do
    request = %LlmRequest{}
    {request, _} = LlmRequest.append_instructions(request, ["Instruction 1"])
    {request, _} = LlmRequest.append_instructions(request, ["Instruction 2"])

    assert request.config.system_instruction == "Instruction 1\n\nInstruction 2"
  end

  test "append_instructions empty string list" do
    request = %LlmRequest{}
    {request, user_contents} = LlmRequest.append_instructions(request, [])

    assert request.config[:system_instruction] == nil
    assert user_contents == []
  end

  test "append_instructions invalid input" do
    request = %LlmRequest{}

    assert_raise ArgumentError, fn ->
      LlmRequest.append_instructions(request, 123)
    end
  end

  test "append_instructions with content" do
    request = %LlmRequest{}
    content = %{parts: [%{text: "Instruction 1"}, %{text: "Instruction 2"}]}
    {request, user_contents} = LlmRequest.append_instructions(request, content)

    assert request.config.system_instruction == "Instruction 1\n\nInstruction 2"
    assert user_contents == []
  end

  test "append_instructions with content multipart" do
    request = %LlmRequest{}

    content = %{
      parts: [
        %{text: "Instruction 1"},
        %{inline_data: %{display_name: "image1", mime_type: "image/jpeg", data: "data"}},
        %{text: "Instruction 2"}
      ]
    }

    {request, user_contents} = LlmRequest.append_instructions(request, content)

    sys_inst = request.config.system_instruction
    assert sys_inst =~ "Instruction 1"
    assert sys_inst =~ "Instruction 2"

    assert sys_inst =~
             "[Reference to inline binary data: inline_data_0 ('image1', type: image/jpeg)]"

    assert length(user_contents) == 1
    assert hd(user_contents).role == "user"
    assert length(hd(user_contents).parts) == 2
    assert Enum.at(hd(user_contents).parts, 0).text == "Referenced inline data: inline_data_0"
    assert Map.has_key?(Enum.at(hd(user_contents).parts, 1), :inline_data)
  end

  test "set_output_schema sets schema correctly" do
    request = %LlmRequest{}
    request = LlmRequest.set_output_schema(request, %{type: "object"})

    assert request.config.response_schema == %{type: "object"}
    assert request.config.response_mime_type == "application/json"
  end

  test "set_output_schema raises error when both nil" do
    request = %LlmRequest{}

    assert_raise ArgumentError, fn ->
      LlmRequest.set_output_schema(request, nil, nil)
    end
  end

  test "append_instructions mixed string and content" do
    request = %LlmRequest{}
    {request, _} = LlmRequest.append_instructions(request, ["String 1"])
    content = %{parts: [%{text: "Content 1"}]}
    {request, _} = LlmRequest.append_instructions(request, content)

    assert request.config.system_instruction == "String 1\n\nContent 1"
  end

  test "append_instructions content extracts text only" do
    request = %LlmRequest{}
    content = %{parts: [%{text: "Text part 1"}, %{text: "Text part 2"}]}
    {request, _} = LlmRequest.append_instructions(request, content)

    assert request.config.system_instruction == "Text part 1\n\nText part 2"
  end

  test "append_instructions content no text parts" do
    request = %LlmRequest{}

    content = %{
      parts: [
        %{inline_data: %{mime_type: "image/png", data: "data"}}
      ]
    }

    {request, _} = LlmRequest.append_instructions(request, content)

    assert request.config.system_instruction ==
             "[Reference to inline binary data: inline_data_0 (type: image/png)]"
  end
end
