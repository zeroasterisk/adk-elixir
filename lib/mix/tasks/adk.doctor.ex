defmodule Mix.Tasks.Adk.Doctor do
  @moduledoc """
  Validates your environment for ADK Elixir development.

  Checks Elixir/OTP versions, API keys, dependencies, and agent modules
  to help diagnose common setup issues.

  ## Usage

      mix adk.doctor
      mix adk.doctor --verbose
      mix adk.doctor --json

  ## Options

    * `--verbose` — Show additional detail for each check
    * `--json` — Output results as JSON (for CI/tooling)

  ## Checks

    * Elixir version (>= 1.15 required, >= 1.16 recommended)
    * OTP version (>= 25 required, >= 26 recommended)
    * GEMINI_API_KEY / GOOGLE_API_KEY environment variables
    * ADK dependency present in project
    * Optional dependencies (Phoenix/Plug, Protobuf)
    * Agent modules implementing ADK.Agent behaviour
  """
  @shortdoc "Validates your ADK development environment"

  use Mix.Task

  @switches [verbose: :boolean, json: :boolean]

  @elixir_min {1, 15, 0}
  @elixir_rec {1, 16, 0}
  @otp_min 25
  @otp_rec 26

  @impl true
  def run(args) do
    {opts, _argv, _} = OptionParser.parse(args, strict: @switches)

    results = run_checks(opts)

    if opts[:json] do
      print_json(results)
    else
      print_human(results, opts)
    end

    failed = Enum.count(results, &(&1.status == :fail))

    if failed > 0 do
      Mix.raise("#{failed} check(s) failed. See above for details.")
    end
  end

  @doc false
  def run_checks(opts \\ []) do
    [
      check_elixir_version(opts),
      check_otp_version(opts),
      check_env("GEMINI_API_KEY", required: true),
      check_env("GOOGLE_API_KEY", required: false),
      check_dep(:adk, required: true),
      check_dep(:phoenix, required: false, label: "Phoenix/Plug (web UI)"),
      check_dep(:protobuf, required: false, label: "Protobuf (gRPC features)"),
      check_agents(opts)
    ]
  end

  # -- Individual checks --

  defp check_elixir_version(_opts) do
    raw = System.version()
    current = Version.parse!(raw)
    current_tuple = {current.major, current.minor, current.patch}

    cond do
      current_tuple < @elixir_min ->
        %{
          group: :environment,
          name: "Elixir version",
          status: :fail,
          message: "Elixir #{raw} (>= #{format_vsn(@elixir_min)} required)"
        }

      current_tuple < @elixir_rec ->
        %{
          group: :environment,
          name: "Elixir version",
          status: :warn,
          message: "Elixir #{raw} (>= #{format_vsn(@elixir_rec)} recommended)"
        }

      true ->
        %{
          group: :environment,
          name: "Elixir version",
          status: :pass,
          message: "Elixir #{raw} (>= #{format_vsn(@elixir_min)} required)"
        }
    end
  end

  defp check_otp_version(_opts) do
    raw = :erlang.system_info(:otp_release) |> List.to_string()
    version = String.to_integer(raw)

    cond do
      version < @otp_min ->
        %{
          group: :environment,
          name: "OTP version",
          status: :fail,
          message: "OTP #{raw} (>= #{@otp_min} required)"
        }

      version < @otp_rec ->
        %{
          group: :environment,
          name: "OTP version",
          status: :warn,
          message: "OTP #{raw} (>= #{@otp_rec} recommended)"
        }

      true ->
        %{
          group: :environment,
          name: "OTP version",
          status: :pass,
          message: "OTP #{raw} (>= #{@otp_min} required)"
        }
    end
  end

  defp check_env(var, opts) do
    required? = Keyword.get(opts, :required, false)

    case System.get_env(var) do
      nil when required? ->
        %{
          group: :api_keys,
          name: var,
          status: :fail,
          message: "#{var} is not set"
        }

      nil ->
        %{
          group: :api_keys,
          name: var,
          status: :optional,
          message: "#{var} is not set (optional)"
        }

      _value ->
        %{
          group: :api_keys,
          name: var,
          status: :pass,
          message: "#{var} is set"
        }
    end
  end

  defp check_dep(dep, opts) do
    required? = Keyword.get(opts, :required, false)
    label = Keyword.get(opts, :label, Atom.to_string(dep))

    deps =
      try do
        Mix.Project.deps_paths()
      rescue
        _ -> %{}
      end

    if Map.has_key?(deps, dep) do
      %{
        group: :dependencies,
        name: label,
        status: :pass,
        message: ":#{dep} dependency found"
      }
    else
      if required? do
        %{
          group: :dependencies,
          name: label,
          status: :fail,
          message: ":#{dep} dependency not found"
        }
      else
        %{
          group: :dependencies,
          name: label,
          status: :optional,
          message: ":#{dep} not found (#{label} unavailable)"
        }
      end
    end
  end

  defp check_agents(_opts) do
    agents = find_agent_modules()

    case agents do
      [] ->
        %{
          group: :agents,
          name: "Agent modules",
          status: :warn,
          message: "No agent modules found implementing ADK.Agent"
        }

      modules ->
        names = modules |> Enum.map(&inspect/1) |> Enum.join(", ")

        %{
          group: :agents,
          name: "Agent modules",
          status: :pass,
          message: "Found #{length(modules)} agent module(s): #{names}"
        }
    end
  end

  defp find_agent_modules do
    # Ensure the project is compiled so we can introspect modules
    Mix.Task.run("compile", ["--no-warnings"])

    case :application.get_key(Mix.Project.config()[:app], :modules) do
      {:ok, modules} ->
        Enum.filter(modules, fn mod ->
          try do
            behaviours =
              mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

            ADK.Agent in behaviours
          rescue
            _ -> false
          end
        end)

      _ ->
        []
    end
  end

  # -- Output formatting --

  defp print_human(results, _opts) do
    Mix.shell().info("\nADK Doctor")
    Mix.shell().info("==========\n")

    results
    |> Enum.group_by(& &1.group)
    |> Enum.each(fn {group, checks} ->
      Mix.shell().info(group_label(group))

      Enum.each(checks, fn check ->
        Mix.shell().info("  #{status_icon(check.status)} #{check.message}")
      end)

      Mix.shell().info("")
    end)

    passed = Enum.count(results, &(&1.status == :pass))
    failed = Enum.count(results, &(&1.status == :fail))
    warned = Enum.count(results, &(&1.status == :warn))
    optional = Enum.count(results, &(&1.status == :optional))

    summary =
      "Summary: #{passed} passed" <>
        if(failed > 0, do: ", #{failed} failed", else: "") <>
        if(warned > 0, do: ", #{warned} warning(s)", else: "") <>
        if(optional > 0, do: ", #{optional} optional skipped", else: "")

    Mix.shell().info(summary)
  end

  defp print_json(results) do
    data =
      Enum.map(results, fn check ->
        %{
          group: check.group,
          name: check.name,
          status: check.status,
          message: check.message
        }
      end)

    passed = Enum.count(results, &(&1.status == :pass))
    failed = Enum.count(results, &(&1.status == :fail))
    warned = Enum.count(results, &(&1.status == :warn))
    optional = Enum.count(results, &(&1.status == :optional))

    output = %{
      checks: data,
      summary: %{passed: passed, failed: failed, warnings: warned, optional_skipped: optional},
      ok: failed == 0
    }

    Mix.shell().info(Jason.encode!(output, pretty: true))
  end

  defp group_label(:environment), do: "Environment"
  defp group_label(:api_keys), do: "API Keys"
  defp group_label(:dependencies), do: "Dependencies"
  defp group_label(:agents), do: "Agents"
  defp group_label(other), do: to_string(other)

  defp status_icon(:pass), do: "✓"
  defp status_icon(:fail), do: "✗"
  defp status_icon(:warn), do: "!"
  defp status_icon(:optional), do: "○"

  defp format_vsn({major, minor, patch}), do: "#{major}.#{minor}.#{patch}"
end
