# Agent Guidelines for ADK for Elixir

## Core Rules

### Avoid Deep Positional Arguments
Max 3 positional arguments. Use a keyword list (`opts \\ []`) for options.
*Example:* `def do_exec(command, timeout, opts \\ [])`

### Pattern Match > Conditional Logic
Prefer pattern matching in function heads over `if/else` or `case` in function bodies.
*Example:*
```elixir
# Good
def handle(%{type: "text"}), do: :ok
def handle(_), do: :error

# Bad
def handle(msg) do
  if msg.type == "text", do: :ok, else: :error
end
```

### Pipes and Pipelines
- Start with a raw value or variable, not a function call.
- Avoid single-step pipelines.
*Example:* `user |> calculate_score() |> save()`

### Error Handling
- Return `{:ok, result}` or `{:error, reason}`.
- Use `with` to chain operations that can fail.
- Avoid exceptions for control flow.

### Data Structures
- Use structs for known shapes, maps for dynamic data.
- Prepend to lists: `[new | list]`, not `list ++ [new]`.
- Prefer keyword lists for options.

## General Guidelines
- **Function Design**: Use guard clauses. Predicate names end in `?` (e.g., `valid?`).
- **Aliases**: Prefer `alias` over `import`.
- **Testing**: Tag tests; use line numbers (e.g., `mix test path:123`).
- **GenServer**: Keep state simple; use `handle_continue` for post-init.
- **Async**: Use `Task.Supervisor` and `Task.async_stream` for concurrency.

<!-- usage-rules-start -->
<!-- usage-rules-header -->
# Usage Rules

**IMPORTANT**: Consult these usage rules early and often when working with the packages listed below.
Before attempting to use any of these packages or to discover if you should use them, review their
usage rules to understand the correct patterns, conventions, and best practices.
<!-- usage-rules-header-end -->

<!-- usage_rules-start -->
## usage_rules usage
_A dev tool for Elixir projects to gather LLM usage rules from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
