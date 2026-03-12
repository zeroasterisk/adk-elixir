# Tool Use Example

A single agent with **multiple tools** demonstrating function calling in ADK Elixir.

## Tools

| Tool | Description |
|------|-------------|
| `calculator` | Evaluate math expressions (`2 + 3 * 4`, `2 ** 10`) |
| `string_utils` | Word count, reverse, uppercase, length |
| `current_time` | Current date/time with timezone offset |

## What This Demonstrates

- Defining multiple `ADK.Tool.FunctionTool`s with JSON Schema parameters
- Pattern matching in tool implementations (idiomatic Elixir)
- The LLM selecting the appropriate tool based on the user's question
- Safe expression evaluation

## Setup

```bash
cd examples/tool_use
mix deps.get
```

Set your API key:

```bash
export GOOGLE_API_KEY=your-key-here
# or
export ADK_MODEL=gemini-flash-latest
```

## Usage

```elixir
# Start an interactive session
iex -S mix

# Ask math questions
ToolUse.chat("What is 2 to the power of 16?")

# String operations
ToolUse.chat("How many words are in 'to be or not to be'?")
ToolUse.chat("Reverse the string 'Elixir is fun'")

# Time queries
ToolUse.chat("What time is it in Tokyo right now?")

# The agent picks the right tool automatically
ToolUse.chat("What's 365 * 24 and also tell me the current UTC time")
```

## Project Structure

```
tool_use/
├── lib/
│   ├── tool_use.ex          # Agent definition and chat interface
│   └── tool_use/
│       └── tools.ex          # Tool definitions (calculator, string, time)
├── mix.exs
└── README.md
```
