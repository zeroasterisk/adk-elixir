#!/usr/bin/env elixir
# Real ADK Elixir Benchmarks — mocked LLM, pure framework overhead
#
# Run: cd adk-elixir && mix run benchmarks/real/elixir_bench.exs
#
# Each scenario uses ADK.LLM.Mock so no real API calls are made.
# Results are written to benchmarks/real/elixir_results.json

defmodule BenchHelper do
  @moduledoc false

  def measure_memory(fun) do
    :erlang.garbage_collect()
    mem_before = :erlang.memory(:total)
    result = fun.()
    :erlang.garbage_collect()
    mem_after = :erlang.memory(:total)
    {result, max(0, mem_after - mem_before)}
  end

  def make_tool(name, description \\ "A tool") do
    ADK.Tool.FunctionTool.new(String.to_atom(name),
      description: description,
      func: fn _ctx, args -> {:ok, "Result from #{name}: #{inspect(args)}"} end,
      parameters: %{
        type: "object",
        properties: %{input: %{type: "string"}},
        required: ["input"]
      }
    )
  end

  def run_conversation(runner, user_id, session_id, turns) do
    Enum.each(1..turns, fn i ->
      ADK.Runner.run(runner, user_id, "#{session_id}-#{i}", "Turn #{i} message")
    end)
  end
end

IO.puts("=== ADK Elixir Real Benchmarks ===\n")

# Ensure application is started
Application.ensure_all_started(:adk)

# ─────────────────────────────────────────────────────────────
# Scenario 1: Single agent + 3 tools, 10-turn conversation
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 1: Single agent + 3 tools, 10-turn conversation")

scenario1_fn = fn ->
  # Set up mock responses: for each turn, LLM calls a tool then responds
  # 10 turns × 2 responses (tool call + final answer) = 20 responses
  responses =
    Enum.flat_map(1..10, fn i ->
      [
        %{function_call: %{name: "lookup", args: %{"input" => "q#{i}"}, id: "fc-#{i}"}},
        "Answer for turn #{i}"
      ]
    end)

  ADK.LLM.Mock.set_responses(responses)

  tools = [
    BenchHelper.make_tool("lookup", "Look up information"),
    BenchHelper.make_tool("calculate", "Calculate something"),
    BenchHelper.make_tool("format", "Format output")
  ]

  agent = ADK.Agent.LlmAgent.new(
    name: "assistant",
    model: "mock",
    instruction: "You are a helpful assistant with tools.",
    tools: tools
  )

  runner = ADK.Runner.new(app_name: "bench1", agent: agent)

  # Run 10 turns, each in its own session to avoid session state accumulation
  Enum.each(1..10, fn i ->
    ADK.LLM.Mock.set_responses([
      %{function_call: %{name: "lookup", args: %{"input" => "q#{i}"}, id: "fc-#{i}"}},
      "Answer for turn #{i}"
    ])
    ADK.Runner.run(runner, "user1", "s1-#{System.unique_integer([:positive])}", "Turn #{i}")
  end)
end

