defmodule CodeExecutionAgent.Executor do
  @moduledoc """
  Stateful code executor that uses an `Agent` process to maintain variable
  bindings across multiple tool invocations within a session.

  ⚠️  **Safety Warning**: This module executes arbitrary Elixir code via
  `Code.eval_string/3`. It is intended for **local development and demos only**.
  Never expose this to untrusted input in production without sandboxing.

  ## How it works

  1. An `Agent` process stores the current set of bindings (a keyword list).
  2. Each `execute/1` call evaluates the code string with the current bindings.
  3. Any new or updated variables are merged back into the stored bindings.
  4. The evaluated result is returned as a string.

  This gives the LLM a persistent "notebook" where earlier computations
  remain available in later tool calls.
  """

  use Agent

  @doc "Start the executor agent process."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> [] end, name: name)
  end

  @doc """
  Execute an Elixir code string with persisted bindings.

  Returns `{:ok, result_string}` or `{:error, reason}`.
  """
  def execute(code, name \\ __MODULE__) do
    bindings = Agent.get(name, & &1)

    try do
      {result, new_bindings} = Code.eval_string(code, bindings)

      # Merge new bindings back (new vars + updated existing ones)
      Agent.update(name, fn _old -> new_bindings end)

      {:ok, inspect(result, pretty: true, limit: 500)}
    rescue
      e ->
        {:error, "#{Exception.message(e)}"}
    catch
      kind, reason ->
        {:error, "#{kind}: #{inspect(reason)}"}
    end
  end

  @doc "Reset all stored bindings."
  def reset(name \\ __MODULE__) do
    Agent.update(name, fn _ -> [] end)
  end

  @doc "Return the current bindings."
  def bindings(name \\ __MODULE__) do
    Agent.get(name, & &1)
  end

  @doc "Return the ADK FunctionTool definition for code execution."
  def tool do
    ADK.Tool.FunctionTool.new("execute_code",
      description: """
      Execute an Elixir code expression. Variables defined in previous calls
      persist and can be reused. The result of the last expression is returned.
      Use standard Elixir: Enum, Map, String, :math, etc.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "code" => %{
            "type" => "string",
            "description" =>
              "Elixir code to evaluate. The last expression is the return value."
          }
        },
        "required" => ["code"]
      },
      func: fn _ctx, %{"code" => code} ->
        case execute(code) do
          {:ok, result} -> {:ok, %{"result" => result}}
          {:error, reason} -> {:ok, %{"error" => reason}}
        end
      end
    )
  end
end
