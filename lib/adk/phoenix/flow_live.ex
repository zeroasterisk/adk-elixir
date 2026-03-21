if Code.ensure_loaded?(Phoenix.Component) do
  defmodule ADK.Phoenix.FlowLive do
    @moduledoc """
    Read-only Phoenix LiveView component for visualizing agent graphs.

    Renders agent trees (Sequential, Parallel, Loop, nested agents) as a visual
    flow diagram using CSS-only layout (flexbox). Each agent type gets distinct
    visual styling, and an optional `active_agent` assign highlights the currently
    executing agent in real time.

    ## Usage

        # In a LiveView template
        <ADK.Phoenix.FlowLive.flow_graph agent={@agent} />

        # With active agent highlighting
        <ADK.Phoenix.FlowLive.flow_graph agent={@agent} active_agent="researcher" />

    ## Agent Types

    - **LlmAgent** — Blue node with model and tool count
    - **SequentialAgent** — Purple container, vertical stack with arrows
    - **ParallelAgent** — Teal container, horizontal row with fork/join
    - **LoopAgent** — Amber container, vertical stack with cycle indicator
    - **Custom** — Gray node

    ## Styling

    All elements use `.adk-flow-*` CSS classes with inline styles for zero-config
    rendering. Override with your own CSS targeting the class names.
    """

    use Phoenix.Component

    # ── Public API ──────────────────────────────────────────────────────

    @doc """
    Renders a complete agent flow graph.

    ## Assigns

    - `agent` (required) — The root agent struct
    - `active_agent` (optional) — Name of the currently active agent (string)
    """
    attr :agent, :any, required: true
    attr :active_agent, :string, default: nil

    def flow_graph(assigns) do
      ~H"""
      <div class="adk-flow-root" style={root_style()}>
        <.agent_node agent={@agent} active_agent={@active_agent} depth={0} />
      </div>
      """
    end

    # ── Agent Node Dispatch ─────────────────────────────────────────────

    attr :agent, :any, required: true
    attr :active_agent, :string, default: nil
    attr :depth, :integer, default: 0

    def agent_node(assigns) do
      ~H"""
      <%= case agent_type(@agent) do %>
        <% :sequential -> %>
          <.sequential_node agent={@agent} active_agent={@active_agent} depth={@depth} />
        <% :parallel -> %>
          <.parallel_node agent={@agent} active_agent={@active_agent} depth={@depth} />
        <% :loop -> %>
          <.loop_node agent={@agent} active_agent={@active_agent} depth={@depth} />
        <% _leaf -> %>
          <.leaf_node agent={@agent} active_agent={@active_agent} depth={@depth} />
      <% end %>
      """
    end

    # ── Leaf Node (LlmAgent, Custom, etc.) ──────────────────────────────

    defp leaf_node(assigns) do
      type = agent_type(assigns.agent)
      name = agent_name(assigns.agent)
      active = assigns.active_agent == name

      assigns =
        assigns
        |> assign(:type, type)
        |> assign(:name, name)
        |> assign(:active, active)
        |> assign(:model, agent_model(assigns.agent))
        |> assign(:tool_count, agent_tool_count(assigns.agent))
        |> assign(:description, safe_description(assigns.agent))

      ~H"""
      <div class={"adk-flow-node adk-flow-#{@type}"} style={node_style(@type, @active)} data-agent-name={@name}>
        <div class="adk-flow-node-header" style={node_header_style(@type)}>
          <span class="adk-flow-badge" style={badge_style(@type)}><%= type_label(@type) %></span>
          <span class="adk-flow-name" style={name_style()}><%= @name %></span>
        </div>
        <div class="adk-flow-node-body" style={node_body_style()}>
          <%= if @model do %>
            <div class="adk-flow-meta" style={meta_style()}>
              <span style={meta_icon_style()}>🧠</span> <%= @model %>
            </div>
          <% end %>
          <%= if @tool_count > 0 do %>
            <div class="adk-flow-meta" style={meta_style()}>
              <span style={meta_icon_style()}>🔧</span> <%= @tool_count %> tool<%= if @tool_count > 1, do: "s" %>
            </div>
          <% end %>
          <%= if @description && @description != "" do %>
            <div class="adk-flow-desc" style={desc_style()}><%= @description %></div>
          <% end %>
        </div>
        <%= if @active do %>
          <div class="adk-flow-active-indicator" style={active_indicator_style()}>● active</div>
        <% end %>
      </div>
      """
    end

    # ── Sequential Container ────────────────────────────────────────────

    defp sequential_node(assigns) do
      name = agent_name(assigns.agent)
      active = assigns.active_agent == name
      children = safe_sub_agents(assigns.agent)

      assigns =
        assigns
        |> assign(:name, name)
        |> assign(:active, active)
        |> assign(:children, children)

      ~H"""
      <div class="adk-flow-container adk-flow-sequential" style={container_style(:sequential, @active)} data-agent-name={@name}>
        <div class="adk-flow-container-header" style={container_header_style(:sequential)}>
          <span class="adk-flow-badge" style={badge_style(:sequential)}><%= type_label(:sequential) %></span>
          <span class="adk-flow-name" style={name_style()}><%= @name %></span>
          <%= if @active do %>
            <span class="adk-flow-active-indicator" style={active_indicator_inline_style()}>● active</span>
          <% end %>
        </div>
        <div class="adk-flow-sequential-children" style={sequential_children_style()}>
          <%= for {child, idx} <- Enum.with_index(@children) do %>
            <%= if idx > 0 do %>
              <div class="adk-flow-arrow" style={arrow_style()}>▼</div>
            <% end %>
            <.agent_node agent={child} active_agent={@active_agent} depth={@depth + 1} />
          <% end %>
        </div>
      </div>
      """
    end

    # ── Parallel Container ──────────────────────────────────────────────

    defp parallel_node(assigns) do
      name = agent_name(assigns.agent)
      active = assigns.active_agent == name
      children = safe_sub_agents(assigns.agent)

      assigns =
        assigns
        |> assign(:name, name)
        |> assign(:active, active)
        |> assign(:children, children)

      ~H"""
      <div class="adk-flow-container adk-flow-parallel" style={container_style(:parallel, @active)} data-agent-name={@name}>
        <div class="adk-flow-container-header" style={container_header_style(:parallel)}>
          <span class="adk-flow-badge" style={badge_style(:parallel)}><%= type_label(:parallel) %></span>
          <span class="adk-flow-name" style={name_style()}><%= @name %></span>
          <%= if @active do %>
            <span class="adk-flow-active-indicator" style={active_indicator_inline_style()}>● active</span>
          <% end %>
        </div>
        <div class="adk-flow-fork" style={fork_join_style()}>⑂ fork</div>
        <div class="adk-flow-parallel-children" style={parallel_children_style()}>
          <%= for child <- @children do %>
            <.agent_node agent={child} active_agent={@active_agent} depth={@depth + 1} />
          <% end %>
        </div>
        <div class="adk-flow-join" style={fork_join_style()}>⑈ join</div>
      </div>
      """
    end

    # ── Loop Container ──────────────────────────────────────────────────

    defp loop_node(assigns) do
      name = agent_name(assigns.agent)
      active = assigns.active_agent == name
      children = safe_sub_agents(assigns.agent)
      max_iter = Map.get(assigns.agent, :max_iterations, nil)

      assigns =
        assigns
        |> assign(:name, name)
        |> assign(:active, active)
        |> assign(:children, children)
        |> assign(:max_iterations, max_iter)

      ~H"""
      <div class="adk-flow-container adk-flow-loop" style={container_style(:loop, @active)} data-agent-name={@name}>
        <div class="adk-flow-container-header" style={container_header_style(:loop)}>
          <span class="adk-flow-badge" style={badge_style(:loop)}><%= type_label(:loop) %></span>
          <span class="adk-flow-name" style={name_style()}><%= @name %></span>
          <%= if @max_iterations do %>
            <span class="adk-flow-iterations" style={iterations_style()}>max: <%= @max_iterations %></span>
          <% end %>
          <%= if @active do %>
            <span class="adk-flow-active-indicator" style={active_indicator_inline_style()}>● active</span>
          <% end %>
        </div>
        <div class="adk-flow-loop-body" style={loop_body_style()}>
          <div class="adk-flow-loop-children" style={sequential_children_style()}>
            <%= for {child, idx} <- Enum.with_index(@children) do %>
              <%= if idx > 0 do %>
                <div class="adk-flow-arrow" style={arrow_style()}>▼</div>
              <% end %>
              <.agent_node agent={child} active_agent={@active_agent} depth={@depth + 1} />
            <% end %>
          </div>
          <div class="adk-flow-loop-arrow" style={loop_arrow_style()}>↻</div>
        </div>
      </div>
      """
    end

    # ── Agent Introspection ─────────────────────────────────────────────

    @doc false
    def agent_type(agent) do
      case agent do
        %ADK.Agent.SequentialAgent{} -> :sequential
        %ADK.Agent.ParallelAgent{} -> :parallel
        %ADK.Agent.LoopAgent{} -> :loop
        %ADK.Agent.LlmAgent{} -> :llm
        %ADK.Agent.Custom{} -> :custom
        agent when is_struct(agent) and agent.__struct__ == ADK.Agent.RemoteA2aAgent -> :remote
        _ -> :unknown
      end
    end

    @doc false
    def agent_name(agent) do
      case agent do
        %{name: name} when is_binary(name) -> name
        _ -> "unnamed"
      end
    end

    defp agent_model(agent) do
      case agent do
        %{model: model} when is_binary(model) -> model
        _ -> nil
      end
    end

    defp agent_tool_count(agent) do
      case agent do
        %{tools: tools} when is_list(tools) -> length(tools)
        _ -> 0
      end
    end

    defp safe_description(agent) do
      case agent do
        %{description: desc} when is_binary(desc) -> desc
        _ -> nil
      end
    end

    defp safe_sub_agents(agent) do
      case agent do
        %{sub_agents: agents} when is_list(agents) -> agents
        _ -> []
      end
    end

    # ── Type Labels ─────────────────────────────────────────────────────

    defp type_label(:llm), do: "LLM"
    defp type_label(:sequential), do: "Sequential"
    defp type_label(:parallel), do: "Parallel"
    defp type_label(:loop), do: "Loop"
    defp type_label(:custom), do: "Custom"
    defp type_label(:remote), do: "Remote"
    defp type_label(_), do: "Agent"

    # ── Inline Styles ───────────────────────────────────────────────────
    # All styles are inline for zero-dependency rendering.
    # Users can override via .adk-flow-* CSS classes.

    defp root_style do
      "padding: 24px; font-family: system-ui, -apple-system, sans-serif; color: #e2e8f0; background: #0f1117; min-height: 100px;"
    end

    defp node_style(type, active) do
      border_color = if active, do: "#22c55e", else: type_border_color(type)
      shadow = if active, do: "0 0 12px rgba(34, 197, 94, 0.4)", else: "0 2px 8px rgba(0,0,0,0.3)"

      "border: 2px solid #{border_color}; border-radius: 10px; background: #1a1d2e; " <>
        "padding: 0; min-width: 180px; max-width: 280px; box-shadow: #{shadow}; " <>
        "transition: box-shadow 0.3s, border-color 0.3s;"
    end

    defp container_style(type, active) do
      border_color = if active, do: "#22c55e", else: type_border_color(type)
      bg = type_bg_color(type)
      shadow = if active, do: "0 0 12px rgba(34, 197, 94, 0.4)", else: "0 2px 8px rgba(0,0,0,0.2)"

      "border: 2px solid #{border_color}; border-radius: 12px; background: #{bg}; " <>
        "padding: 0; min-width: 200px; box-shadow: #{shadow}; " <>
        "transition: box-shadow 0.3s, border-color 0.3s;"
    end

    defp node_header_style(type) do
      bg = type_header_bg(type)
      "padding: 8px 12px; border-bottom: 1px solid rgba(255,255,255,0.1); " <>
        "background: #{bg}; border-radius: 8px 8px 0 0; display: flex; align-items: center; gap: 8px;"
    end

    defp container_header_style(type) do
      bg = type_header_bg(type)
      "padding: 10px 14px; border-bottom: 1px solid rgba(255,255,255,0.1); " <>
        "background: #{bg}; border-radius: 10px 10px 0 0; display: flex; align-items: center; gap: 8px; flex-wrap: wrap;"
    end

    defp node_body_style do
      "padding: 10px 12px;"
    end

    defp badge_style(type) do
      bg = type_badge_bg(type)
      "background: #{bg}; color: white; font-size: 0.65rem; font-weight: 700; " <>
        "padding: 2px 7px; border-radius: 4px; text-transform: uppercase; letter-spacing: 0.05em;"
    end

    defp name_style do
      "font-weight: 600; font-size: 0.9rem; color: #f1f5f9;"
    end

    defp meta_style do
      "font-size: 0.78rem; color: #94a3b8; display: flex; align-items: center; gap: 4px; margin-top: 4px;"
    end

    defp meta_icon_style do
      "font-size: 0.85rem;"
    end

    defp desc_style do
      "font-size: 0.75rem; color: #64748b; margin-top: 6px; font-style: italic;"
    end

    defp sequential_children_style do
      "display: flex; flex-direction: column; align-items: center; gap: 0; padding: 16px;"
    end

    defp parallel_children_style do
      "display: flex; flex-direction: row; align-items: flex-start; gap: 16px; " <>
        "padding: 16px; flex-wrap: wrap; justify-content: center;"
    end

    defp arrow_style do
      "color: #475569; font-size: 1.2rem; text-align: center; padding: 4px 0; line-height: 1;"
    end

    defp fork_join_style do
      "text-align: center; color: #5eead4; font-size: 0.75rem; font-weight: 600; " <>
        "padding: 6px 0; letter-spacing: 0.05em; text-transform: uppercase;"
    end

    defp loop_body_style do
      "display: flex; align-items: center; gap: 8px; padding: 0 8px 12px 0;"
    end

    defp loop_arrow_style do
      "font-size: 2rem; color: #fbbf24; flex-shrink: 0; padding: 0 8px; " <>
        "align-self: center;"
    end

    defp iterations_style do
      "font-size: 0.7rem; color: #fbbf24; background: rgba(251,191,36,0.15); " <>
        "padding: 2px 6px; border-radius: 4px;"
    end

    defp active_indicator_style do
      "font-size: 0.7rem; color: #22c55e; text-align: center; padding: 4px 0 6px; " <>
        "font-weight: 600; animation: adk-pulse 1.5s ease-in-out infinite;"
    end

    defp active_indicator_inline_style do
      "font-size: 0.7rem; color: #22c55e; font-weight: 600; margin-left: auto;"
    end

    # ── Color Schemes ───────────────────────────────────────────────────

    defp type_border_color(:llm), do: "#3b82f6"
    defp type_border_color(:sequential), do: "#8b5cf6"
    defp type_border_color(:parallel), do: "#14b8a6"
    defp type_border_color(:loop), do: "#f59e0b"
    defp type_border_color(:custom), do: "#6b7280"
    defp type_border_color(:remote), do: "#ec4899"
    defp type_border_color(_), do: "#475569"

    defp type_bg_color(:sequential), do: "rgba(139, 92, 246, 0.06)"
    defp type_bg_color(:parallel), do: "rgba(20, 184, 166, 0.06)"
    defp type_bg_color(:loop), do: "rgba(245, 158, 11, 0.06)"
    defp type_bg_color(_), do: "rgba(100, 116, 139, 0.06)"

    defp type_header_bg(:llm), do: "rgba(59, 130, 246, 0.15)"
    defp type_header_bg(:sequential), do: "rgba(139, 92, 246, 0.15)"
    defp type_header_bg(:parallel), do: "rgba(20, 184, 166, 0.15)"
    defp type_header_bg(:loop), do: "rgba(245, 158, 11, 0.15)"
    defp type_header_bg(:custom), do: "rgba(107, 114, 128, 0.15)"
    defp type_header_bg(:remote), do: "rgba(236, 72, 153, 0.15)"
    defp type_header_bg(_), do: "rgba(71, 85, 105, 0.15)"

    defp type_badge_bg(:llm), do: "#3b82f6"
    defp type_badge_bg(:sequential), do: "#8b5cf6"
    defp type_badge_bg(:parallel), do: "#14b8a6"
    defp type_badge_bg(:loop), do: "#f59e0b"
    defp type_badge_bg(:custom), do: "#6b7280"
    defp type_badge_bg(:remote), do: "#ec4899"
    defp type_badge_bg(_), do: "#475569"
  end
end
