defmodule ADK.Skill.Steps do
  @moduledoc """
  DSL for declaring skill steps that auto-dagify into workflows.

  Skills declare steps with dependencies. The Harness automatically
  decomposes them into a DAG: independent steps run in parallel,
  dependent steps run sequentially, checkpoints between each node.

  ADK Elixir extension — no Python ADK equivalent exists.

  ## Example

      defmodule MyApp.Skills.Ship do
        use ADK.Skill.Steps

        step :sync, fn ctx -> Git.pull(ctx.repo) end
        step :test, fn ctx -> Mix.test(ctx.repo) end, depends_on: [:sync]
        step :lint, fn ctx -> Mix.lint(ctx.repo) end, depends_on: [:sync]
        step :review, fn ctx -> Review.diff(ctx.repo) end, depends_on: [:test, :lint]
        step :commit, fn ctx -> Git.commit(ctx.repo) end, depends_on: [:review]
        step :push, fn ctx -> Git.push(ctx.repo) end, depends_on: [:commit]
      end

  After compilation, the module has a `__steps__/0` function that returns
  the step definitions, and `to_workflow/0` that compiles them into an
  `ADK.Workflow`-compatible plan.
  """

  @doc """
  A single step definition.
  """
  defstruct [:name, :handler, depends_on: [], opts: []]

  @type t :: %__MODULE__{
          name: atom(),
          handler: (map() -> any()),
          depends_on: [atom()],
          opts: keyword()
        }

  defmacro __using__(_opts) do
    quote do
      import ADK.Skill.Steps, only: [step: 2, step: 3]
      Module.register_attribute(__MODULE__, :__steps__, accumulate: true)
      @before_compile ADK.Skill.Steps
    end
  end

  @doc """
  Declare a step with a name and handler function.

  ## Options

    * `:depends_on` — list of step names this step depends on (default: `[]`)
    * `:requires_approval` — whether to pause for human approval (default: `false`)
    * `:timeout` — step timeout in ms
  """
  defmacro step(name, handler, opts \\ []) do
    quote do
      @__steps__ %ADK.Skill.Steps{
        name: unquote(name),
        handler: unquote(handler),
        depends_on: unquote(opts[:depends_on] || []),
        opts: unquote(Macro.escape(Keyword.drop(opts, [:depends_on])))
      }
    end
  end

  defmacro __before_compile__(env) do
    steps = Module.get_attribute(env.module, :__steps__) |> Enum.reverse()

    quote do
      @doc "Returns all step definitions in declaration order."
      @spec __steps__() :: [ADK.Skill.Steps.t()]
      def __steps__, do: unquote(Macro.escape(steps))

      @doc "Compile steps into a workflow plan (JSON-compatible map)."
      @spec to_plan() :: map()
      def to_plan do
        ADK.Skill.Steps.compile_plan(__steps__())
      end
    end
  end

  @doc """
  Compile a list of step definitions into a plan map compatible with
  `ADK.Workflow.from_plan/1`.

  ## Examples

      iex> steps = [
      ...>   %ADK.Skill.Steps{name: :a, handler: fn _ -> :ok end, depends_on: []},
      ...>   %ADK.Skill.Steps{name: :b, handler: fn _ -> :ok end, depends_on: [:a]}
      ...> ]
      iex> plan = ADK.Skill.Steps.compile_plan(steps)
      iex> length(plan["steps"])
      2
  """
  @spec compile_plan([t()]) :: map()
  def compile_plan(steps) do
    plan_steps =
      Enum.map(steps, fn step ->
        base = %{
          "id" => Atom.to_string(step.name),
          "action" => "execute"
        }

        base =
          if step.depends_on != [] do
            Map.put(base, "depends_on", Enum.map(step.depends_on, &Atom.to_string/1))
          else
            base
          end

        if step.opts[:requires_approval] do
          Map.put(base, "requires_approval", true)
        else
          base
        end
      end)

    %{"steps" => plan_steps}
  end

  @doc """
  Validate step definitions: check for cycles, undefined dependencies,
  and duplicate names.

  Returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> steps = [%ADK.Skill.Steps{name: :a, handler: fn _ -> :ok end, depends_on: [:b]}]
      iex> ADK.Skill.Steps.validate(steps)
      {:error, "Step :a depends on undefined step: :b"}
  """
  @spec validate([t()]) :: :ok | {:error, String.t()}
  def validate(steps) do
    names = MapSet.new(steps, & &1.name)

    with :ok <- check_duplicates(steps),
         :ok <- check_undefined_deps(steps, names),
         :ok <- check_cycles(steps) do
      :ok
    end
  end

  defp check_duplicates(steps) do
    names = Enum.map(steps, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> {:error, "Duplicate step name: #{inspect(dup)}"}
    end
  end

  defp check_undefined_deps(steps, names) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      undefined = Enum.find(step.depends_on, &(not MapSet.member?(names, &1)))

      if undefined do
        {:halt,
         {:error, "Step #{inspect(step.name)} depends on undefined step: #{inspect(undefined)}"}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp check_cycles(steps) do
    graph = Map.new(steps, &{&1.name, &1.depends_on})

    Enum.reduce_while(steps, :ok, fn step, :ok ->
      if has_cycle?(step.name, graph, MapSet.new()) do
        {:halt, {:error, "Cycle detected involving step: #{inspect(step.name)}"}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp has_cycle?(node, graph, visited) do
    if MapSet.member?(visited, node) do
      true
    else
      visited = MapSet.put(visited, node)
      deps = Map.get(graph, node, [])
      Enum.any?(deps, &has_cycle?(&1, graph, visited))
    end
  end
end
