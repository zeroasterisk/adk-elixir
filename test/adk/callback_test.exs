defmodule ADK.CallbackTest do
  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.Event
  alias ADK.Runner

  defmodule BeforeAgentCallback do
    @behaviour ADK.Callback
    @impl true
    def before_agent(_context) do
      event =
        Event.new(%{
          author: "agent",
          content: %{parts: [%{text: "End invocation event before agent call."}]}
        })

      {:halt, [event]}
    end
  end

  defmodule BeforeModelCallback do
    @behaviour ADK.Callback
    @impl true
    def before_model(_context) do
      response =
        %{
          content: %{
            role: "model",
            parts: [
              %{text: "End invocation event before model call."}
            ]
          },
          usage_metadata: nil
        }

      {:halt, {:ok, response}}
    end
  end

  defmodule AfterModelCallback do
    @behaviour ADK.Callback
    @impl true
    def after_model({:ok, llm_response}, _context) do
      new_parts =
        llm_response.content.parts
        |> Enum.map(fn part ->
          if part[:text] do
            %{part | text: part.text <> "Update response event after model call."}
          else
            part
          end
        end)

      updated_content = %{llm_response.content | parts: new_parts}
      updated_response = %{llm_response | content: updated_content}

      {:ok, updated_response}
    end

    def after_model({:error, _reason} = error, _context), do: error
  end

  # Test Cases

  test "before_agent callback ends invocation" do
    agent =
      LlmAgent.new(
        model: "gemini-1.5-flash",
        name: "before_agent_callback_agent",
        instruction: "echo 1"
      )

    runner = Runner.new(app_name: "test", agent: agent)
    [response] = Runner.run(runner, "user1", "s1", "Hi.", callbacks: [BeforeAgentCallback])
    assert Event.text(response) == "End invocation event before agent call."
  end

  test "before_model callback ends invocation" do
    agent =
      LlmAgent.new(
        model: "gemini-1.5-flash",
        name: "before_model_callback_agent",
        instruction: "echo 2"
      )

    runner = Runner.new(app_name: "test", agent: agent)
    [response] = Runner.run(runner, "user1", "s2", "Hi.", callbacks: [BeforeModelCallback])
    assert Event.text(response) == "End invocation event before model call."
  end

  test "after_model callback updates response" do
    ADK.LLM.Mock.set_responses(["Hello."])

    agent =
      LlmAgent.new(
        model: "gemini-1.5-flash",
        name: "after_model_callback_agent",
        instruction: "Say hello"
      )

    runner = Runner.new(app_name: "test", agent: agent)
    [response] = Runner.run(runner, "user1", "s3", "Hi.", callbacks: [AfterModelCallback])
    assert Event.text(response) == "Hello.Update response event after model call."
  end
end
