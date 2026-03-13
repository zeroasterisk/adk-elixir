#!/usr/bin/env python3
"""
Real ADK Python Benchmarks — mocked LLM, pure framework overhead.

Run:
  cd adk-elixir/benchmarks/real
  . .venv/bin/activate
  python python_bench.py

Uses google-adk with a custom MockLlm so no real API calls are made.
Results are written to benchmarks/real/python_results.json
"""

import asyncio
import json
import statistics
import time
import tracemalloc
import threading
from typing import AsyncGenerator

from google.adk.agents import Agent, SequentialAgent, ParallelAgent
from google.adk.models.base_llm import BaseLlm
from google.adk.models.llm_request import LlmRequest
from google.adk.models.llm_response import LlmResponse
from google.adk.models.registry import LLMRegistry
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.adk.tools import FunctionTool
from google.genai import types


# ─────────────────────────────────────────────────────────────
# Mock LLM
# ─────────────────────────────────────────────────────────────

_response_queues: dict[int, list] = {}


class MockLlm(BaseLlm):
    """Mock LLM that returns canned responses from a thread-local queue."""

    @classmethod
    def supported_models(cls):
        return [r"mock.*"]

    async def generate_content_async(
        self, llm_request: LlmRequest, stream: bool = False
    ) -> AsyncGenerator[LlmResponse, None]:
        tid = threading.current_thread().ident
        queue = _response_queues.get(tid, [])
        if queue:
            yield queue.pop(0)
        else:
            yield LlmResponse(
                content=types.Content(
                    role="model", parts=[types.Part(text="Echo fallback")]
                )
            )


# Register mock before anything else
LLMRegistry._register(r"mock.*", MockLlm)


def set_mock_responses(responses: list[LlmResponse]):
    _response_queues[threading.current_thread().ident] = list(responses)


def text_response(text: str) -> LlmResponse:
    return LlmResponse(
        content=types.Content(role="model", parts=[types.Part(text=text)]),
        turn_complete=True,
    )


def fc_response(name: str, args: dict | None = None) -> LlmResponse:
    fc = types.FunctionCall(name=name, args=args or {}, id="fc-auto")
    return LlmResponse(
        content=types.Content(role="model", parts=[types.Part(function_call=fc)])
    )


# ─────────────────────────────────────────────────────────────
# Tools (matching Elixir benchmark)
# ─────────────────────────────────────────────────────────────


def lookup(input: str) -> str:
    """Look up information."""
    return f"Result from lookup: {input}"


def calculate(input: str) -> str:
    """Calculate something."""
    return f"Result from calculate: {input}"


def format_output(input: str) -> str:
    """Format output."""
    return f"Result from format: {input}"


# ─────────────────────────────────────────────────────────────
# Benchmark harness
# ─────────────────────────────────────────────────────────────

ITERATIONS = 200
WARMUP = 20


def run_benchmark(name: str, fn) -> dict:
    """Run a benchmark function ITERATIONS times, collecting timing and memory."""
    print(f"▸ {name}")

    # Warmup
    for _ in range(WARMUP):
        asyncio.run(fn())

    times_ns = []
    memory_deltas = []

    for _ in range(ITERATIONS):
        tracemalloc.start()
        mem_before = tracemalloc.get_traced_memory()[0]

        t0 = time.perf_counter_ns()
        asyncio.run(fn())
        t1 = time.perf_counter_ns()

        mem_after = tracemalloc.get_traced_memory()[1]  # peak
        tracemalloc.stop()

        times_ns.append(t1 - t0)
        memory_deltas.append(max(0, mem_after - mem_before))

    times_us = [t / 1000 for t in times_ns]
    times_us.sort()

    p99_idx = int(len(times_us) * 0.99)
    p99 = times_us[p99_idx] if p99_idx < len(times_us) else times_us[-1]

    mean_us = statistics.mean(times_us)
    median_us = statistics.median(times_us)
    std_dev_us = statistics.stdev(times_us) if len(times_us) > 1 else 0
    ips = 1_000_000 / mean_us if mean_us > 0 else 0
    mean_mem_bytes = statistics.mean(memory_deltas)

    result = {
        "name": name,
        "mean_us": round(mean_us, 2),
        "median_us": round(median_us, 2),
        "p99_us": round(p99, 2),
        "std_dev_us": round(std_dev_us, 2),
        "ips": round(ips, 2),
        "sample_size": ITERATIONS,
        "memory_mean_bytes": round(mean_mem_bytes, 2),
    }

    print(
        f"  Mean: {result['mean_us']} µs | Median: {result['median_us']} µs | P99: {result['p99_us']} µs"
    )
    print(
        f"  StdDev: {result['std_dev_us']} µs | IPS: {result['ips']} | Samples: {result['sample_size']}"
    )
    print(f"  Memory (mean): {round(mean_mem_bytes / 1024, 2)} KB")
    print()
    return result


