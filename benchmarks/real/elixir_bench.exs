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
  extract_stats.(scenario6_benchee)
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