scenario1_benchee = Benchee.run(
  %{"scenario1_single_agent_3tools_10turn" => scenario1_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 2: 3-agent sequential pipeline (research → write → edit)
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 2: 3-agent sequential pipeline")

scenario2_fn = fn ->
  ADK.LLM.Mock.set_responses([
    "Research findings: Elixir is great for concurrency.",
    "Draft article: Elixir leverages the BEAM VM...",
    "Edited article: The Elixir programming language..."
  ])

  researcher = ADK.Agent.LlmAgent.new(name: "researcher", model: "mock", instruction: "Research the topic.")
  writer = ADK.Agent.LlmAgent.new(name: "writer", model: "mock", instruction: "Write an article.")
  editor = ADK.Agent.LlmAgent.new(name: "editor", model: "mock", instruction: "Edit for clarity.")

  pipeline = ADK.Agent.SequentialAgent.new(
    name: "pipeline",
    sub_agents: [researcher, writer, editor]
  )

  runner = ADK.Runner.new(app_name: "bench2", agent: pipeline)
  ADK.Runner.run(runner, "user1", "s2-#{System.unique_integer([:positive])}", "Write about Elixir")
end

scenario2_benchee = Benchee.run(
  %{"scenario2_sequential_pipeline" => scenario2_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 3: Parallel fan-out — ParallelAgent with 5 sub-agents
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 3: Parallel fan-out (5 sub-agents)")

scenario3_fn = fn ->
  sub_agents = Enum.map(1..5, fn i ->
    ADK.LLM.Mock.set_responses(["Result from agent #{i}"])
    ADK.Agent.LlmAgent.new(
      name: "worker_#{i}",
      model: "mock",
      instruction: "Process shard #{i}."
    )
  end)

  # Each sub-agent needs its own mock response — but Mock uses process dict.
  # ParallelAgent runs in Tasks, so we need a different approach.
  # Set enough responses for all 5.
  ADK.LLM.Mock.set_responses([
    "Result from agent 1",
    "Result from agent 2",
    "Result from agent 3",
    "Result from agent 4",
    "Result from agent 5"
  ])

  fan_out = ADK.Agent.ParallelAgent.new(
    name: "fan_out",
    sub_agents: sub_agents
  )

  runner = ADK.Runner.new(app_name: "bench3", agent: fan_out)
  ADK.Runner.run(runner, "user1", "s3-#{System.unique_integer([:positive])}", "Process all shards")
end

scenario3_benchee = Benchee.run(
  %{"scenario3_parallel_fanout" => scenario3_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 4: 100 concurrent sessions
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 4: 100 concurrent sessions")

scenario4_fn = fn ->
  agent = ADK.Agent.LlmAgent.new(
    name: "shared_agent",
    model: "mock",
    instruction: "You help users."
  )

  runner = ADK.Runner.new(app_name: "bench4", agent: agent)

  tasks = Enum.map(1..100, fn i ->
    Task.async(fn ->
      ADK.LLM.Mock.set_responses(["Response for user #{i}"])
      ADK.Runner.run(runner, "user_#{i}", "s4-#{i}-#{System.unique_integer([:positive])}", "Hello from user #{i}")
    end)
  end)

  Task.await_many(tasks, 30_000)
end

scenario4_benchee = Benchee.run(
  %{"scenario4_100_concurrent_sessions" => scenario4_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 5: Context compression — 200-message history
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 5: Context compression (200 messages → TokenBudget)")

scenario5_fn = fn ->
  # Build 200 messages simulating a long conversation
  messages = Enum.map(1..200, fn i ->
    role = if rem(i, 2) == 0, do: :model, else: :user
    %{role: role, parts: [%{text: "Message number #{i} with some content to make it realistically sized. This is padding text to simulate real conversation messages that contain meaningful content."}]}
  end)

  ADK.Context.Compressor.TokenBudget.compress(
    messages,
    [token_budget: 1000, keep_recent: 5, keep_system: true]
  )
end

scenario5_benchee = Benchee.run(
  %{"scenario5_context_compression" => scenario5_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 6: Agent transfer chain — A → B → C → back to A
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 6: Agent transfer chain (A → B → C → A)")

scenario6_fn = fn ->
  ADK.LLM.Mock.set_responses([
    # A transfers to B
    %{function_call: %{name: "transfer_to_agent_agent_b", args: %{}, id: "fc-1"}},
    # B transfers to C
    %{function_call: %{name: "transfer_to_agent_agent_c", args: %{}, id: "fc-2"}},
    # C responds (can't transfer back to A in tree structure, so it responds)
    "Final response from C after chain A→B→C"
  ])

  agent_c = ADK.Agent.LlmAgent.new(
    name: "agent_c",
    model: "mock",
    instruction: "You are agent C.",
    description: "Final handler"
  )

  agent_b = ADK.Agent.LlmAgent.new(
    name: "agent_b",
    model: "mock",
    instruction: "You are agent B.",
    description: "Intermediate handler",
    sub_agents: [agent_c]
  )

  agent_a = ADK.Agent.LlmAgent.new(
    name: "agent_a",
    model: "mock",
    instruction: "You are agent A, the coordinator.",
    sub_agents: [agent_b]
  )

  runner = ADK.Runner.new(app_name: "bench6", agent: agent_a)
  ADK.Runner.run(runner, "user1", "s6-#{System.unique_integer([:positive])}", "Start the chain")
end

scenario6_benchee = Benchee.run(
  %{"scenario6_transfer_chain" => scenario6_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 7: Context compression at 2,000 messages
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 7: Context compression (2,000 messages → TokenBudget)")

scenario7_fn = fn ->
  messages = Enum.map(1..2000, fn i ->
    role = if rem(i, 2) == 0, do: :model, else: :user
    %{role: role, parts: [%{text: "Message number #{i} with some content to make it realistically sized. This is padding text to simulate real conversation messages that contain meaningful content."}]}
  end)

  ADK.Context.Compressor.TokenBudget.compress(
    messages,
    [token_budget: 1000, keep_recent: 5, keep_system: true]
  )
end

scenario7_benchee = Benchee.run(
  %{"scenario7_compression_2000msg" => scenario7_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 8: Large fan-out — ParallelAgent with 20 sub-agents
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 8: Large fan-out (20 sub-agents)")

scenario8_fn = fn ->
  sub_agents = Enum.map(1..20, fn i ->
    ADK.Agent.LlmAgent.new(
      name: "worker_#{i}",
      model: "mock",
      instruction: "Process shard #{i}."
    )
  end)

  ADK.LLM.Mock.set_responses(
    Enum.map(1..20, fn i -> "Result from agent #{i}" end)
  )

  fan_out = ADK.Agent.ParallelAgent.new(
    name: "fan_out_20",
    sub_agents: sub_agents
  )

  runner = ADK.Runner.new(app_name: "bench8", agent: fan_out)
  ADK.Runner.run(runner, "user1", "s8-#{System.unique_integer([:positive])}", "Process all shards")
end

scenario8_benchee = Benchee.run(
  %{"scenario8_large_fanout_20" => scenario8_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 9: Deep fan-out — 5 ParallelAgents, each with 5 sub-agents (25 total)
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 9: Deep fan-out (5×5 = 25 agents)")

scenario9_fn = fn ->
  # 25 responses needed (5 groups × 5 workers)
  ADK.LLM.Mock.set_responses(
    Enum.map(1..25, fn i -> "Result from deep worker #{i}" end)
  )

  outer_agents = Enum.map(1..5, fn g ->
    inner_agents = Enum.map(1..5, fn w ->
      ADK.Agent.LlmAgent.new(
        name: "group#{g}_worker#{w}",
        model: "mock",
        instruction: "Process group #{g} shard #{w}."
      )
    end)

    ADK.Agent.ParallelAgent.new(
      name: "group_#{g}",
      sub_agents: inner_agents
    )
  end)

  deep_fan = ADK.Agent.ParallelAgent.new(
    name: "deep_fan_out",
    sub_agents: outer_agents
  )

  runner = ADK.Runner.new(app_name: "bench9", agent: deep_fan)
  ADK.Runner.run(runner, "user1", "s9-#{System.unique_integer([:positive])}", "Process all groups")
end

scenario9_benchee = Benchee.run(
  %{"scenario9_deep_fanout_5x5" => scenario9_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 10: Complex workflow — Sequential → Parallel → Loop
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 10: Complex workflow (Sequential → Parallel → Loop)")

scenario10_fn = fn ->
  # LlmAgent response + 3 parallel responses + 2 loop iterations (1 response each) = 6 responses
  ADK.LLM.Mock.set_responses([
    "Step 1: Initial analysis complete.",
    "Parallel worker A result.",
    "Parallel worker B result.",
    "Parallel worker C result.",
    "Loop iteration 1: refining...",
    "Loop iteration 2: done."
  ])

  step1 = ADK.Agent.LlmAgent.new(name: "analyzer", model: "mock", instruction: "Analyze the input.")

  parallel_workers = Enum.map(["A", "B", "C"], fn name ->
    ADK.Agent.LlmAgent.new(name: "parallel_#{name}", model: "mock", instruction: "Process shard #{name}.")
  end)
  step2 = ADK.Agent.ParallelAgent.new(name: "parallel_step", sub_agents: parallel_workers)

  refiner = ADK.Agent.LlmAgent.new(name: "refiner", model: "mock", instruction: "Refine the results.")
  step3 = ADK.Agent.LoopAgent.new(name: "refine_loop", sub_agents: [refiner], max_iterations: 2)

  pipeline = ADK.Agent.SequentialAgent.new(
    name: "complex_pipeline",
    sub_agents: [step1, step2, step3]
  )

  runner = ADK.Runner.new(app_name: "bench10", agent: pipeline)
  ADK.Runner.run(runner, "user1", "s10-#{System.unique_integer([:positive])}", "Run complex workflow")
end

scenario10_benchee = Benchee.run(
  %{"scenario10_complex_workflow" => scenario10_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 11: Long transfer chain — A → B → C → D → E → F
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 11: Long transfer chain (A → B → C → D → E → F)")

scenario11_fn = fn ->
  ADK.LLM.Mock.set_responses([
    %{function_call: %{name: "transfer_to_agent_agent_b", args: %{}, id: "fc-1"}},
    %{function_call: %{name: "transfer_to_agent_agent_c", args: %{}, id: "fc-2"}},
    %{function_call: %{name: "transfer_to_agent_agent_d", args: %{}, id: "fc-3"}},
    %{function_call: %{name: "transfer_to_agent_agent_e", args: %{}, id: "fc-4"}},
    %{function_call: %{name: "transfer_to_agent_agent_f", args: %{}, id: "fc-5"}},
    "Final response from F after chain A→B→C→D→E→F"
  ])

  agent_f = ADK.Agent.LlmAgent.new(name: "agent_f", model: "mock", instruction: "You are agent F.", description: "Final handler")
  agent_e = ADK.Agent.LlmAgent.new(name: "agent_e", model: "mock", instruction: "You are agent E.", description: "Handler E", sub_agents: [agent_f])
  agent_d = ADK.Agent.LlmAgent.new(name: "agent_d", model: "mock", instruction: "You are agent D.", description: "Handler D", sub_agents: [agent_e])
  agent_c = ADK.Agent.LlmAgent.new(name: "agent_c", model: "mock", instruction: "You are agent C.", description: "Handler C", sub_agents: [agent_d])
  agent_b = ADK.Agent.LlmAgent.new(name: "agent_b", model: "mock", instruction: "You are agent B.", description: "Handler B", sub_agents: [agent_c])
  agent_a = ADK.Agent.LlmAgent.new(name: "agent_a", model: "mock", instruction: "You are agent A, the coordinator.", sub_agents: [agent_b])

  runner = ADK.Runner.new(app_name: "bench11", agent: agent_a)
  ADK.Runner.run(runner, "user1", "s11-#{System.unique_integer([:positive])}", "Start the long chain")
end

scenario11_benchee = Benchee.run(
  %{"scenario11_long_transfer_chain" => scenario11_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 12: Transfer with backtracking (A → B → C → B → A → B → C)
# Note: ADK tree structure means we simulate this as a deep chain
# where agents at different levels produce multiple responses.
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 12: Transfer with backtracking")

scenario12_fn = fn ->
  # A→B (transfer), B→C (transfer), C responds, then another round:
  # Simulate backtracking as multiple sequential transfers within the tree.
  # The tree is: A > B > C, and we do A→B→C then C responds, B responds, A responds
  # (7 LLM calls total to simulate back-and-forth routing overhead)
  ADK.LLM.Mock.set_responses([
    %{function_call: %{name: "transfer_to_agent_agent_b", args: %{}, id: "fc-1"}},
    %{function_call: %{name: "transfer_to_agent_agent_c", args: %{}, id: "fc-2"}},
    "Response from C (first pass)",
    "Response from B (backtrack)",
    "Response from A (backtrack)",
    %{function_call: %{name: "transfer_to_agent_agent_b", args: %{}, id: "fc-6"}},
    "Final response after backtracking"
  ])

  agent_c = ADK.Agent.LlmAgent.new(name: "agent_c", model: "mock", instruction: "You are agent C.", description: "Handler C")
  agent_b = ADK.Agent.LlmAgent.new(name: "agent_b", model: "mock", instruction: "You are agent B.", description: "Handler B", sub_agents: [agent_c])
  agent_a = ADK.Agent.LlmAgent.new(name: "agent_a", model: "mock", instruction: "You are agent A.", sub_agents: [agent_b])

  runner = ADK.Runner.new(app_name: "bench12", agent: agent_a)
  ADK.Runner.run(runner, "user1", "s12-#{System.unique_integer([:positive])}", "Start backtracking chain")
end

scenario12_benchee = Benchee.run(
  %{"scenario12_transfer_backtracking" => scenario12_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 13: Error handling overhead
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 13: Error handling (tool exception + recovery)")

scenario13_fn = fn ->
  error_tool = ADK.Tool.FunctionTool.new(:risky_tool,
    description: "A tool that might fail",
    func: fn _ctx, _args -> raise "Simulated tool failure!" end,
    parameters: %{
      type: "object",
      properties: %{input: %{type: "string"}},
      required: ["input"]
    }
  )

  safe_tool = ADK.Tool.FunctionTool.new(:safe_tool,
    description: "A safe fallback tool",
    func: fn _ctx, args -> {:ok, "Safe result: #{inspect(args)}"} end,
    parameters: %{
      type: "object",
      properties: %{input: %{type: "string"}},
      required: ["input"]
    }
  )

  ADK.LLM.Mock.set_responses([
    %{function_call: %{name: "risky_tool", args: %{"input" => "test"}, id: "fc-1"}},
    %{function_call: %{name: "safe_tool", args: %{"input" => "fallback"}, id: "fc-2"}},
    "Recovered successfully after error"
  ])

  agent = ADK.Agent.LlmAgent.new(
    name: "error_handler",
    model: "mock",
    instruction: "You handle errors gracefully.",
    tools: [error_tool, safe_tool]
  )

  runner = ADK.Runner.new(app_name: "bench13", agent: agent)
  ADK.Runner.run(runner, "user1", "s13-#{System.unique_integer([:positive])}", "Test error handling")
end

scenario13_benchee = Benchee.run(
  %{"scenario13_error_handling" => scenario13_fn},
  warmup: 2,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 14: 500 concurrent sessions
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 14: 500 concurrent sessions")

scenario14_fn = fn ->
  agent = ADK.Agent.LlmAgent.new(
    name: "shared_agent_500",
    model: "mock",
    instruction: "You help users."
  )

  runner = ADK.Runner.new(app_name: "bench14", agent: agent)

  tasks = Enum.map(1..500, fn i ->
    Task.async(fn ->
      ADK.LLM.Mock.set_responses(["Response for user #{i}"])
      ADK.Runner.run(runner, "user_#{i}", "s14-#{i}-#{System.unique_integer([:positive])}", "Hello from user #{i}")
    end)
  end)

  Task.await_many(tasks, 60_000)
end

scenario14_benchee = Benchee.run(
  %{"scenario14_500_concurrent_sessions" => scenario14_fn},
  warmup: 1,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Scenario 15: Mixed load (realistic production simulation)
# 50 concurrent sessions, each running a 3-agent pipeline with tools
# ─────────────────────────────────────────────────────────────

IO.puts("▸ Scenario 15: Mixed load (50 sessions × 3-agent pipeline + tools)")

scenario15_fn = fn ->
  tool = ADK.Tool.FunctionTool.new(:process_data,
    description: "Process data",
    func: fn _ctx, args -> {:ok, "Processed: #{inspect(args)}"} end,
    parameters: %{
      type: "object",
      properties: %{input: %{type: "string"}},
      required: ["input"]
    }
  )

  tasks = Enum.map(1..50, fn i ->
    Task.async(fn ->
      # Each session: 3-agent sequential pipeline with tool calls
      # Agent 1 calls tool + responds, Agent 2 responds, Agent 3 responds = 4 LLM responses
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "process_data", args: %{"input" => "data_#{i}"}, id: "fc-#{i}"}},
        "Agent 1 processed data for session #{i}",
        "Agent 2 wrote report for session #{i}",
        "Agent 3 edited report for session #{i}"
      ])

      agent1 = ADK.Agent.LlmAgent.new(name: "processor", model: "mock", instruction: "Process input.", tools: [tool])
      agent2 = ADK.Agent.LlmAgent.new(name: "writer", model: "mock", instruction: "Write report.")
      agent3 = ADK.Agent.LlmAgent.new(name: "editor", model: "mock", instruction: "Edit report.")

      pipeline = ADK.Agent.SequentialAgent.new(
        name: "pipeline_#{i}",
        sub_agents: [agent1, agent2, agent3]
      )

      runner = ADK.Runner.new(app_name: "bench15_#{i}", agent: pipeline)
      ADK.Runner.run(runner, "user_#{i}", "s15-#{i}-#{System.unique_integer([:positive])}", "Process request #{i}")
    end)
  end)

  Task.await_many(tasks, 60_000)
end

scenario15_benchee = Benchee.run(
  %{"scenario15_mixed_load" => scenario15_fn},
  warmup: 1,
  time: 10,
  memory_time: 2,
  print: [configuration: false],
  formatters: []
)

# ─────────────────────────────────────────────────────────────
# Collect and output results
# ─────────────────────────────────────────────────────────────

IO.puts("\n=== Results Summary ===\n")

extract_stats = fn benchee_result ->
  scenario = benchee_result.scenarios |> List.first()
  stats = scenario.run_time_data.statistics

  memory_stats = if scenario.memory_usage_data && scenario.memory_usage_data.statistics do
    scenario.memory_usage_data.statistics
  else
    nil
  end

  %{
    name: scenario.name,
    # Benchee reports in nanoseconds; convert to microseconds
    mean_us: Float.round(stats.average / 1_000, 2),
    median_us: Float.round(stats.median / 1_000, 2),
    p99_us: Float.round(stats.percentiles[99] / 1_000, 2),
    std_dev_us: Float.round(stats.std_dev / 1_000, 2),
    ips: Float.round(stats.ips, 2),
    sample_size: stats.sample_size,
    memory_mean_bytes: if(memory_stats, do: memory_stats.average, else: nil)
  }
end

all_results = [
  extract_stats.(scenario1_benchee),
  extract_stats.(scenario2_benchee),
  extract_stats.(scenario3_benchee),
  extract_stats.(scenario4_benchee),
  extract_stats.(scenario5_benchee),
  extract_stats.(scenario6_benchee),
  extract_stats.(scenario7_benchee),
  extract_stats.(scenario8_benchee),
  extract_stats.(scenario9_benchee),
  extract_stats.(scenario10_benchee),
  extract_stats.(scenario11_benchee),
  extract_stats.(scenario12_benchee),
  extract_stats.(scenario13_benchee),
  extract_stats.(scenario14_benchee),
  extract_stats.(scenario15_benchee)
]

Enum.each(all_results, fn r ->
  IO.puts("#{r.name}:")
  IO.puts("  Mean: #{r.mean_us} µs | Median: #{r.median_us} µs | P99: #{r.p99_us} µs")
  IO.puts("  StdDev: #{r.std_dev_us} µs | IPS: #{r.ips} | Samples: #{r.sample_size}")
  if r.memory_mean_bytes do
    IO.puts("  Memory (mean): #{Float.round(r.memory_mean_bytes / 1024, 2)} KB")
  end
  IO.puts("")
end)

# Write JSON results
json = Jason.encode!(all_results, pretty: true)
File.write!("benchmarks/real/elixir_results.json", json)
IO.puts("Results written to benchmarks/real/elixir_results.json")
