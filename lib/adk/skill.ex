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
        model: "gemini-2.0-flash",
        instruction: "You are helpful.",
        skills: [skill]
      )
  """

  @enforce_keys [:name, :instruction, :dir]
  defstruct [:name, :description, :instruction, :tools, :dir]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          instruction: String.t(),
          tools: [map()] | nil,
          dir: Path.t()
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
      |> Enum.flat_map(fn s -> s.tools || [] end)

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

  # --- Private helpers ---

  defp parse_skill(content, dir) do
    name = extract_name(content) || Path.basename(dir)
    description = extract_description(content)

    %__MODULE__{
      name: name,
      description: description,
      instruction: String.trim(content),
      tools: [],
      dir: dir
    }
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
