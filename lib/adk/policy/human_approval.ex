defmodule ADK.Policy.HumanApproval do
  @moduledoc """
  A policy that pauses agent execution and requires human approval before
  running sensitive tools — Human-in-the-loop (HITL) tool confirmation.

  ## Modes

  * `:cli` — prompts the user interactively via stdin. Blocks the agent process
    until the user types `y`/`yes` or `n`/`no`. Best for terminal-based agents.

  * `:server` — registers the request with `ADK.Tool.Approval` GenServer and
    blocks until externally approved or denied. Use this for web UIs (LiveView),
    webhooks, or any async approval flow.

  ## Usage

      # CLI mode — user is prompted in the terminal
      policy = ADK.Policy.HumanApproval.new(
        sensitive_tools: ["shell_command", "delete_file"],
        mode: :cli
      )

      # CLI mode with custom prompt function
      policy = ADK.Policy.HumanApproval.new(
        sensitive_tools: :all,
        mode: :cli,
        prompt_fn: fn %{tool_name: name, args: args} ->
          IO.puts("About to call \#{name} with \#{inspect(args)}")
          answer = IO.gets("OK? [y/N]: ") |> String.trim()
          if answer in ["y", "yes"], do: :allow, else: {:deny, "Custom rejection"}
        end
      )

      # Server mode — approve via ADK.Tool.Approval.approve/2
      {:ok, _} = ADK.Tool.Approval.start_link(name: MyApprovals)
      policy = ADK.Policy.HumanApproval.new(
        sensitive_tools: ["delete_file"],
        mode: :server,
        server: MyApprovals,
        timeout: 120_000
      )

      # Pass to Runner.run/5
      ADK.Runner.run(runner, user_id, session_id, message, policies: [policy])

  ## Struct-based Policies

  `HumanApproval` is a struct, not just a module. `ADK.Policy.check_tool_authorization/4`
  detects structs and dispatches to `check/4` directly rather than calling `authorize_tool/3`
  on the module. This allows per-instance configuration (different tools, modes, servers).

  If you use `HumanApproval` as a bare module (unusual), all tools are allowed by default.
  Use `new/1` to create a configured struct instance.
  """

  @behaviour ADK.Policy

  @enforce_keys [:sensitive_tools]
  defstruct [
    :sensitive_tools,
    mode: :cli,
    server: ADK.Tool.Approval,
    timeout: 60_000,
    prompt_fn: nil
  ]

  @type t :: %__MODULE__{
          sensitive_tools: [String.t()] | :all,
          mode: :cli | :server,
          server: atom() | pid(),
          timeout: pos_integer(),
          prompt_fn: (map() -> :allow | {:deny, String.t()}) | nil
        }

  @doc """
  Create a new `HumanApproval` policy struct.

  ## Options

    * `:sensitive_tools` — list of tool name strings to intercept, or `:all` (required)
    * `:mode` — `:cli` (default) or `:server`
    * `:server` — `ADK.Tool.Approval` server name or pid (server mode only)
    * `:timeout` — ms to wait for server-mode approval (default: 60_000)
    * `:prompt_fn` — custom `(%{tool_name, args, request_id}) -> :allow | {:deny, reason}`
  """
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  # --- ADK.Policy behaviour (module-level defaults) ---

  @impl ADK.Policy
  @doc false
  def authorize_tool(_tool, _args, _ctx), do: :allow

  @impl ADK.Policy
  @doc false
  def filter_input(content, _ctx), do: {:cont, content}

  @impl ADK.Policy
  @doc false
  def filter_output(events, _ctx), do: events

  # --- Struct-level check (called by check_tool_authorization for struct policies) ---

  @doc """
  Check authorization for a specific `HumanApproval` struct instance.

  Returns `:allow` or `{:deny, reason}`. May block if awaiting human input.
  """
  @spec check(t(), map(), map(), ADK.Context.t()) :: :allow | {:deny, String.t()}
  def check(%__MODULE__{} = policy, tool, args, _ctx) do
    tool_name = Map.get(tool, :name, "unknown")

    if sensitive?(policy, tool_name) do
      request_approval(policy, tool_name, args)
    else
      :allow
    end
  end

  # --- Private helpers ---

  defp sensitive?(%{sensitive_tools: :all}, _name), do: true
  defp sensitive?(%{sensitive_tools: tools}, name), do: name in tools

  defp request_approval(%{mode: :cli} = policy, tool_name, args) do
    cli_prompt(policy, tool_name, args)
  end

  defp request_approval(%{mode: :server} = policy, tool_name, args) do
    server_approval(policy, tool_name, args)
  end

  defp cli_prompt(%{prompt_fn: prompt_fn}, tool_name, args) when not is_nil(prompt_fn) do
    prompt_fn.(%{tool_name: tool_name, args: args, request_id: nil})
  end

  defp cli_prompt(_policy, tool_name, args) do
    args_str =
      case map_size(args) do
        0 -> "(no args)"
        _ -> inspect(args)
      end

    truncated = String.slice(args_str, 0, 200)
    label = String.pad_trailing("  Tool: #{tool_name}", 55)
    args_label = String.pad_trailing("  Args: #{truncated}", 55)

    IO.puts("""

    ┌─────────────────────────────────────────────────────┐
    │  🔒 Human Approval Required                          │
    #{label}│
    #{args_label}│
    └─────────────────────────────────────────────────────┘
    """)

    answer =
      IO.gets("Allow this tool call? [y/N]: ")
      |> String.trim()
      |> String.downcase()

    if answer in ["y", "yes"] do
      :allow
    else
      {:deny, "User declined tool '#{tool_name}'"}
    end
  end

  defp server_approval(%{server: server, timeout: timeout, prompt_fn: prompt_fn}, tool_name, args) do
    {request_id, request} = ADK.Tool.Approval.register(server, tool_name, args)

    # If a prompt_fn is given, fire it in a separate process so it can
    # notify a UI / send a message / etc. without blocking the subscription.
    if prompt_fn do
      spawn(fn ->
        prompt_fn.(%{tool_name: tool_name, args: args, request_id: request_id, request: request})
      end)
    end

    case ADK.Tool.Approval.await(server, request_id, timeout) do
      :allow -> :allow
      {:deny, reason} -> {:deny, reason}
    end
  end
end
