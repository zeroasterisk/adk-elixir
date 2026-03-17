defmodule ADK.SystemInstructionTest do
  use ExUnit.Case, async: true

  alias ADK.Context
  alias ADK.InstructionCompiler
  alias ADK.Session

  test "context_variable" do
    agent = %{
      instruction:
        "Use the echo_info tool to echo {{customerId}}, {{customerInt}}, {{customerFloat}}, and {{customerJson}}. Ask for it if you need to."
    }

    {:ok, pid} = Session.start_link(session_id: "test_session")

    Session.put_state(pid, "customerId", "1234567890")
    Session.put_state(pid, "customerInt", 30)
    Session.put_state(pid, "customerFloat", 12.34)

    Session.put_state(
      pid,
      "customerJson",
      %{"name" => "John Doe", "age" => 30, "count" => 11.1} |> Jason.encode!()
    )

    ctx = %Context{
      invocation_id: "1234567890",
      agent: agent,
      session_pid: pid
    }

    si = InstructionCompiler.compile(agent, ctx)

    assert si ==
             "Use the echo_info tool to echo 1234567890, 30, 12.34, and {\"age\":30,\"count\":11.1,\"name\":\"John Doe\"}. Ask for it if you need to."
  end

  test "context_variable_with_complicated_format" do
    agent = %{
      instruction:
        "Use the echo_info tool to echo {{customerId}}, {{customer_int}}, { non-identifier-float}}, {{fileName}}, {'key1': 'value1'} and {{'key2': 'value2'}}. Ask for it if you need to."
    }

    {:ok, pid} = Session.start_link(session_id: "test_session_2")

    Session.put_state(pid, "customerId", "1234567890")
    Session.put_state(pid, "customer_int", 30)
    Session.put_state(pid, "fileName", "test artifact")

    ctx = %Context{
      invocation_id: "1234567890",
      agent: agent,
      session_pid: pid
    }

    si = InstructionCompiler.compile(agent, ctx)

    assert si ==
             "Use the echo_info tool to echo 1234567890, 30, { non-identifier-float}}, test artifact, {'key1': 'value1'} and {{'key2': 'value2'}}. Ask for it if you need to."
  end

  @nl_planner_si """
  You are an intelligent tool use agent built upon the Gemini large language model. When answering the question, try to leverage the available tools to gather the information instead of your memorized knowledge.

  Follow this process when answering the question: (1) first come up with a plan in natural language text format; (2) Then use tools to execute the plan and provide reasoning between tool code snippets to make a summary of current state and next step. Tool code snippets and reasoning should be interleaved with each other. (3) In the end, return one final answer.

  Follow this format when answering the question: (1) The planning part should be under /*PLANNING*/. (2) The tool code snippets should be under /*ACTION*/, and the reasoning parts should be under /*REASONING*/. (3) The final answer part should be under /*FINAL_ANSWER*/.


  Below are the requirements for the planning:
  The plan is made to answer the user query if following the plan. The plan is coherent and covers all aspects of information from user query, and only involves the tools that are accessible by the agent. The plan contains the decomposed steps as a numbered list where each step should use one or multiple available tools. By reading the plan, you can intuitively know which tools to trigger or what actions to take.
  If the initial plan cannot be successfully executed, you should learn from previous execution results and revise your plan. The revised plan should be be under /*REPLANNING*/. Then use tools to follow the new plan.

  Below are the requirements for the reasoning:
  The reasoning makes a summary of the current trajectory based on the user query and tool outputs. Based on the tool outputs and plan, the reasoning also comes up with instructions to the next steps, making the trajectory closer to the final answer.



  Below are the requirements for the final answer:
  The final answer should be precise and follow query formatting requirements. Some queries may not be answerable with the available tools and information. In those cases, inform the user why you cannot process their query and ask for more information.



  Below are the requirements for the tool code:

  **Custom Tools:** The available tools are described in the context and can be directly used.
  - Code must be valid self-contained Python snippets with no imports and no references to tools or Python libraries that are not in the context.
  - You cannot use any parameters or fields that are not explicitly defined in the APIs in the context.
  - Use "print" to output execution results for the next step or final answer that you need for responding to the user. Never generate ```tool_outputs yourself.
  - The code snippets should be readable, efficient, and directly relevant to the user query and reasoning steps.
  - When using the tools, you should use the library name together with the function name, e.g., vertex_search.search().
  - If Python libraries are not provided in the context, NEVER write your own code other than the function calls using the provided tools.



  VERY IMPORTANT instruction that you MUST follow in addition to the above instructions:

  You should ask for clarification if you need more information to answer the question.
  You should prefer using the information available in the context instead of repeated tool use.

  You should ONLY generate code snippets prefixed with "```tool_code" if you need to use the tools to answer the question.

  If you are asked to write code by user specifically,
  - you should ALWAYS use "```python" to format the code.
  - you should NEVER put "tool_code" to format the code.
  - Good example:
  ```python
  print('hello')
  ```
  - Bad example:
  ```tool_code
  print('hello')
  ```
  """

  test "nl_planner" do
    agent = %{
      global_instruction: @nl_planner_si
    }

    {:ok, pid} = Session.start_link(session_id: "test_session_3")

    Session.put_state(pid, "customerId", "1234567890")

    ctx = %Context{
      invocation_id: "1234567890",
      agent: agent,
      session_pid: pid
    }

    si = InstructionCompiler.compile(agent, ctx)

    Enum.each(String.split(@nl_planner_si, "\n"), fn line ->
      assert si =~ line
    end)
  end

  test "function_instruction" do
    agent = %{
      instruction: "This is the plain text sub agent instruction."
    }

    {:ok, pid} = Session.start_link(session_id: "test_session_4")

    Session.put_state(pid, "customerId", "1234567890")

    ctx = %Context{
      invocation_id: "1234567890",
      agent: agent,
      session_pid: pid
    }

    si = InstructionCompiler.compile(agent, ctx)

    assert si == "This is the plain text sub agent instruction."
  end
end
