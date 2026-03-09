defmodule ADK.Plugin.ReflectRetryIntegrationTest do
  use ExUnit.Case, async: false

  alias ADK.Plugin.ReflectRetry

  setup do
    unless Process.whereis(ADK.SessionSupervisor) do
      start_supervised!({DynamicSupervisor, name: ADK.SessionSupervisor, strategy: :one_for_one})
    end

    unless Process.whereis(ADK.SessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: ADK.SessionRegistry})
    end

    unless Process.whereis(ADK.Plugin.Registry) do
      start_supervised!(ADK.Plugin.Registry)
    end

    :ok
  end

  describe "full plugin pipeline with Registry" do
    test "registered plugin is discoverable" do
      ADK.Plugin.register({ReflectRetry, max_retries: 2})

      plugins = ADK.Plugin.list()
      assert Enum.any?(plugins, fn {mod, _} -> mod == ReflectRetry end)
    end

    test "plugin hooks run through Plugin.run_before/run_after" do
      {:ok, state} = ReflectRetry.init(max_retries: 1)
      plugins = [{ReflectRetry, state}]

      ctx = %ADK.Context{invocation_id: "pipeline-test"}
      good_events = [ADK.Event.new(%{author: "bot", content: %{parts: [%{text: "ok"}]}})]

      # before_run should pass through
      assert {:cont, ^ctx, updated_plugins} = ADK.Plugin.run_before(plugins, ctx)

      # after_run with good events should pass through
      {result, _} = ADK.Plugin.run_after(updated_plugins, good_events, ctx)
      assert result == good_events
    end

    test "plugin retries via run_after when agent fails then recovers" do
      agent = ADK.Agent.Custom.new(
        name: "pipeline_agent",
        run_fn: fn _agent, ctx ->
          if ADK.Context.get_temp(ctx, :reflection_feedback) do
            [ADK.Event.new(%{author: "pipeline_agent", content: %{parts: [%{text: "success"}]}})]
          else
            [ADK.Event.new(%{author: "pipeline_agent", error: "fail"})]
          end
        end
      )

      {:ok, state} = ReflectRetry.init(max_retries: 2)
      plugins = [{ReflectRetry, state}]

      ctx = %ADK.Context{invocation_id: "pipeline-retry", agent: agent}
      error_events = [ADK.Event.new(%{author: "pipeline_agent", error: "fail"})]

      {result, _} = ADK.Plugin.run_after(plugins, error_events, ctx)

      texts = Enum.map(result, &ADK.Event.text/1) |> Enum.filter(& &1)
      assert Enum.any?(texts, &(&1 =~ "success"))
    end

    test "end-to-end: validator-based retry through plugin pipeline" do
      call_count = :counters.new(1, [:atomics])

      agent = ADK.Agent.Custom.new(
        name: "quality_agent",
        run_fn: fn _agent, _ctx ->
          n = :counters.get(call_count, 1) + 1
          :counters.put(call_count, 1, n)

          text =
            if n >= 2,
              do: "The capital of France is Paris.",
              else: "I'm not sure about that."

          [ADK.Event.new(%{author: "quality_agent", content: %{parts: [%{text: text}]}})]
        end
      )

      validator = fn events ->
        text = events |> Enum.map_join(" ", &(ADK.Event.text(&1) || ""))
        if String.contains?(text, "not sure"),
          do: {:error, "Response was uncertain — be definitive"},
          else: :ok
      end

      {:ok, state} = ReflectRetry.init(max_retries: 3, validator: validator)
      plugins = [{ReflectRetry, state}]

      ctx = %ADK.Context{invocation_id: "e2e-val", agent: agent}
      initial = [ADK.Event.new(%{author: "quality_agent", content: %{parts: [%{text: "I'm not sure about that."}]}})]

      {result, _} = ADK.Plugin.run_after(plugins, initial, ctx)

      texts = Enum.map(result, &ADK.Event.text/1) |> Enum.filter(& &1)
      assert Enum.any?(texts, &(&1 =~ "Paris"))
      assert Enum.any?(texts, &(&1 =~ "Reflect & Retry"))
    end
  end
end
