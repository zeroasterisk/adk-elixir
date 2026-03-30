if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule ADK.Phoenix.ControlLive do
    @moduledoc """
    Phoenix LiveView dashboard for observing ADK agent system state in real-time.

    Displays five panels:

    1. **Active Sessions** — current sessions with agent name, user_id, message count, last activity
    2. **Recent Agent Runs** — Runner.run invocations with timing, agent, status
    3. **Tool Call Log** — tool invocations with tool name, duration, success/failure
    4. **LLM Metrics** — LLM calls with model, latency, token counts
    5. **System Health** — BEAM metrics: process count, memory usage, scheduler utilization

    Subscribes to `ADK.Phoenix.ControlLive.Store` via PubSub for real-time telemetry
    updates and uses `:timer.send_interval/2` for periodic BEAM metrics refresh.

    ## Usage

        # In a Phoenix router
        live "/control", ADK.Phoenix.ControlLive

        # Or mount directly
        <.live_component module={ADK.Phoenix.ControlLive} id="control" />

    ## Styling

    All elements use `.adk-ctrl-*` CSS classes with inline styles for zero-config
    rendering. No Tailwind dependency required.
    """

    use Phoenix.LiveView
    import Phoenix.Component

    alias ADK.Phoenix.ControlLive.Store

    @beam_refresh_ms 5_000

    # ── Mount ───────────────────────────────────────────────────────────

    @impl true
    def mount(_params, _session, socket) do
      if connected?(socket) do
        # Subscribe to store updates
        if pubsub_available?() do
          Phoenix.PubSub.subscribe(pubsub_server(), Store.topic())
        end

        # Schedule periodic BEAM metrics refresh
        :timer.send_interval(@beam_refresh_ms, self(), :refresh_beam)
      end

      state =
        if store_running?() do
          Store.get_state()
        else
          %{sessions: [], runs: [], tools: [], llm: [], errors: []}
        end

      socket =
        socket
        |> assign(:sessions, state.sessions)
        |> assign(:runs, state.runs)
        |> assign(:tools, state.tools)
        |> assign(:llm, state.llm)
        |> assign(:errors, state.errors)
        |> assign(:beam, collect_beam_metrics())
        |> assign(:page_title, "ADK Control Plane")

      {:ok, socket}
    end

    # ── Event Handlers ──────────────────────────────────────────────────

    @impl true
    def handle_info({:control_plane_update, state}, socket) do
      socket =
        socket
        |> assign(:sessions, state.sessions)
        |> assign(:runs, state.runs)
        |> assign(:tools, state.tools)
        |> assign(:llm, state.llm)
        |> assign(:errors, state.errors)

      {:noreply, socket}
    end

    def handle_info(:refresh_beam, socket) do
      {:noreply, assign(socket, :beam, collect_beam_metrics())}
    end

    def handle_info(_msg, socket), do: {:noreply, socket}

    # ── Render ──────────────────────────────────────────────────────────

    @impl true
    def render(assigns) do
      ~H"""
      <div class="adk-ctrl-root" style={root_style()}>
        <div class="adk-ctrl-grid" style={grid_style()}>
          <.beam_health beam={@beam} />
          <.sessions_panel sessions={@sessions} />
          <.runs_panel runs={@runs} />
          <.tools_panel tools={@tools} />
          <.llm_panel llm={@llm} />
          <.errors_panel errors={@errors} />
        </div>
      </div>
      """
    end

    # ── Function Components ─────────────────────────────────────────────

    attr(:beam, :map, required: true)

    defp beam_health(assigns) do
      ~H"""
      <div class="adk-ctrl-panel" style={panel_style()} data-section="health">
        <h3 style={heading_style()}>⚡ System Health</h3>
        <div style={metrics_grid_style()}>
          <.metric_card label="Processes" value={@beam.process_count} />
          <.metric_card label="Memory" value={@beam.memory_human} />
          <.metric_card label="Atoms" value={@beam.atom_count} />
          <.metric_card label="Ports" value={@beam.port_count} />
          <.metric_card label="Schedulers" value={"#{@beam.schedulers_online}/#{@beam.schedulers}"} />
          <.metric_card label="Uptime" value={@beam.uptime_human} />
        </div>
        <div style="margin-top:12px;">
          <table style={table_style()}>
            <thead>
              <tr>
                <th style={th_style()}>Memory Area</th>
                <th style={th_style_right()}>Usage</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{area, bytes} <- @beam.memory_detail}>
                <td style={td_style()}><%= area %></td>
                <td style={td_style_right()}><%= format_bytes(bytes) %></td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
      """
    end

    attr(:label, :string, required: true)
    attr(:value, :any, required: true)

    defp metric_card(assigns) do
      ~H"""
      <div style={card_style()}>
        <div style="font-size:0.7rem;color:#94a3b8;text-transform:uppercase;letter-spacing:0.05em;"><%= @label %></div>
        <div style="font-size:1.2rem;font-weight:700;color:#e2e8f0;margin-top:4px;"><%= @value %></div>
      </div>
      """
    end

    attr(:sessions, :list, required: true)

    defp sessions_panel(assigns) do
      ~H"""
      <div class="adk-ctrl-panel" style={panel_style()} data-section="sessions">
        <h3 style={heading_style()}>📡 Active Sessions <span style={badge_style()}><%= length(@sessions) %></span></h3>
        <%= if @sessions == [] do %>
          <p style={empty_style()}>No session events yet</p>
        <% else %>
          <table style={table_style()}>
            <thead>
              <tr>
                <th style={th_style()}>Session</th>
                <th style={th_style()}>User</th>
                <th style={th_style()}>App</th>
                <th style={th_style()}>Phase</th>
                <th style={th_style_right()}>Time</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={s <- Enum.take(@sessions, 20)}>
                <td style={td_style()}><code style={code_style()}><%= truncate(s.session_id, 20) %></code></td>
                <td style={td_style()}><%= s[:user_id] || "—" %></td>
                <td style={td_style()}><%= s[:app_name] || "—" %></td>
                <td style={td_style()}><.phase_badge phase={s.phase} /></td>
                <td style={td_style_right()}><%= format_time(s.timestamp) %></td>
              </tr>
            </tbody>
          </table>
        <% end %>
      </div>
      """
    end

    attr(:runs, :list, required: true)

    defp runs_panel(assigns) do
      ~H"""
      <div class="adk-ctrl-panel" style={panel_style()} data-section="runs">
        <h3 style={heading_style()}>🏃 Recent Agent Runs <span style={badge_style()}><%= length(@runs) %></span></h3>
        <%= if @runs == [] do %>
          <p style={empty_style()}>No agent runs yet</p>
        <% else %>
          <table style={table_style()}>
            <thead>
              <tr>
                <th style={th_style()}>Agent</th>
                <th style={th_style()}>Phase</th>
                <th style={th_style()}>Status</th>
                <th style={th_style_right()}>Duration</th>
                <th style={th_style_right()}>Time</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={r <- Enum.take(@runs, 20)}>
                <td style={td_style()}><%= r.agent_name %></td>
                <td style={td_style()}><.phase_badge phase={r.phase} /></td>
                <td style={td_style()}><.status_badge status={r.status} /></td>
                <td style={td_style_right()}><%= format_us(r.duration) %></td>
                <td style={td_style_right()}><%= format_time(r.timestamp) %></td>
              </tr>
            </tbody>
          </table>
        <% end %>
      </div>
      """
    end

    attr(:tools, :list, required: true)

    defp tools_panel(assigns) do
      ~H"""
      <div class="adk-ctrl-panel" style={panel_style()} data-section="tools">
        <h3 style={heading_style()}>🔧 Tool Call Log <span style={badge_style()}><%= length(@tools) %></span></h3>
        <%= if @tools == [] do %>
          <p style={empty_style()}>No tool calls yet</p>
        <% else %>
          <table style={table_style()}>
            <thead>
              <tr>
                <th style={th_style()}>Tool</th>
                <th style={th_style()}>Agent</th>
                <th style={th_style()}>Status</th>
                <th style={th_style_right()}>Duration</th>
                <th style={th_style_right()}>Time</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={t <- Enum.take(@tools, 20)}>
                <td style={td_style()}><code style={code_style()}><%= t.tool_name %></code></td>
                <td style={td_style()}><%= t.agent_name %></td>
                <td style={td_style()}><.status_badge status={t.status} /></td>
                <td style={td_style_right()}><%= format_us(t.duration) %></td>
                <td style={td_style_right()}><%= format_time(t.timestamp) %></td>
              </tr>
            </tbody>
          </table>
        <% end %>
      </div>
      """
    end

    attr(:llm, :list, required: true)

    defp llm_panel(assigns) do
      ~H"""
      <div class="adk-ctrl-panel" style={panel_style()} data-section="llm">
        <h3 style={heading_style()}>🧠 LLM Metrics <span style={badge_style()}><%= length(@llm) %></span></h3>
        <%= if @llm == [] do %>
          <p style={empty_style()}>No LLM calls yet</p>
        <% else %>
          <table style={table_style()}>
            <thead>
              <tr>
                <th style={th_style()}>Model</th>
                <th style={th_style()}>Agent</th>
                <th style={th_style()}>Status</th>
                <th style={th_style_right()}>Latency</th>
                <th style={th_style_right()}>In</th>
                <th style={th_style_right()}>Out</th>
                <th style={th_style_right()}>Time</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={l <- Enum.take(@llm, 20)}>
                <td style={td_style()}><code style={code_style()}><%= l.model %></code></td>
                <td style={td_style()}><%= l.agent_name %></td>
                <td style={td_style()}><.status_badge status={l.status} /></td>
                <td style={td_style_right()}><%= format_us(l.duration) %></td>
                <td style={td_style_right()}><%= l[:input_tokens] || "—" %></td>
                <td style={td_style_right()}><%= l[:output_tokens] || "—" %></td>
                <td style={td_style_right()}><%= format_time(l.timestamp) %></td>
              </tr>
            </tbody>
          </table>
        <% end %>
      </div>
      """
    end

    attr(:errors, :list, required: true)

    defp errors_panel(assigns) do
      ~H"""
      <div class="adk-ctrl-panel" style={panel_style()} data-section="errors">
        <h3 style={heading_style()}>🚨 Recent Errors <span style={badge_style(:error)}><%= length(@errors) %></span></h3>
        <%= if @errors == [] do %>
          <p style={empty_style()}>No errors — looking good! ✅</p>
        <% else %>
          <table style={table_style()}>
            <thead>
              <tr>
                <th style={th_style()}>Category</th>
                <th style={th_style()}>Name</th>
                <th style={th_style()}>Agent</th>
                <th style={th_style_right()}>Time</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- Enum.take(@errors, 20)}>
                <td style={td_style()}><span style={error_cat_style()}><%= e[:category] || "unknown" %></span></td>
                <td style={td_style()}><%= e[:tool_name] || e[:model] || e[:agent_name] || "—" %></td>
                <td style={td_style()}><%= e[:agent_name] || "—" %></td>
                <td style={td_style_right()}><%= format_time(e.timestamp) %></td>
              </tr>
            </tbody>
          </table>
        <% end %>
      </div>
      """
    end

    # ── Shared Sub-Components ───────────────────────────────────────────

    attr(:phase, :atom, required: true)

    defp phase_badge(assigns) do
      color =
        case assigns.phase do
          :start -> "#3b82f6"
          :stop -> "#22c55e"
          :exception -> "#ef4444"
          _ -> "#94a3b8"
        end

      assigns = assign(assigns, :color, color)

      ~H"""
      <span style={"display:inline-block;padding:1px 6px;border-radius:3px;font-size:0.7rem;font-weight:600;background:#{@color}20;color:#{@color};"}><%= @phase %></span>
      """
    end

    attr(:status, :atom, required: true)

    defp status_badge(assigns) do
      {color, label} =
        case assigns.status do
          :ok -> {"#22c55e", "ok"}
          :error -> {"#ef4444", "err"}
          _ -> {"#94a3b8", "?"}
        end

      assigns = assign(assigns, color: color, label: label)

      ~H"""
      <span style={"display:inline-block;padding:1px 6px;border-radius:3px;font-size:0.7rem;font-weight:600;background:#{@color}20;color:#{@color};"}><%= @label %></span>
      """
    end

    # ── BEAM Metrics ────────────────────────────────────────────────────

    defp collect_beam_metrics do
      memory = :erlang.memory()
      total_mem = memory[:total] || 0

      %{
        process_count: :erlang.system_info(:process_count),
        memory_human: format_bytes(total_mem),
        memory_total: total_mem,
        atom_count: :erlang.system_info(:atom_count),
        port_count: :erlang.system_info(:port_count),
        schedulers: :erlang.system_info(:schedulers),
        schedulers_online: :erlang.system_info(:schedulers_online),
        uptime_human: format_uptime(),
        memory_detail: [
          {"Processes", memory[:processes] || 0},
          {"Binary", memory[:binary] || 0},
          {"ETS", memory[:ets] || 0},
          {"Atom", memory[:atom] || 0},
          {"Code", memory[:code] || 0},
          {"System", memory[:system] || 0}
        ]
      }
    end

    # ── Formatting Helpers ──────────────────────────────────────────────

    @doc false
    def format_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

    def format_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576,
      do: "#{Float.round(bytes / 1024, 1)} KB"

    def format_bytes(bytes) when is_integer(bytes) and bytes < 1_073_741_824,
      do: "#{Float.round(bytes / 1_048_576, 1)} MB"

    def format_bytes(bytes) when is_integer(bytes),
      do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

    def format_bytes(_), do: "—"

    defp format_us(nil), do: "—"
    defp format_us(us) when is_integer(us) and us < 1_000, do: "#{us}µs"

    defp format_us(us) when is_integer(us) and us < 1_000_000,
      do: "#{Float.round(us / 1_000, 1)}ms"

    defp format_us(us) when is_integer(us), do: "#{Float.round(us / 1_000_000, 2)}s"
    defp format_us(_), do: "—"

    defp format_time(%DateTime{} = dt) do
      Calendar.strftime(dt, "%H:%M:%S")
    end

    defp format_time(_), do: "—"

    defp format_uptime do
      {uptime_ms, _} = :erlang.statistics(:wall_clock)
      total_seconds = div(uptime_ms, 1000)
      hours = div(total_seconds, 3600)
      minutes = div(rem(total_seconds, 3600), 60)
      seconds = rem(total_seconds, 60)

      cond do
        hours > 0 -> "#{hours}h #{minutes}m"
        minutes > 0 -> "#{minutes}m #{seconds}s"
        true -> "#{seconds}s"
      end
    end

    defp truncate(nil, _), do: "—"

    defp truncate(str, max) when is_binary(str) do
      if String.length(str) > max do
        String.slice(str, 0, max) <> "…"
      else
        str
      end
    end

    defp truncate(other, max), do: truncate(to_string(other), max)

    # ── Style Helpers ───────────────────────────────────────────────────

    defp root_style do
      "padding:16px;background:#0f1117;min-height:100%;font-family:system-ui,-apple-system,sans-serif;color:#e2e8f0;"
    end

    defp grid_style do
      "display:grid;grid-template-columns:repeat(auto-fit,minmax(400px,1fr));gap:16px;"
    end

    defp panel_style do
      "background:#1a1d2e;border:1px solid #2d3148;border-radius:8px;padding:16px;overflow:hidden;"
    end

    defp heading_style do
      "font-size:0.9rem;font-weight:600;color:#7c83fd;margin:0 0 12px 0;display:flex;align-items:center;gap:8px;"
    end

    defp badge_style(type \\ :default) do
      bg = if type == :error, do: "#ef444420", else: "#2d3148"
      color = if type == :error, do: "#ef4444", else: "#94a3b8"

      "background:#{bg};color:#{color};border-radius:10px;padding:1px 8px;font-size:0.7rem;font-weight:500;"
    end

    defp metrics_grid_style do
      "display:grid;grid-template-columns:repeat(3,1fr);gap:8px;"
    end

    defp card_style do
      "background:#0f1117;border:1px solid #2d3148;border-radius:6px;padding:10px 12px;"
    end

    defp table_style do
      "width:100%;border-collapse:collapse;font-size:0.8rem;"
    end

    defp th_style do
      "text-align:left;padding:6px 8px;border-bottom:1px solid #2d3148;color:#94a3b8;font-weight:500;font-size:0.7rem;text-transform:uppercase;letter-spacing:0.05em;"
    end

    defp th_style_right do
      th_style() <> "text-align:right;"
    end

    defp td_style do
      "padding:6px 8px;border-bottom:1px solid #1e2235;color:#e2e8f0;"
    end

    defp td_style_right do
      td_style() <> "text-align:right;"
    end

    defp code_style do
      "background:#0f1117;padding:1px 4px;border-radius:3px;font-family:monospace;font-size:0.75rem;"
    end

    defp empty_style do
      "color:#64748b;font-size:0.85rem;font-style:italic;padding:12px 0;"
    end

    defp error_cat_style do
      "background:#ef444420;color:#ef4444;padding:1px 6px;border-radius:3px;font-size:0.7rem;font-weight:600;"
    end

    # ── Private Helpers ─────────────────────────────────────────────────

    defp pubsub_available? do
      Code.ensure_loaded?(Phoenix.PubSub)
    end

    defp pubsub_server do
      Application.get_env(:adk, :pubsub, ADK.PubSub)
    end

    defp store_running? do
      Process.whereis(ADK.Phoenix.ControlLive.Store) != nil
    end
  end
end
