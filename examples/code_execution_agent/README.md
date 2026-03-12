# Code Execution Agent

An ADK Elixir example that demonstrates a **data analysis agent** capable of writing and executing Elixir code — a port of the Python ADK `code_execution/agent.py` sample.

## How It Works

In the Python ADK, this sample uses `BuiltInCodeExecutor` to run Python code. In Elixir, we implement equivalent functionality using:

- **`Code.eval_string/3`** — Elixir's built-in code evaluator
- **`Agent` process** — maintains variable bindings between tool calls so the LLM can build on previous computations (like a notebook)

The agent can:
- Perform calculations and data analysis
- Define variables that persist across tool calls
- Use the full Elixir standard library (Enum, Map, String, :math, etc.)

## ⚠️ Safety Warning

This example executes **arbitrary Elixir code** via `Code.eval_string/3`. This is powerful but dangerous:

- **Never expose this to untrusted input** in production
- Code runs with the full privileges of the BEAM VM
- There is no sandboxing — file system, network, and process access are all available
- This is intended for **local development and demos only**

For production use, consider:
- Running code in a sandboxed container
- Using a restricted evaluator
- Implementing an allowlist of permitted modules/functions

## Usage

```elixir
# Start IEx
iex -S mix

# One-shot query
CodeExecutionAgent.chat("Calculate the standard deviation of [2, 4, 4, 4, 5, 5, 7, 9]")

# Interactive session
CodeExecutionAgent.interactive()
```

## Configuration

Set `ADK_MODEL` to override the default model:

```bash
ADK_MODEL=gemini-flash-latest iex -S mix
```

## Files

| File | Purpose |
|------|---------|
| `lib/code_execution_agent.ex` | Agent definition, chat/interactive functions |
| `lib/code_execution_agent/executor.ex` | Stateful code executor + FunctionTool |
| `test/code_execution_agent_test.exs` | Unit tests for agent and executor |

## Running Tests

```bash
mix test
```
