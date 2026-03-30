defmodule ADK.Skill.Toolset do
  @moduledoc """
  Progressive disclosure toolset for skills.

  Wraps a list of `ADK.Skill` structs and generates three tools that let an
  LLM agent discover skills incrementally — saving tokens by loading detail
  only when needed.

  ## Disclosure levels

  1. **`list_skills`** — returns skill names + descriptions (~200 tokens).
  2. **`load_skill`** — given a skill name, returns the full SKILL.md instruction.
  3. **`load_skill_resource`** — given a skill name + resource path, reads a
     file from the skill's `references/` directory.

  ## Usage

      skills = [seo_skill, blog_skill]
      toolset = ADK.Skill.Toolset.new(skills)
      tools = ADK.Skill.Toolset.tools(toolset)

      agent = ADK.Agent.LlmAgent.new(
        name: "writer",
        model: "gemini-flash-latest",
        instruction: "You write blog posts.",
        tools: tools
      )
  """

  alias ADK.Tool.FunctionTool

  defstruct [:skills]

  @type t :: %__MODULE__{skills: %{String.t() => ADK.Skill.t()}}

  @doc """
  Create a new toolset from a list of skills.

  Raises `ArgumentError` if duplicate skill names are detected.
  """
  @spec new([ADK.Skill.t()]) :: t()
  def new(skills) when is_list(skills) do
    skill_map =
      Enum.reduce(skills, %{}, fn skill, acc ->
        if Map.has_key?(acc, skill.name) do
          raise ArgumentError, "Duplicate skill name: #{inspect(skill.name)}"
        end

        Map.put(acc, skill.name, skill)
      end)

    %__MODULE__{skills: skill_map}
  end

  @doc """
  Returns the three progressive-disclosure tools for this toolset.
  """
  @spec tools(t()) :: [FunctionTool.t()]
  def tools(%__MODULE__{} = toolset) do
    [
      list_skills_tool(toolset),
      load_skill_tool(toolset),
      load_skill_resource_tool(toolset)
    ]
  end

  # --- Tool builders ---

  defp list_skills_tool(%__MODULE__{skills: skills}) do
    FunctionTool.new("list_skills",
      description:
        "List all available skills with their names and descriptions. " <>
          "Use this first to discover what skills are available.",
      func: fn _args ->
        entries =
          skills
          |> Enum.sort_by(fn {name, _} -> name end)
          |> Enum.map(fn {name, skill} ->
            desc = skill.description || "(no description)"
            "- **#{name}**: #{desc}"
          end)
          |> Enum.join("\n")

        {:ok, entries}
      end,
      parameters: %{"type" => "object", "properties" => %{}}
    )
  end

  defp load_skill_tool(%__MODULE__{skills: skills}) do
    FunctionTool.new("load_skill",
      description:
        "Load the full instructions for a skill by name. " <>
          "Call list_skills first to see available names.",
      func: fn args ->
        name = Map.get(args, "name", "")

        case Map.fetch(skills, name) do
          {:ok, skill} -> {:ok, skill.instruction}
          :error -> {:error, "Unknown skill: #{inspect(name)}"}
        end
      end,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Skill name"}
        },
        "required" => ["name"]
      }
    )
  end

  defp load_skill_resource_tool(%__MODULE__{skills: skills}) do
    FunctionTool.new("load_skill_resource",
      description:
        "Read a resource file from a skill's references/ directory. " <>
          "Useful for loading examples, templates, or reference data.",
      func: fn args ->
        name = Map.get(args, "name", "")
        path = Map.get(args, "path", "")

        with {:ok, skill} <-
               Map.fetch(skills, name) |> ok_or_error("Unknown skill: #{inspect(name)}"),
             :ok <- validate_path(path),
             full_path <- Path.join([skill.dir, "references", path]),
             {:ok, content} <- File.read(full_path) |> wrap_file_error(full_path) do
          {:ok, content}
        end
      end,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Skill name"},
          "path" => %{"type" => "string", "description" => "Relative path within references/"}
        },
        "required" => ["name", "path"]
      }
    )
  end

  defp ok_or_error({:ok, val}, _msg), do: {:ok, val}
  defp ok_or_error(:error, msg), do: {:error, msg}

  defp validate_path(path) do
    if String.contains?(path, "..") do
      {:error, "Path traversal not allowed"}
    else
      :ok
    end
  end

  defp wrap_file_error({:ok, content}, _path), do: {:ok, content}
  defp wrap_file_error({:error, reason}, path), do: {:error, "Cannot read #{path}: #{reason}"}
end
