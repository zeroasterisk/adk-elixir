defmodule ADK.Plugin.GlobalInstructionTest do
  use ExUnit.Case, async: false

  alias ADK.Plugin.GlobalInstruction
  alias ADK.Models.LlmRequest
  alias ADK.Context

  setup do
    # Ensure Registry is running clean for each test
    if Process.whereis(ADK.Plugin.Registry) do
      ADK.Plugin.Registry.clear()
    else
      start_supervised!(ADK.Plugin.Registry)
    end

    on_exit(fn ->
      if Process.whereis(ADK.Plugin.Registry), do: ADK.Plugin.Registry.clear()
    end)

    :ok
  end

  test "with a string global instruction" do
    ADK.Plugin.Registry.register(
      {GlobalInstruction, instruction: "You are a helpful assistant with a friendly personality."}
    )

    request = %LlmRequest{
      model: "gemini-1.5-flash",
      config: %{system_instruction: nil}
    }

    context = %Context{}

    assert {:ok, result} = GlobalInstruction.before_model(context, request)

    assert result.config.system_instruction ==
             "You are a helpful assistant with a friendly personality."
  end

  test "with an instruction provider function" do
    provider = fn ctx -> "You are assistant for user #{ctx.user_id}." end
    ADK.Plugin.Registry.register({GlobalInstruction, instruction: provider})

    request = %LlmRequest{
      model: "gemini-1.5-flash",
      config: %{system_instruction: ""}
    }

    context = %Context{user_id: "alice"}

    assert {:ok, result} = GlobalInstruction.before_model(context, request)
    assert result.config.system_instruction == "You are assistant for user alice."
  end

  test "with empty global instruction" do
    ADK.Plugin.Registry.register({GlobalInstruction, instruction: ""})

    request = %LlmRequest{
      model: "gemini-1.5-flash",
      config: %{system_instruction: "Original instruction"}
    }

    context = %Context{}

    assert {:ok, result} = GlobalInstruction.before_model(context, request)
    assert result.config.system_instruction == "Original instruction"
  end

  test "leads existing instructions" do
    ADK.Plugin.Registry.register({GlobalInstruction, instruction: "You are a helpful assistant."})

    request = %LlmRequest{
      model: "gemini-1.5-flash",
      config: %{system_instruction: "Existing instructions."}
    }

    context = %Context{}

    assert {:ok, result} = GlobalInstruction.before_model(context, request)

    assert result.config.system_instruction ==
             "You are a helpful assistant.\n\nExisting instructions."
  end

  test "prepends to a list of instructions" do
    ADK.Plugin.Registry.register({GlobalInstruction, instruction: "Global instruction."})

    request = %LlmRequest{
      model: "gemini-1.5-flash",
      config: %{system_instruction: ["Existing instruction."]}
    }

    context = %Context{}

    assert {:ok, result} = GlobalInstruction.before_model(context, request)
    assert result.config.system_instruction == ["Global instruction.", "Existing instruction."]
  end

  test "injects session state" do
    ADK.Plugin.Registry.register(
      {GlobalInstruction, instruction: "Hello {{name}}, you have {{count}} items."}
    )

    request = %LlmRequest{
      model: "gemini-1.5-flash",
      config: %{}
    }

    context = %Context{temp_state: %{__mock_session_state: %{name: "Alice", count: 42}}}

    assert {:ok, result} = GlobalInstruction.before_model(context, request)
    assert result.config.system_instruction == "Hello Alice, you have 42 items."
  end
end
