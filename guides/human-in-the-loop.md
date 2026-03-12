# Human-in-the-Loop (HITL) in ADK Elixir

A practical guide to adding human approval gates to your agents — from CLI
prototypes to production LiveView dashboards.

## Why Human-in-the-Loop?

Agents are powerful, but some actions shouldn't happen without a human saying
"yes":

- **Destructive operations** — deleting files, dropping tables, revoking access
- **Financial actions** — processing refunds, placing orders, transferring funds
- **External API calls** — sending emails, posting to social media, calling paid APIs
- **Sensitive data access** — reading PII, accessing medical records, exporting data
- **Irreversible changes** — deploying to production, publishing content, modifying DNS

Without HITL, a prompt injection or model hallucination could trigger any of
these. HITL adds a human checkpoint: the agent proposes an action, a human
reviews it, and only then does it execute.

## ADK Elixir's HITL Architecture

ADK Elixir provides HITL as a first-class feature through three components:

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│  ADK.Policy     │     │  ADK.Policy.          │     │  ADK.Tool.      │
│  (behaviour)    │────▶│  HumanApproval        │────▶│  Approval       │
│                 │     │  (struct + impl)      │     │  (GenServer)    │
└─────────────────┘     └──────────────────────┘     └─────────────────┘
                                                            │
                                                     ┌──────┴──────┐
                                                     │             │
                                                  CLI mode    Server mode
                                                  (stdin)     (async)
                                                              │
                                                       ┌──────┴──────┐
                                                       │             │
                                                    LiveView    API/Webhook
```

- **`ADK.Policy`** — The behaviour that all policies implement. Checked before
  every tool call, input, and output.
- **`ADK.Policy.HumanApproval`** — A struct-based policy that intercepts
  sensitive tool calls and blocks until a human decides.
- **`ADK.Tool.Approval`** — A GenServer that manages pending approval requests,
  enabling async approval from any process (LiveView, API handler, CLI).

## Quick Start: CLI Mode

The fastest way to add HITL — blocks on stdin in your terminal:

```elixir
# Define an agent with a dangerous tool
agent = ADK.Agent.LlmAgent.new(
  name: "ops_agent",
  model: "gemini-flash-latest",
  instruction: "You help with system operations.",
  tools: [
    ADK.Tool.FunctionTool.new(
      name: "delete_file",
      description: "Delete a file from the filesystem",
      function: fn %{"path" => path}, _ctx ->
        File.rm!(path)
        "Deleted #{path}"
      end
    ),
    ADK.Tool.FunctionTool.new(
      name: "list_files",
      description: "List files in a directory",
      function: fn %{"dir" => dir}, _ctx ->
        File.ls!(dir) |> Enum.join(", ")
      end
    )
  ]
)

# Create HITL policy — only intercepts "delete_file"
policy = ADK.Policy.HumanApproval.new(
  sensitive_tools: ["delete_file"],
  mode: :cli
)

# Run with the policy
runner = ADK.Runner.new(app_name: "ops", agent: agent)
events = ADK.Runner.run(runner, "user1", "session1", "Delete /tmp/old.log",
  policies: [policy]
)
```

When the agent tries to call `delete_file`, you'll see:

```
┌─────────────────────────────────────────────────────┐
│  🔒 Human Approval Required                          │
  Tool: delete_file                                    │
  Args: %{"path" => "/tmp/old.log"}                    │
└─────────────────────────────────────────────────────┘

