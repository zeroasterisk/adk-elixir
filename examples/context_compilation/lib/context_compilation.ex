defmodule ContextCompilation do
  @moduledoc """
  Demonstrates ADK Elixir's context compilation — the process of transforming
  a declarative agent definition into a concrete LLM request.

  Run with: `mix run -e "ContextCompilation.demo()"`

  This does NOT call any LLM API. It shows what *would* be sent.
  """

  @doc """
  Run the full demo: single agent, multi-agent, and dynamic instructions.
  """
  def demo do
    IO.puts("""
    ╔══════════════════════════════════════════════════════════╗
    ║           ADK Elixir — Context Compilation Demo         ║
    ╚══════════════════════════════════════════════════════════╝
    """)

    demo_single_agent()
    demo_multi_agent()
    demo_dynamic_instructions()
    demo_with_state_variables()
    demo_with_output_schema()
  end

  @doc """
  Demo 1: Single agent with tools — shows basic compilation.
  """
  def demo_single_agent do
    header("1. Single Agent with Tools")

    agent = ADK.Agent.LlmAgent.new(
      name: "weather_bot",
      model: "gemini-2.0-flash",
      description: "Helps users check the weather",
      instruction: "You are a helpful weather assistant. Be concise.",
      tools: [ContextCompilation.Tools.get_weather()]
    )

    ctx = build_context(agent)
    show_compilation(agent, ctx)
  end

  @doc """
  Demo 2: Router agent with sub-agents — shows transfer compilation.
  """
  def demo_multi_agent do
    header("2. Multi-Agent with Transfer")

    weather_agent = ADK.Agent.LlmAgent.new(
      name: "weather",
      model: "gemini-2.0-flash",
      description: "Handles weather-related questions",
      instruction: "You handle weather queries. Use the get_weather tool."
    )

    news_agent = ADK.Agent.LlmAgent.new(
      name: "news",
      model: "gemini-2.0-flash",
      description: "Handles news and current events",
      instruction: "You handle news queries. Use the get_news tool."
    )

    router = ADK.Agent.LlmAgent.new(
      name: "router",
      model: "gemini-2.0-flash",
      instruction: "Route user requests to the appropriate specialist agent.",
      sub_agents: [weather_agent, news_agent]
    )

    ctx = build_context(router)
    show_compilation(router, ctx)
  end

  @doc """
  Demo 3: Dynamic instruction provider.
  """
  def demo_dynamic_instructions do
    header("3. Dynamic Instruction Provider")

    agent = ADK.Agent.LlmAgent.new(
      name: "time_aware_bot",
      model: "gemini-2.0-flash",
      instruction: fn _ctx ->
        now = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
        "You are a helpful assistant. Current time: #{now}. Adjust your greeting based on the time of day."
      end
    )

    ctx = build_context(agent)
    show_compilation(agent, ctx)
  end

  @doc """
  Demo 4: State variable substitution.
  """
  def demo_with_state_variables do
    header("4. State Variable Substitution")

    agent = ADK.Agent.LlmAgent.new(
      name: "personalized_bot",
      model: "gemini-2.0-flash",
      instruction: "You are helping {user_name} who lives in {location}. They prefer {language} responses."
    )

    # Show with and without state
    ctx_empty = build_context(agent)

    IO.puts("  Without state (variables left as-is):")
    instruction = ADK.InstructionCompiler.compile(agent, ctx_empty)
    IO.puts("  #{inspect(instruction)}\n")

    # Simulate state by showing substitution directly
    state = %{"user_name" => "Alice", "location" => "Tokyo", "language" => "Japanese"}
    instruction_with_state = ADK.InstructionCompiler.substitute_vars(
      "You are helping {user_name} who lives in {location}. They prefer {language} responses.",
      state
    )
    IO.puts("  With state #{inspect(state)}:")
    IO.puts("  #{inspect(instruction_with_state)}\n")
  end

  @doc """
  Demo 5: Output schema compilation.
  """
  def demo_with_output_schema do
    header("5. Output Schema")

    agent = ADK.Agent.LlmAgent.new(
      name: "structured_bot",
      model: "gemini-2.0-flash",
      instruction: "Extract structured data from the user's message.",
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "city" => %{"type" => "string"},
          "temperature" => %{"type" => "number"},
          "unit" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
        },
        "required" => ["city", "temperature", "unit"]
      }
    )

    ctx = build_context(agent)
    show_compilation(agent, ctx)
  end

  # --- Helpers ---

  defp header(title) do
    IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    IO.puts("  #{title}")
    IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
  end

  defp build_context(agent) do
    %ADK.Context{
      invocation_id: "demo-#{:rand.uniform(9999)}",
      agent: agent,
      user_content: %{text: "What's the weather in Tokyo?"}
    }
  end

  defp show_compilation(agent, ctx) do
    # 1. Show the compiled system instruction
    instruction = ADK.InstructionCompiler.compile(agent, ctx)

    IO.puts("  📋 Compiled System Instruction:")
    IO.puts("  ┌─────────────────────────────────────────────")
    for line <- String.split(instruction, "\n") do
      IO.puts("  │ #{line}")
    end
    IO.puts("  └─────────────────────────────────────────────\n")

    # 2. Show the effective tools
    tools = ADK.Agent.LlmAgent.effective_tools(agent)
    IO.puts("  🔧 Tools (#{length(tools)}):")
    for tool <- tools do
      decl = ADK.Tool.declaration(tool)
      IO.puts("    - #{decl.name}: #{decl.description || "(no description)"}")

      if decl[:parameters] do
        IO.puts("      params: #{inspect(decl.parameters)}")
      end
    end
    IO.puts("")

    # 3. Show the full request structure
    IO.puts("  📦 Full Request Map:")
    request = %{
      model: agent.model,
      instruction: instruction,
      messages: [%{role: :user, parts: [%{text: "What's the weather in Tokyo?"}]}],
      tools: Enum.map(tools, &ADK.Tool.declaration/1),
      generate_config: agent.generate_config
    }
    IO.puts("  #{inspect(request, pretty: true, width: 80)}\n\n")
  end
end
