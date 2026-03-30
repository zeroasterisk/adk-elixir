defmodule ADK.Planner.PlanReAct do
  @moduledoc """
  Plan-Re-Act planner that constrains the LLM response to generate a plan
  before any action/observation.
  """
  @behaviour ADK.Planner

  defstruct []

  @type t :: %__MODULE__{}

  @planning_tag "/*PLANNING*/"
  @replanning_tag "/*REPLANNING*/"
  @reasoning_tag "/*REASONING*/"
  @action_tag "/*ACTION*/"
  @final_answer_tag "/*FINAL_ANSWER*/"

  @impl ADK.Planner
  def build_planning_instruction(_ctx, _request) do
    build_nl_planner_instruction()
  end

  @impl ADK.Planner
  def process_planning_response(_ctx, parts) when parts == [] or is_nil(parts), do: nil

  def process_planning_response(_ctx, parts) do
    # Find the first valid function call and keep track of preceding parts.
    {preserved_parts, first_fc_part_index} =
      Enum.reduce_while(Enum.with_index(parts), {[], -1}, fn {part, index}, {acc_parts, _idx} ->
        case part do
          %{function_call: %{name: name}} when name != nil and name != "" ->
            {:halt, {acc_parts ++ [part], index}}

          %{function_call: _} ->
            # Ignore function calls with empty names
            {:cont, {acc_parts, -1}}

          _ ->
            new_parts = handle_non_function_call_parts(part)
            {:cont, {acc_parts ++ new_parts, -1}}
        end
      end)

    if first_fc_part_index >= 0 do
      remaining = Enum.drop(parts, first_fc_part_index + 1)

      fc_parts =
        Enum.take_while(remaining, fn
          %{function_call: %{name: _}} -> true
          _ -> false
        end)

      preserved_parts ++ fc_parts
    else
      preserved_parts
    end
  end

  defp split_by_last_pattern(text, pattern) do
    case :binary.matches(text, pattern) do
      [] ->
        {text, ""}

      matches ->
        {last_pos, _len} = List.last(matches)

        {String.slice(text, 0, last_pos + String.length(pattern)),
         String.slice(text, last_pos + String.length(pattern), String.length(text))}
    end
  end

  defp handle_non_function_call_parts(%{text: text} = part) when is_binary(text) do
    if String.contains?(text, @final_answer_tag) do
      {reasoning_text, final_answer_text} = split_by_last_pattern(text, @final_answer_tag)

      parts = []

      parts =
        if reasoning_text != "" do
          parts ++ [mark_as_thought(%{text: reasoning_text})]
        else
          parts
        end

      parts =
        if final_answer_text != "" do
          parts ++ [%{text: final_answer_text}]
        else
          parts
        end

      parts
    else
      if String.starts_with?(text, @planning_tag) or
           String.starts_with?(text, @reasoning_tag) or
           String.starts_with?(text, @action_tag) or
           String.starts_with?(text, @replanning_tag) do
        [mark_as_thought(part)]
      else
        [part]
      end
    end
  end

  defp handle_non_function_call_parts(part), do: [part]

  defp mark_as_thought(%{text: _} = part) do
    Map.put(part, :thought, true)
  end

  defp mark_as_thought(part), do: part

  defp build_nl_planner_instruction do
    high_level_preamble = """
    When answering the question, try to leverage the available tools to gather the information instead of your memorized knowledge.

    Follow this process when answering the question: (1) first come up with a plan in natural language text format; (2) Then use tools to execute the plan and provide reasoning between tool code snippets to make a summary of current state and next step. Tool code snippets and reasoning should be interleaved with each other. (3) In the end, return one final answer.

    Follow this format when answering the question: (1) The planning part should be under #{@planning_tag}. (2) The tool code snippets should be under #{@action_tag}, and the reasoning parts should be under #{@reasoning_tag}. (3) The final answer part should be under #{@final_answer_tag}.
    """

    planning_preamble = """
    Below are the requirements for the planning:
    The plan is made to answer the user query if following the plan. The plan is coherent and covers all aspects of information from user query, and only involves the tools that are accessible by the agent. The plan contains the decomposed steps as a numbered list where each step should use one or multiple available tools. By reading the plan, you can intuitively know which tools to trigger or what actions to take.
    If the initial plan cannot be successfully executed, you should learn from previous execution results and revise your plan. The revised plan should be under #{@replanning_tag}. Then use tools to follow the new plan.
    """

    reasoning_preamble = """
    Below are the requirements for the reasoning:
    The reasoning makes a summary of the current trajectory based on the user query and tool outputs. Based on the tool outputs and plan, the reasoning also comes up with instructions to the next steps, making the trajectory closer to the final answer.
    """

    final_answer_preamble = """
    Below are the requirements for the final answer:
    The final answer should be precise and follow query formatting requirements. Some queries may not be answerable with the available tools and information. In those cases, inform the user why you cannot process their query and ask for more information.
    """

    tool_code_without_python_libraries_preamble = """
    Below are the requirements for the tool code:

    **Custom Tools:** The available tools are described in the context and can be directly used.
    - Code must be valid self-contained Python snippets with no imports and no references to tools or Python libraries that are not in the context.
    - You cannot use any parameters or fields that are not explicitly defined in the APIs in the context.
    - The code snippets should be readable, efficient, and directly relevant to the user query and reasoning steps.
    - When using the tools, you should use the library name together with the function name, e.g., vertex_search.search().
    - If Python libraries are not provided in the context, NEVER write your own code other than the function calls using the provided tools.
    """

    user_input_preamble = """
    VERY IMPORTANT instruction that you MUST follow in addition to the above instructions:

    You should ask for clarification if you need more information to answer the question.
    You should prefer using the information available in the context instead of repeated tool use.
    """

    Enum.join(
      [
        String.trim(high_level_preamble),
        String.trim(planning_preamble),
        String.trim(reasoning_preamble),
        String.trim(final_answer_preamble),
        String.trim(tool_code_without_python_libraries_preamble),
        String.trim(user_input_preamble)
      ],
      "\n\n"
    )
  end
end
