defmodule ADK.Optimization.SimplePromptOptimizer do
  @moduledoc """
  A naive optimizer that iteratively tries to improve an agent's prompt.
  """

  @behaviour ADK.Optimization.AgentOptimizer

  alias ADK.Optimization.DataTypes.{BaseAgentWithScores, OptimizerResult}
  alias ADK.Optimization.SimplePromptOptimizer.Config

  require Logger

  @optimizer_prompt_template """
  You are an expert prompt engineer. Your task is to improve the system prompt for an AI agent.
  The agent's current prompt achieved an average score of {current_score} on a set of evaluation tasks. A higher score is better.

  Here is the current prompt:
  <current_prompt>
  {current_prompt_text}
  </current_prompt>

  Based on the current prompt, rewrite it to create a new, improved version that is likely to achieve a higher score.
  The agent needs to solve customer support tasks by using tools correctly and following policies.
  Focus on clarity, structure, and providing actionable guidance for the agent.

  **Output only the new, full, improved agent prompt. Do not add any other text, explanations, or markdown formatting.**
  """

  defstruct [:config]

  @doc "Create a new SimplePromptOptimizer."
  def new(opts \\ []) do
    %__MODULE__{config: Config.new(opts)}
  end

  @impl true
  def optimize(%__MODULE__{} = optimizer, initial_agent, sampler) do
    sampler_mod = sampler.__struct__
    train_ids = sampler_mod.get_train_example_ids(sampler)
    batch_size = min(optimizer.config.batch_size, length(train_ids))
    config = %{optimizer.config | batch_size: batch_size}

    {best_agent, _best_score} = run_optimization_iterations(config, initial_agent, sampler, train_ids)

    final_score = run_final_validation(best_agent, sampler)

    {:ok, %OptimizerResult{
      optimized_agents: [
        %BaseAgentWithScores{
          optimized_agent: best_agent,
          overall_score: final_score
        }
      ]
    }}
  end

  defp run_optimization_iterations(config, initial_agent, sampler, train_example_ids) do
    Logger.info("Evaluating initial agent to get baseline score...")
    best_score = score_agent_on_batch(config, initial_agent, sampler, train_example_ids)
    Logger.info("Initial agent baseline score: #{best_score}")

    Enum.reduce(1..config.num_iterations, {initial_agent, best_score}, fn i, {best_agent, current_best_score} ->
      Logger.info("--- Starting optimization iteration #{i}/#{config.num_iterations} ---")
      
      new_prompt_text = generate_candidate_prompt(config, best_agent, current_best_score)
      candidate_agent = %{best_agent | instruction: new_prompt_text}
      
      Logger.info("Generated new candidate prompt:\n#{new_prompt_text}")
      
      candidate_score = score_agent_on_batch(config, candidate_agent, sampler, train_example_ids)
      Logger.info("Candidate score: #{candidate_score} (vs. best score: #{current_best_score})")

      if candidate_score > current_best_score do
        Logger.info("New candidate is better. Updating best agent.")
        {candidate_agent, candidate_score}
      else
        Logger.info("New candidate is not better. Discarding.")
        {best_agent, current_best_score}
      end
    end)
  end

  defp generate_candidate_prompt(config, best_agent, best_score) do
    score_str = :erlang.float_to_binary(best_score * 1.0, decimals: 2)
    prompt =
      @optimizer_prompt_template
      |> String.replace("{current_score}", score_str)
      |> String.replace("{current_prompt_text}", best_agent.instruction || "")

    request = %{
      messages: [
        %{role: :user, parts: [%{text: prompt}]}
      ],
      generation_config: config.model_configuration
    }

    case ADK.LLM.generate(config.optimizer_model, request) do
      {:ok, %{content: %{parts: parts}}} ->
        parts
        |> Enum.filter(fn p -> !Map.get(p, :thought, false) end)
        |> Enum.map_join("", fn
          %{text: t} -> t
          _ -> ""
        end)
        |> String.trim()

      _ ->
        best_agent.instruction || ""
    end
  end

  defp score_agent_on_batch(config, agent, sampler, example_ids) do
    sampler_mod = sampler.__struct__
    eval_batch = Enum.take_random(example_ids, config.batch_size)
    eval_results = sampler_mod.sample_and_score(sampler, agent, :train, eval_batch, false)

    case eval_results.scores do
      empty when map_size(empty) == 0 -> 0.0
      scores ->
        total = Enum.reduce(scores, 0.0, fn {_id, score}, acc -> acc + score end)
        total / map_size(scores)
    end
  end

  defp run_final_validation(best_agent, sampler) do
    sampler_mod = sampler.__struct__
    Logger.info("Optimization loop finished. Running final validation on the best agent found.")
    
    validation_results = sampler_mod.sample_and_score(sampler, best_agent, :validation, nil, false)

    case validation_results.scores do
      empty when map_size(empty) == 0 -> 0.0
      scores ->
        total = Enum.reduce(scores, 0.0, fn {_id, score}, acc -> acc + score end)
        total / map_size(scores)
    end
  end
end