# ─────────────────────────────────────────────────────────────
# Scenario 1: Single agent + 3 tools, 10-turn conversation
# ─────────────────────────────────────────────────────────────


async def scenario1():
    session_service = InMemorySessionService()

    tools = [
        FunctionTool(func=lookup),
        FunctionTool(func=calculate),
        FunctionTool(func=format_output),
    ]

    agent = Agent(
        name="assistant",
        model="mock",
        instruction="You are a helpful assistant with tools.",
        tools=tools,
    )

    runner = Runner(
        app_name="bench1", agent=agent, session_service=session_service
    )

    for turn in range(1, 11):
        session = await session_service.create_session(
            app_name="bench1", user_id="user1"
        )

        set_mock_responses([
            fc_response("lookup", {"input": f"q{turn}"}),
            text_response(f"Answer for turn {turn}"),
        ])

        content = types.Content(
            role="user", parts=[types.Part(text=f"Turn {turn}")]
        )
        async for _ in runner.run_async(
            user_id="user1", session_id=session.id, new_message=content
        ):
            pass


# ─────────────────────────────────────────────────────────────
# Scenario 2: 3-agent sequential pipeline
# ─────────────────────────────────────────────────────────────


async def scenario2():
    session_service = InMemorySessionService()

    set_mock_responses([
        text_response("Research findings: Elixir is great for concurrency."),
        text_response("Draft article: Elixir leverages the BEAM VM..."),
        text_response("Edited article: The Elixir programming language..."),
    ])

    researcher = Agent(name="researcher", model="mock", instruction="Research the topic.")
    writer = Agent(name="writer", model="mock", instruction="Write an article.")
    editor = Agent(name="editor", model="mock", instruction="Edit for clarity.")

    pipeline = SequentialAgent(
        name="pipeline", sub_agents=[researcher, writer, editor]
    )

    runner = Runner(
        app_name="bench2", agent=pipeline, session_service=session_service
    )
    session = await session_service.create_session(
        app_name="bench2", user_id="user1"
    )

    content = types.Content(
        role="user", parts=[types.Part(text="Write about Elixir")]
    )
    async for _ in runner.run_async(
        user_id="user1", session_id=session.id, new_message=content
    ):
        pass


# ─────────────────────────────────────────────────────────────
# Scenario 3: Parallel fan-out (5 sub-agents)
# ─────────────────────────────────────────────────────────────


async def scenario3():
    session_service = InMemorySessionService()

    workers = [
        Agent(name=f"worker_{i}", model="mock", instruction=f"Process shard {i}.")
        for i in range(1, 6)
    ]

    set_mock_responses([text_response(f"Result from agent {i}") for i in range(1, 6)])

    fan_out = ParallelAgent(name="fan_out", sub_agents=workers)

    runner = Runner(
        app_name="bench3", agent=fan_out, session_service=session_service
    )
    session = await session_service.create_session(
        app_name="bench3", user_id="user1"
    )

    content = types.Content(
        role="user", parts=[types.Part(text="Process all shards")]
    )
    async for _ in runner.run_async(
        user_id="user1", session_id=session.id, new_message=content
    ):
        pass


# ─────────────────────────────────────────────────────────────
# Scenario 4: 100 concurrent sessions
# ─────────────────────────────────────────────────────────────


