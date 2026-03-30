defmodule ADK.Skill do
  @moduledoc """
  A Skill is a reusable bundle of instructions (and optionally tools)
  that can be loaded from a directory and mixed into an LlmAgent.

  A skill directory contains:

  - `SKILL.md` — required; provides the skill's instruction text
  - Additional files as needed (tool modules, reference docs, etc.)

  ## SKILL.md format

  The first `# Heading` becomes the skill name (fallback: directory basename).
  The first `>` blockquote line becomes the description.
  The full file content is used as the instruction.

  ```markdown
  # My Skill

  > Short description of what this skill does.

  ## Instructions

  Detailed instruction text here...
  ```

  ## Usage

      # Load a single skill from a directory
      {:ok, skill} = ADK.Skill.from_dir("path/to/skills/my_skill")

      # Load all skills from a root skills directory
      {:ok, skills} = ADK.Skill.load_from_dir("path/to/skills/")

      # Use with LlmAgent
      agent = ADK.Agent.LlmAgent.new(
        name: "bot",
        model: "gemini-flash-latest",
        instruction: "You are helpful.",
        skills: [skill]
      )
  """

  require Logger

  @enforce_keys [:name, :instruction, :dir]
  defstruct [
    :name,
    :description,
    :instruction,
    :tools,
    :dir,
    :mcp_toolsets,
    :auth_requirements,
    :supervisor,
    missing_deps: []
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          instruction: String.t(),
          tools: [map()] | nil,
          dir: Path.t(),
          mcp_toolsets: [pid()] | nil,
          auth_requirements: [map()] | nil,
          supervisor: pid() | nil,
          missing_deps: [String.t()]
        }

  @doc """
  Load a single skill from a directory.

  The directory must contain a `SKILL.md` file.

  Returns `{:ok, skill}` or `{:error, reason}`.

  ## Examples

      iex> dir = Path.join(System.tmp_dir!(), "test_skill_from_dir")
      iex> File.mkdir_p!(dir)
      iex> File.write!(Path.join(dir, "SKILL.md"), "# Test Skill\\n\\n> A test.\\n\\nDo stuff.")
      iex> {:ok, skill} = ADK.Skill.from_dir(dir)
      iex> skill.name
      "Test Skill"
      iex> skill.description
      "A test."
  """
  @spec from_dir(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def from_dir(dir) do
    skill_md = Path.join(dir, "SKILL.md")

    cond do
      not File.dir?(dir) ->
        {:error, "Not a directory: #{dir}"}

      not File.exists?(skill_md) ->
        {:error, "No SKILL.md found in: #{dir}"}

      true ->
        case File.read(skill_md) do
          {:ok, content} ->
            {:ok, parse_skill(content, dir)}

          {:error, reason} ->
            {:error, "Failed to read SKILL.md in #{dir}: #{reason}"}
        end
    end
  end

  @doc """
  Load a single skill from a directory, raising on error.

  ## Examples

      iex> dir = Path.join(System.tmp_dir!(), "test_skill_bang")
      iex> File.mkdir_p!(dir)
      iex> File.write!(Path.join(dir, "SKILL.md"), "# Bang Skill\\n\\nInstruction.")
      iex> skill = ADK.Skill.from_dir!(dir)
      iex> skill.name
      "Bang Skill"
  """
  @spec from_dir!(Path.t()) :: t()
  def from_dir!(dir) do
    case from_dir(dir) do
      {:ok, skill} -> skill
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  Scan a root directory and load all skills from subdirectories containing `SKILL.md`.

  Returns `{:ok, [skill]}` with all successfully loaded skills.
  Subdirectories without `SKILL.md` are silently skipped.

  ## Examples

      iex> root = Path.join(System.tmp_dir!(), "test_skill_root")
      iex> skill_dir = Path.join(root, "my_skill")
      iex> File.mkdir_p!(skill_dir)
      iex> File.write!(Path.join(skill_dir, "SKILL.md"), "# My Skill\\n\\nDo things.")
      iex> {:ok, skills} = ADK.Skill.load_from_dir(root)
      iex> length(skills)
      1
      iex> hd(skills).name
      "My Skill"
  """
  @spec load_from_dir(Path.t()) :: {:ok, [t()]} | {:error, String.t()}
  def load_from_dir(root) do
    if not File.dir?(root) do
      {:error, "Not a directory: #{root}"}
    else
      skills =
        root
        |> File.ls!()
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.filter(fn dir -> File.exists?(Path.join(dir, "SKILL.md")) end)
        |> Enum.flat_map(fn dir ->
          case from_dir(dir) do
            {:ok, skill} -> [skill]
            {:error, _} -> []
          end
        end)
        |> Enum.sort_by(& &1.name)

      {:ok, skills}
    end
  end

  @doc """
  Returns the instruction string for this skill.

  Useful when composing multiple skill instructions.
  """
  @spec to_instruction(t()) :: String.t()
  def to_instruction(%__MODULE__{instruction: instruction}), do: instruction

  @doc """
  Merge a list of skills into an agent opts keyword list.

  Appends skill instructions to the `:instruction` field and merges skill
  tools into the `:tools` list. Safe to call with an empty list.

  ## Examples

      iex> skill = %ADK.Skill{
      ...>   name: "Helper",
      ...>   instruction: "Be extra helpful.",
      ...>   dir: "/tmp/helper"
      ...> }
      iex> opts = [name: "bot", model: "test", instruction: "You assist users.", tools: []]
      iex> merged = ADK.Skill.apply_to_opts(opts, [skill])
      iex> String.contains?(merged[:instruction], "Be extra helpful.")
      true
  """
  @spec apply_to_opts(keyword(), [t()]) :: keyword()
  def apply_to_opts(opts, []), do: opts

  def apply_to_opts(opts, skills) when is_list(skills) do
    skill_instructions =
      skills
      |> Enum.map(&to_instruction/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n---\n\n")

    skill_tools =
      skills
      |> Enum.flat_map(fn s ->
        local_tools = s.tools || []
        mcp_tools = fetch_mcp_tools(s)
        local_tools ++ mcp_tools
      end)

    opts
    |> Keyword.update(:instruction, skill_instructions, fn existing ->
      if skill_instructions == "" do
        existing
      else
        existing <> "\n\n---\n\n" <> skill_instructions
      end
    end)
    |> Keyword.update(:tools, skill_tools, fn existing ->
      existing ++ skill_tools
    end)
  end

  @doc """
  Stop all supervised processes for this skill (MCP servers, etc).
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{supervisor: nil}), do: :ok

  def stop(%__MODULE__{supervisor: sup}) do
    ADK.Skill.Supervisor.stop(sup)
  end

  # --- Private helpers ---

  defp fetch_mcp_tools(%__MODULE__{mcp_toolsets: toolsets}) when is_list(toolsets) do
    Enum.flat_map(toolsets, fn pid ->
      if Process.alive?(pid) do
        case ADK.MCP.Toolset.get_tools(pid) do
          {:ok, tools} -> tools
          _ -> []
        end
      else
        []
      end
    end)
  end

  defp fetch_mcp_tools(_), do: []

  defp parse_skill(content, dir) do
    {fm, body} = extract_frontmatter(content)
    name = fm["name"] || extract_name(body) || Path.basename(dir)
    description = fm["description"] || extract_description(body)
    deps = parse_deps(fm["deps"])
    missing_deps = check_skill_deps(name, deps)
    loaded = ADK.Skill.Loader.load(dir)
    script_tools = ADK.Skill.Script.discover(dir).tools

    %__MODULE__{
      name: name,
      description: description,
      instruction: String.trim(content),
      tools: (loaded.tools || []) ++ script_tools,
      dir: dir,
      mcp_toolsets: loaded.mcp_toolsets,
      auth_requirements: loaded.auth_requirements,
      supervisor: loaded.supervisor,
      missing_deps: missing_deps
    }
  end

  defp parse_deps(list) when is_list(list), do: list
  defp parse_deps(str) when is_binary(str), do: String.split(str, ~r/[,\s]+/, trim: true)
  defp parse_deps(_), do: []

  defp check_skill_deps(_name, []), do: []

  defp check_skill_deps(name, deps) do
    {_available, missing} = ADK.Skill.Deps.check(deps)

    if missing != [] do
      Logger.warning(
        "Skill \"#{name}\" has missing dependencies: #{inspect(missing)}. Some tools may be unavailable."
      )
    end

    missing
  end

  defp extract_frontmatter(content) do
    case Regex.run(~r/\A---\s*\n(.*?)\n---\s*\n(.*)\z/s, content) do
      [_, yaml_block, body] ->
        fm = parse_yaml_block(yaml_block)
        {fm, body}

      nil ->
        {%{}, content}
    end
  end

  defp parse_yaml_block(block) do
    block
    |> String.split("\n")
    |> parse_yaml_lines(nil, %{})
  end

  defp parse_yaml_lines([], _current_list_key, acc), do: acc

  defp parse_yaml_lines([line | rest], current_list_key, acc) do
    cond do
      # YAML list item: "  - value" (only when following a list key)
      current_list_key != nil && Regex.match?(~r/^\s+-\s+/, line) ->
        [_, item] = Regex.run(~r/^\s+-\s+(.+)$/, line)
        existing = Map.get(acc, current_list_key, [])

        parse_yaml_lines(
          rest,
          current_list_key,
          Map.put(acc, current_list_key, existing ++ [String.trim(item)])
        )

      # Key with inline value: "key: value"
      Regex.match?(~r/^(\w+):\s+(.+)$/, line) ->
        [_, key, val] = Regex.run(~r/^(\w+):\s+(.+)$/, line)
        parse_yaml_lines(rest, nil, Map.put(acc, key, String.trim(val)))

      # Key with no value (list follows): "key:"
      Regex.match?(~r/^(\w+):\s*$/, line) ->
        [_, key] = Regex.run(~r/^(\w+):\s*$/, line)
        parse_yaml_lines(rest, key, acc)

      true ->
        parse_yaml_lines(rest, nil, acc)
    end
  end

  defp extract_name(content) do
    # Match the first # heading
    case Regex.run(~r/^#\s+(.+)$/m, content) do
      [_, heading] -> String.trim(heading)
      nil -> nil
    end
  end

  defp extract_description(content) do
    # Match the first > blockquote line
    case Regex.run(~r/^>\s+(.+)$/m, content) do
      [_, desc] -> String.trim(desc)
      nil -> nil
    end
  end
end
