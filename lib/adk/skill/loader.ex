defmodule ADK.Skill.Loader do
  @moduledoc """
  Enhanced skill directory loader that auto-discovers tools from:

  - `tools/*.ex` — Elixir modules implementing ADK.Tool behaviour
  - `tools/*.py` — Python scripts wrapped as ExecTool
  - `tools/*.sh` — Shell scripts wrapped as ExecTool
  - `mcp.json` — MCP server configurations
  - `auth.json` — Credential requirements
  """

  alias ADK.Skill.ExecTool
  alias ADK.Skill.Supervisor, as: SkillSupervisor

  require Logger

  @doc """
  Load tools, MCP toolsets, and auth requirements from a skill directory.

  Returns a map with:
  - `:tools` — list of FunctionTool structs
  - `:mcp_toolsets` — list of MCP Toolset pids
  - `:auth_requirements` — list of credential requirement maps
  - `:supervisor` — pid of the skill supervisor (if MCP servers exist)
  """
  @spec load(Path.t()) :: map()
  def load(dir) do
    tools = discover_tools(dir)
    auth = load_auth(dir)
    {mcp_toolsets, supervisor} = load_mcp(dir)

    %{
      tools: tools,
      mcp_toolsets: mcp_toolsets,
      auth_requirements: auth,
      supervisor: supervisor
    }
  end

  @doc "Discover tools from the tools/ subdirectory."
  @spec discover_tools(Path.t()) :: [ADK.Tool.FunctionTool.t()]
  def discover_tools(dir) do
    tools_dir = Path.join(dir, "tools")

    if File.dir?(tools_dir) do
      tools_dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.flat_map(fn file ->
        path = Path.join(tools_dir, file)
        load_tool_file(path)
      end)
    else
      []
    end
  end

  @doc "Load auth requirements from auth.json."
  @spec load_auth(Path.t()) :: [map()]
  def load_auth(dir) do
    auth_path = Path.join(dir, "auth.json")

    if File.exists?(auth_path) do
      case File.read(auth_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{"credentials" => creds}} when is_list(creds) ->
              creds

            _ ->
              Logger.warning("Malformed auth.json in #{dir}")
              []
          end

        _ ->
          []
      end
    else
      []
    end
  end

  @doc "Load MCP server configurations and start toolsets."
  @spec load_mcp(Path.t()) :: {[pid()], pid() | nil}
  def load_mcp(dir) do
    mcp_path = Path.join(dir, "mcp.json")

    if File.exists?(mcp_path) do
      case File.read(mcp_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{"servers" => servers}} when is_list(servers) ->
              start_mcp_servers(servers)

            _ ->
              Logger.warning("Malformed mcp.json in #{dir}")
              {[], nil}
          end

        _ ->
          {[], nil}
      end
    else
      {[], nil}
    end
  end

  @doc "Parse MCP server config entries without starting them."
  @spec parse_mcp_config(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_mcp_config(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"servers" => servers}} when is_list(servers) -> {:ok, servers}
          _ -> {:error, :malformed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private ---

  defp load_tool_file(path) do
    ext = Path.extname(path)

    case ext do
      ".py" ->
        if ADK.Skill.Deps.available?("python3") do
          [ExecTool.new(path)]
        else
          Logger.warning("Skipping #{Path.basename(path)}: python3 not found")
          []
        end

      ".sh" ->
        if ADK.Skill.Deps.available?("bash") do
          [ExecTool.new(path)]
        else
          Logger.warning("Skipping #{Path.basename(path)}: bash not found")
          []
        end

      ".ex" ->
        load_elixir_tool(path)

      _ ->
        []
    end
  end

  defp load_elixir_tool(path) do
    try do
      modules = Code.compile_file(path)

      modules
      |> Enum.filter(fn {mod, _bytecode} ->
        function_exported?(mod, :call, 2) or function_exported?(mod, :call, 1)
      end)
      |> Enum.map(fn {mod, _bytecode} ->
        name = mod |> Module.split() |> List.last() |> Macro.underscore()
        description = if function_exported?(mod, :description, 0), do: mod.description(), else: ""

        parameters =
          if function_exported?(mod, :parameters, 0), do: mod.parameters(), else: %{}

        func =
          if function_exported?(mod, :call, 2) do
            fn ctx, args -> mod.call(ctx, args) end
          else
            fn _ctx, args -> mod.call(args) end
          end

        ADK.Tool.FunctionTool.new(name,
          description: description,
          func: func,
          parameters: parameters
        )
      end)
    rescue
      e ->
        Logger.warning("Failed to compile #{path}: #{inspect(e)}")
        []
    end
  end

  defp start_mcp_servers(servers) do
    case SkillSupervisor.start_link([]) do
      {:ok, sup} ->
        toolsets =
          Enum.flat_map(servers, fn server ->
            opts = build_mcp_opts(server)

            case SkillSupervisor.start_mcp_toolset(sup, opts) do
              {:ok, pid} ->
                [pid]

              {:error, reason} ->
                Logger.warning("Failed to start MCP server #{server["name"]}: #{inspect(reason)}")
                []
            end
          end)

        if toolsets == [] do
          SkillSupervisor.stop(sup)
          {[], nil}
        else
          {toolsets, sup}
        end

      {:error, reason} ->
        Logger.warning("Failed to start skill supervisor: #{inspect(reason)}")
        {[], nil}
    end
  end

  defp build_mcp_opts(server) do
    opts = [
      command: server["command"],
      args: server["args"] || []
    ]

    opts =
      if env = server["env"] do
        env_list = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
        Keyword.put(opts, :env, env_list)
      else
        opts
      end

    if filter = server["tool_filter"] do
      Keyword.put(opts, :tool_filter, filter)
    else
      opts
    end
  end
end
