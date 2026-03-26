defmodule ADK.Skill.Deps do
  @moduledoc """
  Checks availability of external dependencies required by skills.

  Skills may declare dependencies on external programs (e.g., `python3`, `jq`)
  via the `deps` field in their SKILL.md frontmatter. This module validates
  whether those programs are available on the system PATH.

  > **Beyond Python ADK:** The Python ADK does not have an equivalent module.
  > This provides graceful degradation when optional skill tools depend on
  > external programs that may not be installed.
  """

  require Logger

  @doc """
  Check which dependencies from a list are available on the system.

  Returns a tuple `{available, missing}` where both are lists of binary names.

  ## Examples

      iex> {avail, _missing} = ADK.Skill.Deps.check(["ls"])
      iex> "ls" in avail
      true

      iex> {_avail, missing} = ADK.Skill.Deps.check(["nonexistent_xyz_123"])
      iex> "nonexistent_xyz_123" in missing
      true
  """
  @spec check([String.t()]) :: {available :: [String.t()], missing :: [String.t()]}
  def check(deps) when is_list(deps) do
    Enum.split_with(deps, &available?/1)
  end

  @doc """
  Check if a single external program is available on the system PATH.

  ## Examples

      iex> ADK.Skill.Deps.available?("ls")
      true

      iex> ADK.Skill.Deps.available?("nonexistent_xyz_123")
      false
  """
  @spec available?(String.t()) :: boolean()
  def available?(name) when is_binary(name) do
    case Process.get({:adk_skill_dep, name}) do
      nil ->
        result = System.find_executable(name) != nil
        Process.put({:adk_skill_dep, name}, result)
        result

      cached ->
        cached
    end
  end

  @doc """
  Check the interpreter required for a given file extension.

  Returns `{:ok, interpreter}` if available, `{:error, interpreter}` if missing.

  ## Examples

      iex> ADK.Skill.Deps.check_interpreter(".sh")
      {:ok, "bash"}
  """
  @spec check_interpreter(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def check_interpreter(ext) do
    interpreter = interpreter_for(ext)

    if interpreter && available?(interpreter) do
      {:ok, interpreter}
    else
      {:error, interpreter || "unknown"}
    end
  end

  @doc false
  @spec interpreter_for(String.t()) :: String.t() | nil
  def interpreter_for(".py"), do: "python3"
  def interpreter_for(".sh"), do: "bash"
  def interpreter_for(".exs"), do: "elixir"
  def interpreter_for(_), do: nil
end