async def scenario4():
    session_service = InMemorySessionService()

    agent = Agent(
        name="shared_agent", model="mock", instruction="You help users."
    )

    runner = Runner(
        app_name="bench4", agent=agent, session_service=session_service
    )

    async def run_one(i: int):
        session = await session_service.create_session(
            app_name="bench4", user_id=f"user_{i}"
        )
        set_mock_responses([text_response(f"Response for user {i}")])
        content = types.Content(
            role="user", parts=[types.Part(text=f"Hello from user {i}")]
        )
        async for _ in runner.run_async(
            user_id=f"user_{i}", session_id=session.id, new_message=content
        ):
            pass

    await asyncio.gather(*[run_one(i) for i in range(100)])


# ─────────────────────────────────────────────────────────────
# Scenario 5: Context compression (200 messages)
# Note: Python ADK doesn't expose TokenBudget as a standalone
# compressor — we benchmark the equivalent: building 200 messages
# and truncating to budget using list comprehension (the Python
# ADK approach via request processors).
# ─────────────────────────────────────────────────────────────


async def scenario5():
    """Simulate token budget compaction on 200 messages."""
    messages = [
        types.Content(
            role="model" if i % 2 == 0 else "user",
            parts=[
                types.Part(
                    text=f"Message number {i} with some content to make it realistically sized. "
                    "This is padding text to simulate real conversation messages "
                    "that contain meaningful content."
                )
            ],
        )
        for i in range(200)
    ]

    # Simulate token budget compaction (chars / 4 = tokens)
    token_budget = 1000
    chars_per_token = 4
    keep_recent = 5

    # Always keep system messages and last N
    recent = messages[-keep_recent:]
    older = messages[:-keep_recent]

    # Estimate tokens for recent
    def estimate_tokens(msgs):
        total_chars = sum(
            len(p.text or "")
            for m in msgs
            for p in (m.parts or [])
        )
        return total_chars // chars_per_token

    recent_tokens = estimate_tokens(recent)
    remaining_budget = token_budget - recent_tokens

    # Fill from newest-old backward
    kept = []
    for msg in reversed(older):
        msg_tokens = estimate_tokens([msg])
        if remaining_budget >= msg_tokens:
            kept.insert(0, msg)
            remaining_budget -= msg_tokens
        else:
            break

    _result = kept + recent


# ─────────────────────────────────────────────────────────────
# Scenario 6: Agent transfer chain (A → B → C)
# ─────────────────────────────────────────────────────────────


async def scenario6():
    session_service = InMemorySessionService()

    agent_c = Agent(
        name="agent_c",
        model="mock",
        instruction="You are agent C.",
        description="Final handler",
    )
    agent_b = Agent(
        name="agent_b",
        model="mock",
        instruction="You are agent B.",
        description="Intermediate handler",
        sub_agents=[agent_c],
    )
    agent_a = Agent(
        name="agent_a",
        model="mock",
        instruction="You are agent A, the coordinator.",
        sub_agents=[agent_b],
    )

    set_mock_responses([
        fc_response("transfer_to_agent", {"agent_name": "agent_b"}),
        fc_response("transfer_to_agent", {"agent_name": "agent_c"}),
        text_response("Final response from C after chain A→B→C"),
    ])

    runner = Runner(
        app_name="bench6", agent=agent_a, session_service=session_service
    )
    session = await session_service.create_session(
        app_name="bench6", user_id="user1"
    )

    content = types.Content(
        role="user", parts=[types.Part(text="Start the chain")]
    )
    async for _ in runner.run_async(
        user_id="user1", session_id=session.id, new_message=content
    ):
        pass


# ─────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("=== ADK Python Real Benchmarks ===\n")

    all_results = [
        run_benchmark("scenario1_single_agent_3tools_10turn", scenario1),
        run_benchmark("scenario2_sequential_pipeline", scenario2),
        run_benchmark("scenario3_parallel_fanout", scenario3),
        run_benchmark("scenario4_100_concurrent_sessions", scenario4),
        run_benchmark("scenario5_context_compression", scenario5),
        run_benchmark("scenario6_transfer_chain", scenario6),
    ]

    with open("python_results.json", "w") as f:
        json.dump(all_results, f, indent=2)

    print("Results written to python_results.json")