Allow this tool call? [y/N]:
```

Type `y` to allow, anything else to deny. If denied, the agent receives a
denial message and can respond to the user explaining why it couldn't proceed.

## Server Mode: Production HITL

CLI mode blocks on stdin — fine for development, useless in production. Server
mode delegates approval to the `ADK.Tool.Approval` GenServer, which can be
resolved from any process.

### Step 1: Start the Approval Server

Add it to your supervision tree:

```elixir
# In your Application or Supervisor
children = [
  {ADK.Tool.Approval, name: MyApp.Approvals},
  # ... other children
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Step 2: Create the Policy

```elixir
policy = ADK.Policy.HumanApproval.new(
  sensitive_tools: ["delete_file", "send_email", "process_refund"],
  mode: :server,
  server: MyApp.Approvals,
  timeout: 120_000  # 2 minutes to approve before auto-deny
)
```

### Step 3: Run the Agent

```elixir
runner = ADK.Runner.new(app_name: "myapp", agent: agent)

# This will BLOCK when a sensitive tool is called,
# waiting for external approval
events = ADK.Runner.run(runner, user_id, session_id, message,
  policies: [policy]
)
```

### Step 4: Approve from Another Process

```elixir
# List pending approvals
pending = ADK.Tool.Approval.list_pending(MyApp.Approvals)
# => [%{id: "approval-abc123", tool_name: "delete_file",
#       args: %{"path" => "/tmp/old.log"}, requested_at: ~U[...]}]

# Approve
ADK.Tool.Approval.approve(MyApp.Approvals, "approval-abc123")

# Or deny with a reason
ADK.Tool.Approval.deny(MyApp.Approvals, "approval-abc123", "Too risky")
```

The blocked `Runner.run/5` call unblocks and continues (or returns a denial
event to the agent).

## ADK.Policy.HumanApproval in Detail

`HumanApproval` is a **struct-based policy**, not just a module. This means
you can create multiple instances with different configurations:

```elixir
# Different policies for different risk levels
low_risk = ADK.Policy.HumanApproval.new(
  sensitive_tools: ["delete_file"],
  mode: :server,
  server: MyApp.Approvals,
  timeout: 60_000
)

high_risk = ADK.Policy.HumanApproval.new(
  sensitive_tools: ["process_payment", "modify_account"],
  mode: :server,
  server: MyApp.Approvals,
  timeout: 300_000  # 5 min for financial actions
)

# Apply both — first deny wins
events = ADK.Runner.run(runner, uid, sid, msg,
  policies: [low_risk, high_risk]
)
```

### Struct Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `sensitive_tools` | `[String.t()]` or `:all` | (required) | Tool names to intercept |
| `mode` | `:cli` or `:server` | `:cli` | Approval mechanism |
| `server` | atom or pid | `ADK.Tool.Approval` | GenServer name (server mode) |
| `timeout` | pos_integer | `60_000` | Milliseconds before auto-deny |
| `prompt_fn` | function or nil | `nil` | Custom prompt/notification function |

### The `:all` Option

To intercept every single tool call:

```elixir
paranoid = ADK.Policy.HumanApproval.new(
  sensitive_tools: :all,
  mode: :server,
  server: MyApp.Approvals
)
```

### Custom Prompt Functions

The `prompt_fn` option lets you customize what happens when approval is
requested. In CLI mode, it replaces the default stdin prompt. In server mode,
it runs in a spawned process for notifications:

```elixir
# CLI: Custom prompt with more context
policy = ADK.Policy.HumanApproval.new(
  sensitive_tools: ["delete_file"],
  mode: :cli,
  prompt_fn: fn %{tool_name: name, args: args} ->
    IO.puts("\n⚠️  Agent wants to run: #{name}")
    IO.puts("   Arguments: #{inspect(args)}")
    IO.puts("   This action is IRREVERSIBLE.\n")

    case IO.gets("Type 'DELETE' to confirm: ") |> String.trim() do
      "DELETE" -> :allow
      _ -> {:deny, "User did not type DELETE"}
    end
  end
)

# Server: Notify via external channel when approval is needed
policy = ADK.Policy.HumanApproval.new(
  sensitive_tools: ["process_refund"],
  mode: :server,
  server: MyApp.Approvals,
  prompt_fn: fn %{tool_name: name, args: args, request_id: id} ->
    # Send Slack notification, email, push notification, etc.
    MyApp.Notifications.send_approval_request(%{
      tool: name,
      args: args,
      approval_url: "https://myapp.com/approve/#{id}"
    })
  end
)
```

## ADK.Tool.Approval GenServer

The `Approval` GenServer is the coordination point for async approvals. It
manages a map of pending requests, each with a waiting process.

### Lifecycle of a Server-Mode Approval

```
1. Agent calls "delete_file"
2. HumanApproval.check/4 detects sensitive tool
3. Approval.register/3 creates request, stores waiter=nil
4. Approval.await/3 subscribes waiter PID, blocks with receive
5. (External) LiveView/API calls Approval.approve/2
6. GenServer sends {:approval_decision, id, :allow} to waiter
7. Waiter unblocks, tool executes
```

```elixir
# The internal flow (you don't call this directly):
{request_id, request} = ADK.Tool.Approval.register(server, "delete_file", %{"path" => "..."})
# => {"approval-xK9m...", %{id: "approval-xK9m...", tool_name: "delete_file", ...}}

# Waiter subscribes and blocks:
:ok = ADK.Tool.Approval.await(server, request_id, 60_000)
# This receive-blocks until approve/deny is called or timeout

# From another process:
ADK.Tool.Approval.approve(server, request_id)
# => :ok  (waiter unblocks with :allow)
```

### API Reference

```elixir
# Start the server
{:ok, pid} = ADK.Tool.Approval.start_link(name: MyApp.Approvals)

# Register a pending approval (called by HumanApproval policy)
{request_id, request} = ADK.Tool.Approval.register(server, tool_name, args)

# Block until decided (called by HumanApproval policy)
decision = ADK.Tool.Approval.await(server, request_id, timeout_ms)
# => :allow | {:deny, reason}

# External decision endpoints
ADK.Tool.Approval.approve(server, request_id)
# => :ok | {:error, :not_found}

ADK.Tool.Approval.deny(server, request_id, "reason")
# => :ok | {:error, :not_found}

# List all pending requests (for dashboards)
requests = ADK.Tool.Approval.list_pending(server)
# => [%{id: ..., tool_name: ..., args: ..., requested_at: ...}]
```

## Building a LiveView Approval Dashboard

Here's how to wire HITL into a Phoenix LiveView UI:

### The LiveView

```elixir
defmodule MyAppWeb.ApprovalsLive do
  use MyAppWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # Poll for pending approvals every second
    if connected?(socket), do: :timer.send_interval(1000, :refresh)

    {:ok, assign(socket, pending: list_pending())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, pending: list_pending())}
  end

  @impl true
  def handle_event("approve", %{"id" => request_id}, socket) do
    ADK.Tool.Approval.approve(MyApp.Approvals, request_id)
    {:noreply, assign(socket, pending: list_pending())}
  end

  @impl true
  def handle_event("deny", %{"id" => request_id}, socket) do
    ADK.Tool.Approval.deny(MyApp.Approvals, request_id, "Denied by operator")
    {:noreply, assign(socket, pending: list_pending())}
  end

  defp list_pending do
    ADK.Tool.Approval.list_pending(MyApp.Approvals)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-4">
      <h1 class="text-2xl font-bold mb-4">🔒 Pending Approvals</h1>

      <%= if @pending == [] do %>
        <p class="text-gray-500">No pending approvals.</p>
      <% else %>
        <div class="space-y-4">
          <%= for request <- @pending do %>
            <div class="border rounded-lg p-4 bg-yellow-50">
              <div class="flex justify-between items-start">
                <div>
                  <span class="font-mono font-bold text-lg">
                    <%= request.tool_name %>
                  </span>
                  <p class="text-sm text-gray-600 mt-1">
                    ID: <%= request.id %>
                  </p>
                  <pre class="mt-2 bg-gray-100 p-2 rounded text-sm">
                    <%= inspect(request.args, pretty: true) %>
                  </pre>
                  <p class="text-xs text-gray-400 mt-1">
                    Requested: <%= request.requested_at %>
                  </p>
                </div>
                <div class="flex gap-2">
                  <button
                    phx-click="approve"
                    phx-value-id={request.id}
                    class="px-4 py-2 bg-green-600 text-white rounded hover:bg-green-700"
                  >
                    ✅ Approve
                  </button>
                  <button
                    phx-click="deny"
                    phx-value-id={request.id}
                    class="px-4 py-2 bg-red-600 text-white rounded hover:bg-red-700"
                  >
                    ❌ Deny
                  </button>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
```

### Using PubSub for Real-Time Updates

Instead of polling, use Phoenix PubSub for instant updates:

```elixir
defmodule MyAppWeb.ApprovalsLive do
  use MyAppWeb, :live_view

  @topic "approvals"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, @topic)
    end

    {:ok, assign(socket, pending: list_pending())}
  end

  @impl true
  def handle_info({:approval_update, _}, socket) do
    {:noreply, assign(socket, pending: list_pending())}
  end

  # ... approve/deny handlers broadcast after acting:
  def handle_event("approve", %{"id" => id}, socket) do
    ADK.Tool.Approval.approve(MyApp.Approvals, id)
    Phoenix.PubSub.broadcast(MyApp.PubSub, @topic, {:approval_update, id})
    {:noreply, assign(socket, pending: list_pending())}
  end
end
```

Combine this with the `prompt_fn` on the policy to broadcast when new
approvals arrive:

```elixir
policy = ADK.Policy.HumanApproval.new(
  sensitive_tools: ["delete_file"],
  mode: :server,
  server: MyApp.Approvals,
  prompt_fn: fn %{request_id: id} ->
    Phoenix.PubSub.broadcast(MyApp.PubSub, "approvals", {:approval_update, id})
  end
)
```

## API-Based Approval (Headless / A2A)

For headless services or Agent-to-Agent scenarios where there's no UI:

```elixir
defmodule MyAppWeb.ApprovalController do
  use MyAppWeb, :controller

  def index(conn, _params) do
    pending = ADK.Tool.Approval.list_pending(MyApp.Approvals)
    json(conn, %{pending: pending})
  end

  def approve(conn, %{"id" => request_id}) do
    case ADK.Tool.Approval.approve(MyApp.Approvals, request_id) do
      :ok -> json(conn, %{status: "approved"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end

  def deny(conn, %{"id" => request_id, "reason" => reason}) do
    case ADK.Tool.Approval.deny(MyApp.Approvals, request_id, reason) do
      :ok -> json(conn, %{status: "denied"})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not found"})
    end
  end
end

# Router
scope "/api/approvals", MyAppWeb do
  get "/", ApprovalController, :index
  post "/:id/approve", ApprovalController, :approve
  post "/:id/deny", ApprovalController, :deny
end
```

Usage:

```bash
# List pending
curl http://localhost:4000/api/approvals

# Approve
curl -X POST http://localhost:4000/api/approvals/approval-xK9m.../approve

# Deny
curl -X POST http://localhost:4000/api/approvals/approval-xK9m.../deny \
  -H "Content-Type: application/json" \
  -d '{"reason": "Not authorized for this operation"}'
```

## The Claw Example

The Claw example in `examples/claw/` demonstrates a complete HITL setup:

```elixir
# examples/claw/lib/claw/agents.ex

# The delete_file tool — a sensitive operation
ADK.Tool.FunctionTool.new(
  name: "delete_file",
  description: "Delete a file from the filesystem",
  function: fn %{"path" => path}, _ctx ->
    File.rm!(path)
    "Deleted #{path}"
  end
)

# HITL policy builder
def hitl_policy(opts \\ []) do
  ADK.Policy.HumanApproval.new(
    Keyword.merge(
      [sensitive_tools: Claw.Tools.sensitive_tool_names(), mode: :cli],
      opts
    )
  )
end

# Usage in CLI
policy = Claw.Agents.hitl_policy()
events = ADK.Runner.run(runner, user_id, session_id, message,
  policies: [policy]
)

# Usage in production with server mode
{:ok, _} = ADK.Tool.Approval.start_link(name: ClawApprovals)
policy = Claw.Agents.hitl_policy(mode: :server, server: ClawApprovals)
```

Run the Claw example to see HITL in action:

```bash
cd examples/claw
mix deps.get
mix run -e "Claw.CLI.main()"
# Ask: "Delete the file /tmp/test.txt"
# You'll get the approval prompt
```

## Custom Policies

`ADK.Policy.HumanApproval` handles the common case, but you can implement
the `ADK.Policy` behaviour directly for custom logic:

```elixir
defmodule MyApp.RateLimitPolicy do
  @behaviour ADK.Policy

  @impl true
  def authorize_tool(%{name: tool_name}, _args, ctx) do
    key = "tool_count:#{tool_name}"
    count = ADK.Session.get_state(ctx.session_pid, key) || 0

    if count >= 10 do
      {:deny, "Tool #{tool_name} has been called #{count} times this session (limit: 10)"}
    else
      ADK.Session.set_state(ctx.session_pid, key, count + 1)
      :allow
    end
  end

  @impl true
  def filter_input(content, _ctx), do: {:cont, content}

  @impl true
  def filter_output(events, _ctx), do: events
end
```

### Composing Multiple Policies

Policies compose as a chain of responsibility. For tool authorization, the
**first deny wins** — all policies must allow:

```elixir
policies = [
  MyApp.RateLimitPolicy,                           # Module-based
  ADK.Policy.HumanApproval.new(                    # Struct-based
    sensitive_tools: ["delete_file"],
    mode: :server,
    server: MyApp.Approvals
  ),
  MyApp.AuditLogPolicy                             # Module-based
]

events = ADK.Runner.run(runner, uid, sid, msg, policies: policies)
```

The runner checks each policy in order:

1. `RateLimitPolicy.authorize_tool/3` — checks rate limit
2. `HumanApproval.check/4` — blocks for human approval (if sensitive)
3. `AuditLogPolicy.authorize_tool/3` — logs the tool call

If any returns `{:deny, reason}`, the tool doesn't execute.

## Patterns

### Pattern 1: Escalation Chain

Agent tries → supervisor agent reviews → human approves:

```elixir
defmodule MyApp.EscalationPolicy do
  @behaviour ADK.Policy

  @auto_approve ["list_files", "read_file", "search"]
  @supervisor_review ["edit_file", "create_file"]
  @human_required ["delete_file", "deploy", "send_email"]

  @impl true
  def authorize_tool(%{name: name}, args, ctx) do
    cond do
      name in @auto_approve ->
        :allow

      name in @supervisor_review ->
        # Ask a supervisor agent to review
        case supervisor_review(name, args, ctx) do
          :approved -> :allow
          :rejected -> {:deny, "Supervisor agent rejected #{name}"}
        end

      name in @human_required ->
        # Delegate to HumanApproval (via the Approval GenServer)
        {id, _req} = ADK.Tool.Approval.register(MyApp.Approvals, name, args)
        ADK.Tool.Approval.await(MyApp.Approvals, id, 120_000)

      true ->
        {:deny, "Unknown tool: #{name}"}
    end
  end

  defp supervisor_review(tool_name, args, _ctx) do
    # Run a quick LLM check — "Should this tool call be allowed?"
    prompt = """
    An agent wants to call tool "#{tool_name}" with args: #{inspect(args)}.
    Is this safe and appropriate? Reply with APPROVED or REJECTED and a reason.
    """

    case ADK.LLM.Gemini.generate("gemini-flash-latest", prompt) do
      {:ok, %{text: text}} ->
        if String.contains?(String.upcase(text), "APPROVED"), do: :approved, else: :rejected
      _ ->
        :rejected  # Fail closed
    end
  end

  @impl true
  def filter_input(content, _ctx), do: {:cont, content}

  @impl true
  def filter_output(events, _ctx), do: events
end
```

### Pattern 2: Approval with Rich Context

Include conversation context in the approval request so the human reviewer
can make an informed decision:

```elixir
policy = ADK.Policy.HumanApproval.new(
  sensitive_tools: ["process_refund"],
  mode: :server,
  server: MyApp.Approvals,
  prompt_fn: fn %{tool_name: name, args: args, request_id: id} ->
    # Enrich the approval request with conversation context
    MyApp.ApprovalEnricher.enrich(id, %{
      tool: name,
      args: args,
      # Pull recent conversation for context
      recent_messages: fetch_recent_messages(args),
      # Add business context
      customer_info: MyApp.Customers.lookup(args["customer_id"]),
      refund_history: MyApp.Refunds.recent(args["customer_id"])
    })
  end
)
```

### Pattern 3: Timeout Handling with Fallback

When approval times out, take a graceful fallback action:

```elixir
defmodule MyApp.GracefulHITL do
  @behaviour ADK.Policy

  @impl true
  def authorize_tool(%{name: "deploy"} = tool, args, ctx) do
    {id, _} = ADK.Tool.Approval.register(MyApp.Approvals, "deploy", args)

    case ADK.Tool.Approval.await(MyApp.Approvals, id, 300_000) do
      :allow ->
        :allow

      {:deny, "Approval timed out" <> _} ->
        # Timeout — create a ticket instead of just failing
        MyApp.Tickets.create(%{
          title: "Deploy approval timed out",
          description: "Agent requested deploy with args: #{inspect(args)}",
          priority: :high
        })
        {:deny, "Deploy approval timed out. A ticket has been created for manual review."}

      {:deny, reason} ->
        {:deny, reason}
    end
  end

  def authorize_tool(_tool, _args, _ctx), do: :allow

  @impl true
  def filter_input(content, _ctx), do: {:cont, content}

  @impl true
  def filter_output(events, _ctx), do: events
end
```

### Pattern 4: Conditional HITL Based on Risk Score

Only require human approval when the risk exceeds a threshold:

```elixir
defmodule MyApp.RiskBasedHITL do
  @behaviour ADK.Policy

  @impl true
  def authorize_tool(%{name: name}, args, ctx) do
    risk = calculate_risk(name, args, ctx)

    cond do
      risk < 0.3 ->
        :allow

      risk < 0.7 ->
        # Log but allow
        Logger.warning("Medium risk tool call: #{name} (risk: #{risk})")
        :allow

      true ->
        # High risk — require human approval
        {id, _} = ADK.Tool.Approval.register(MyApp.Approvals, name, args)
        ADK.Tool.Approval.await(MyApp.Approvals, id, 120_000)
    end
  end

  defp calculate_risk("delete_file", %{"path" => path}, _ctx) do
    cond do
      String.starts_with?(path, "/tmp") -> 0.2
      String.contains?(path, "config") -> 0.9
      String.contains?(path, "production") -> 1.0
      true -> 0.5
    end
  end

  defp calculate_risk("send_email", %{"to" => to}, _ctx) do
    if String.ends_with?(to, "@internal.com"), do: 0.3, else: 0.8
  end

  defp calculate_risk(_tool, _args, _ctx), do: 0.1

  @impl true
  def filter_input(content, _ctx), do: {:cont, content}

  @impl true
  def filter_output(events, _ctx), do: events
end
```

## Comparison with Python ADK

Python ADK (as of v1.26) **does not have a first-class HITL system**. The
typical Python approach is:

```python
# Python — manual HITL (no built-in support)
class MyAgent(Agent):
    async def on_tool_call(self, tool_name, args):
        if tool_name in SENSITIVE_TOOLS:
            # Block? Poll? Webhook? You're on your own.
            approved = await some_custom_approval_flow(tool_name, args)
            if not approved:
                raise ToolDenied(f"User denied {tool_name}")
```

There's no standard pattern, no GenServer, no policy composition, no
struct-based configuration. Every Python project reinvents HITL differently.

### What ADK Elixir Provides That Python Doesn't

| Feature | Python ADK | ADK Elixir |
|---------|-----------|------------|
| Policy behaviour | ❌ No standard | ✅ `ADK.Policy` behaviour |
| HITL policy | ❌ DIY | ✅ `ADK.Policy.HumanApproval` |
| Approval server | ❌ DIY | ✅ `ADK.Tool.Approval` GenServer |
| CLI mode | ❌ DIY | ✅ Built-in stdin prompt |
| Server mode | ❌ DIY | ✅ Built-in async with GenServer |
| Timeout handling | ❌ DIY | ✅ Configurable with auto-deny |
| Policy composition | ❌ DIY | ✅ Chain of responsibility |
| Custom prompt fn | ❌ DIY | ✅ `prompt_fn` option |
| Struct-based config | ❌ N/A | ✅ Per-instance configuration |
| LiveView integration | ❌ N/A | ✅ `list_pending` + PubSub |

The key Elixir advantages:

1. **GenServer for coordination** — The Approval server is a supervised OTP
   process. It doesn't crash and lose pending approvals. If it does crash, the
   supervisor restarts it.

2. **Process-based blocking** — `await/3` uses Erlang's `receive` to block
   the agent process cleanly. No polling, no callbacks, no event loops.

3. **Supervision** — The approval server is part of your OTP supervision tree.
   If it crashes, pending approvals get a clean timeout. No orphaned state.

4. **PubSub for real-time** — Phoenix PubSub gives you instant notifications
   when approvals arrive, without WebSocket plumbing.

## Testing HITL

Test your HITL policies without actually blocking on human input:

```elixir
defmodule MyApp.HITLTest do
  use ExUnit.Case

  test "sensitive tool is intercepted" do
    # Start approval server for the test
    {:ok, server} = ADK.Tool.Approval.start_link(name: :test_approvals)

    policy = ADK.Policy.HumanApproval.new(
      sensitive_tools: ["delete_file"],
      mode: :server,
      server: :test_approvals,
      timeout: 5_000
    )

    tool = %{name: "delete_file"}
    args = %{"path" => "/tmp/test"}
    ctx = %ADK.Context{session_pid: nil, branch: nil}

    # Approve from another process after a short delay
    spawn(fn ->
      Process.sleep(100)
      [req] = ADK.Tool.Approval.list_pending(:test_approvals)
      ADK.Tool.Approval.approve(:test_approvals, req.id)
    end)

    assert :allow = ADK.Policy.HumanApproval.check(policy, tool, args, ctx)

    GenServer.stop(server)
  end

  test "timeout results in denial" do
    {:ok, server} = ADK.Tool.Approval.start_link(name: :test_timeout)

    policy = ADK.Policy.HumanApproval.new(
      sensitive_tools: ["delete_file"],
      mode: :server,
      server: :test_timeout,
      timeout: 100  # Very short timeout
    )

    tool = %{name: "delete_file"}
    args = %{"path" => "/tmp/test"}
    ctx = %ADK.Context{session_pid: nil, branch: nil}

    # Don't approve — let it timeout
    assert {:deny, "Approval timed out" <> _} =
             ADK.Policy.HumanApproval.check(policy, tool, args, ctx)

    GenServer.stop(server)
  end

  test "non-sensitive tools pass through" do
    policy = ADK.Policy.HumanApproval.new(
      sensitive_tools: ["delete_file"],
      mode: :cli
    )

    tool = %{name: "list_files"}
    args = %{"dir" => "/tmp"}
    ctx = %ADK.Context{session_pid: nil, branch: nil}

    assert :allow = ADK.Policy.HumanApproval.check(policy, tool, args, ctx)
  end
end
```

## Summary

ADK Elixir's HITL system gives you:

1. **Zero-config CLI mode** for development and prototyping
2. **Production-ready server mode** with GenServer coordination
3. **Composable policies** that chain together
4. **LiveView-ready** with `list_pending` and PubSub
5. **API-ready** for headless and A2A scenarios
6. **Testable** without human interaction
7. **Supervised** by OTP for fault tolerance

Start with `mode: :cli` during development. Switch to `mode: :server` for
production. Add a LiveView dashboard when you need visibility. The API
stays the same throughout.

## Further Reading

- [Agent Patterns](agent-patterns.md) — HITL pattern (#10) and 24 other patterns
- [Supervision](supervision.md) — OTP supervision tree for ADK
- [Phoenix Integration](phoenix-integration.md) — LiveView agent UI
- [Context Engineering](context-engineering.md) — How agent context is compiled
