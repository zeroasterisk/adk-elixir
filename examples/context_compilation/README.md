# Context Compilation Example

Demonstrates ADK Elixir's **context compilation** — the process of transforming
a declarative agent definition into a concrete LLM request.

This example does **not** call any LLM API. It shows what the framework *would*
send to the model, making the compilation process visible.

## What It Shows

1. **Single agent** — instruction + identity + tools → compiled request
2. **Multi-agent** — automatic transfer tool generation and routing instructions
3. **Dynamic instructions** — runtime instruction providers (functions, MFA)
4. **State variables** — `{key}` template substitution from session state
5. **Output schema** — JSON schema constraint injection

## Run

```bash
cd examples/context_compilation
mix deps.get
mix run -e "ContextCompilation.demo()"
```

## Test

```bash
mix test
```

## Learn More

See the [Context Compilation guide](../../guides/context-compilation.md) for
a full explanation of how ADK Elixir compiles agent definitions.
