defmodule ADK.Plugin.ModelToolHooksTest do
  @moduledoc """
  Tests for the plugin model/tool/event hooks:
  before_model, after_model, before_tool, after_tool, on_event.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  # We store the test log agent pid in ctx.temp_state[:log_pid] to thread it
  # through the stateless plugin hooks without adding fields to ADK.Context.

  # ---------------------------------------------------------------------------
  # Test plugins — all use ctx.temp_state[:log_pid] for recording
  # ---------------------------------------------------------------------------

  defmodule RecordingPlugin do
    @moduledoc "Records all hook calls into an Agent for inspection."
    @behaviour ADK.Plugin

    @impl true
    def init(pid), do: {:ok, pid}

    @impl true
    def before_run(context, pid) do
      if pid, do: Agent.update(pid, &[{:before_run, context.invocation_id} | &1])
      {:cont, context, pid}
    end

    @impl true
    def after_run(events, context, pid) do
      if pid, do: Agent.update(pid, &[{:after_run, context.invocation_id, length(events)} | &1])
      {events, pid}
    end

    @impl true
    def before_model(context, request) do
      if pid = context.temp_state[:log_pid] do
        Agent.update(pid, &[{:before_model, request[:model]} | &1])
      end

      {:ok, request}
    end

    @impl true
    def after_model(context, response) do
      if pid = context.temp_state[:log_pid] do
        Agent.update(pid, &[{:after_model, elem(response, 0)} | &1])
      end

      response
    end

    @impl true
    def before_tool(context, tool_name, args) do
      if pid = context.temp_state[:log_pid] do
        Agent.update(pid, &[{:before_tool, tool_name, args} | &1])
      end

      {:ok, args}
    end

    @impl true
    def after_tool(context, tool_name, result) do
      if pid = context.temp_state[:log_pid] do
        Agent.update(pid, &[{:after_tool, tool_name, elem(result, 0)} | &1])
      end

      result
    end

    @impl true
    def on_event(context, event) do
      if pid = context.temp_state[:log_pid] do
        Agent.update(pid, &[{:on_event, event.author} | &1])
      end

      :ok
    end
  end

  defmodule ModifyRequestPlugin do
    @moduledoc "Modifies the model request in before_model."
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def before_model(_context, request) do
      {:ok, Map.put(request, :injected, true)}
    end

    @impl true
    def after_model(_context, response), do: response
  end

  defmodule SkipModelPlugin do
    @moduledoc "Short-circuits the model call with a canned response."
    @behaviour ADK.Plugin

    @impl true
    def init(_config), do: {:ok, nil}

    @impl true
    def before_model(_context, _request) do
      {:skip, {:ok, %{content: %{parts: [%{text: "skipped by plugin"}]}}}}
    end
  end

  defmodule ModifyArgsPlugin do
    @moduledoc "Modifies tool args in before_tool."
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def before_tool(_context, _tool_name, args) do
      {:ok, Map.put(args, "injected", "yes")}
    end

    @impl true
    def after_tool(_context, _tool_name, result), do: result
  end

  defmodule SkipToolPlugin do
    @moduledoc "Short-circuits a tool call."
    @behaviour ADK.Plugin

    @impl true
    def init(_config), do: {:ok, nil}

    @impl true
    def before_tool(_context, tool_name, _args) do
      {:skip, {:ok, "tool #{tool_name} was skipped"}}
    end
  end

  defmodule TransformResultPlugin do
    @moduledoc "Transforms tool results in after_tool."
    @behaviour ADK.Plugin

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def after_tool(_context, _tool_name, {:ok, result}) do
      {:ok, "transformed: #{result}"}
    end

    def after_tool(_context, _tool_name, result), do: result
  end

  defmodule EventCollectorPlugin do
    @moduledoc "Collects event authors via on_event using ctx.temp_state[:log_pid]."
    @behaviour ADK.Plugin

    @impl true
    def init(_config), do: {:ok, nil}

    @impl true
    def on_event(context, event) do
      if pid = context.temp_state[:log_pid] do
        Agent.update(pid, &[{:event, event.author} | &1])
      end

      :ok
    end
  end

  defmodule NoHooksPlugin do
    @moduledoc "Plugin with no optional hooks — verifies backward compat."
    @behaviour ADK.Plugin

    @impl true
    def init(_config), do: {:ok, %{}}
  end

  defmodule DoubleModifyA do
    @behaviour ADK.Plugin
    @impl true
    def init(_), do: {:ok, nil}
    @impl true
    def before_model(_ctx, req), do: {:ok, Map.put(req, :from_a, true)}
  end

  defmodule DoubleModifyB do
    @behaviour ADK.Plugin
    @impl true
    def init(_), do: {:ok, nil}
    @impl true
    def before_model(_ctx, req), do: {:ok, Map.put(req, :from_b, true)}
  end

  defmodule AppendPlugin do
    @behaviour ADK.Plugin
    @impl true
    def init(_), do: {:ok, nil}
    @impl true
    def after_tool(_ctx, _name, {:ok, v}), do: {:ok, "#{v}!"}
    def after_tool(_ctx, _name, r), do: r
  end

  defmodule CounterPlugin do
    @behaviour ADK.Plugin
    @impl true
    def init(pid), do: {:ok, pid}
    @impl true
    def on_event(ctx, _event) do
      pid = ctx.temp_state[:counter_a] || ctx.temp_state[:counter_b]
      if pid, do: Agent.update(pid, &(&1 + 1))
      :ok
    end
  end

  defmodule OrderPluginA do
    @behaviour ADK.Plugin
    @impl true
    def init(pid), do: {:ok, pid}
    @impl true
    def before_model(ctx, request) do
      if pid = ctx.temp_state[:log_pid] do
        Agent.update(pid, &[:a | &1])
      end

      {:ok, request}
    end

    @impl true
    def after_model(_ctx, resp), do: resp
  end

  defmodule OrderPluginB do
    @behaviour ADK.Plugin
    @impl true
    def init(pid), do: {:ok, pid}
    @impl true
    def before_model(ctx, request) do
      if pid = ctx.temp_state[:log_pid] do
        Agent.update(pid, &[:b | &1])
      end

      {:ok, request}
    end

    @impl true
    def after_model(_ctx, resp), do: resp
  end

  # ---------------------------------------------------------------------------
  # ADK.Plugin helper function tests
  # ---------------------------------------------------------------------------

  describe "run_before_model/3" do
    test "returns {:ok, request} when no plugins implement before_model" do
      plugins = [{NoHooksPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      request = %{model: "test", messages: []}

      assert {:ok, ^request} = ADK.Plugin.run_before_model(plugins, ctx, request)
    end

    test "passes request through multiple plugins" do
      plugins = [{ModifyRequestPlugin, %{}}, {ModifyRequestPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      request = %{model: "test", messages: []}

      assert {:ok, result} = ADK.Plugin.run_before_model(plugins, ctx, request)
      assert result.injected == true
    end

    test "returns {:skip, response} when a plugin short-circuits" do
      plugins = [{SkipModelPlugin, nil}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      request = %{model: "test", messages: []}

      assert {:skip, {:ok, %{content: %{parts: [%{text: "skipped by plugin"}]}}}} =
               ADK.Plugin.run_before_model(plugins, ctx, request)
    end

    test "stops processing after first skip" do
      # SkipModelPlugin first, then ModifyRequestPlugin — modify should NOT fire
      plugins = [
        {SkipModelPlugin, nil},
        {ModifyRequestPlugin, %{}}
      ]

      ctx = %ADK.Context{invocation_id: "inv-1"}
      request = %{model: "test", messages: []}

      assert {:skip, _} = ADK.Plugin.run_before_model(plugins, ctx, request)
    end

    test "empty plugins list returns original request" do
      ctx = %ADK.Context{invocation_id: "inv-1"}
      request = %{model: "gemini-pro", messages: []}

      assert {:ok, ^request} = ADK.Plugin.run_before_model([], ctx, request)
    end

    test "plugin can modify request and pass it to next plugin" do
      plugins = [{DoubleModifyA, nil}, {DoubleModifyB, nil}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      request = %{model: "test"}

      assert {:ok, result} = ADK.Plugin.run_before_model(plugins, ctx, request)
      assert result.from_a == true
      assert result.from_b == true
    end
  end

  describe "run_after_model/3" do
    test "returns response unchanged when no plugins implement after_model" do
      plugins = [{NoHooksPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      response = {:ok, %{content: %{parts: [%{text: "hello"}]}}}

      assert ^response = ADK.Plugin.run_after_model(plugins, ctx, response)
    end

    test "passes response through plugins" do
      plugins = [{ModifyRequestPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      response = {:ok, %{content: %{parts: [%{text: "hello"}]}}}

      # ModifyRequestPlugin.after_model just passes through
      assert ^response = ADK.Plugin.run_after_model(plugins, ctx, response)
    end

    test "records after_model calls via RecordingPlugin" do
      {:ok, log_agent} = Agent.start_link(fn -> [] end)

      plugins = [{RecordingPlugin, nil}]
      ctx = %ADK.Context{invocation_id: "inv-1", temp_state: %{log_pid: log_agent}}
      response = {:ok, %{content: %{parts: [%{text: "hello"}]}}}

      ADK.Plugin.run_after_model(plugins, ctx, response)

      calls = Agent.get(log_agent, & &1)
      assert {:after_model, :ok} in calls

      Agent.stop(log_agent)
    end

    test "empty plugins list returns original response" do
      ctx = %ADK.Context{invocation_id: "inv-1"}
      response = {:ok, %{content: %{parts: [%{text: "unchanged"}]}}}

      assert ^response = ADK.Plugin.run_after_model([], ctx, response)
    end
  end

  describe "run_before_tool/4" do
    test "returns {:ok, args} when no plugins implement before_tool" do
      plugins = [{NoHooksPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      args = %{"input" => "hello"}

      assert {:ok, ^args} = ADK.Plugin.run_before_tool(plugins, ctx, "my_tool", args)
    end

    test "modifies args through plugin" do
      plugins = [{ModifyArgsPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      args = %{"input" => "hello"}

      assert {:ok, new_args} = ADK.Plugin.run_before_tool(plugins, ctx, "my_tool", args)
      assert new_args["injected"] == "yes"
      assert new_args["input"] == "hello"
    end

    test "returns {:skip, result} when plugin short-circuits" do
      plugins = [{SkipToolPlugin, nil}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      args = %{"input" => "hello"}

      assert {:skip, {:ok, "tool my_tool was skipped"}} =
               ADK.Plugin.run_before_tool(plugins, ctx, "my_tool", args)
    end

    test "stops after first skip" do
      plugins = [
        {SkipToolPlugin, nil},
        {ModifyArgsPlugin, %{}}
      ]

      ctx = %ADK.Context{invocation_id: "inv-1"}
      args = %{"input" => "hello"}

      assert {:skip, _} = ADK.Plugin.run_before_tool(plugins, ctx, "my_tool", args)
    end

    test "empty plugins list returns original args" do
      ctx = %ADK.Context{invocation_id: "inv-1"}
      args = %{"q" => "search query"}

      assert {:ok, ^args} = ADK.Plugin.run_before_tool([], ctx, "search", args)
    end

    test "records before_tool calls via RecordingPlugin" do
      {:ok, log_agent} = Agent.start_link(fn -> [] end)

      plugins = [{RecordingPlugin, nil}]
      ctx = %ADK.Context{invocation_id: "inv-1", temp_state: %{log_pid: log_agent}}
      args = %{"q" => "test"}

      ADK.Plugin.run_before_tool(plugins, ctx, "search", args)

      calls = Agent.get(log_agent, & &1)
      assert {:before_tool, "search", args} in calls

      Agent.stop(log_agent)
    end
  end

  describe "run_after_tool/4" do
    test "returns result unchanged when no plugins implement after_tool" do
      plugins = [{NoHooksPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      result = {:ok, "tool result"}

      assert ^result = ADK.Plugin.run_after_tool(plugins, ctx, "my_tool", result)
    end

    test "transforms result through plugin" do
      plugins = [{TransformResultPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      result = {:ok, "raw"}

      assert {:ok, "transformed: raw"} =
               ADK.Plugin.run_after_tool(plugins, ctx, "my_tool", result)
    end

    test "chains multiple after_tool plugins" do
      plugins = [{TransformResultPlugin, %{}}, {NoHooksPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      result = {:ok, "original"}

      assert {:ok, "transformed: original"} =
               ADK.Plugin.run_after_tool(plugins, ctx, "my_tool", result)
    end

    test "passes errors through when plugin doesn't match" do
      plugins = [{TransformResultPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      result = {:error, "something broke"}

      assert {:error, "something broke"} =
               ADK.Plugin.run_after_tool(plugins, ctx, "my_tool", result)
    end
  end

  describe "run_on_event/3" do
    test "calls on_event for each plugin that implements it" do
      {:ok, log_agent} = Agent.start_link(fn -> [] end)

      ctx = %ADK.Context{invocation_id: "inv-1", temp_state: %{log_pid: log_agent}}

      event =
        ADK.Event.new(%{
          author: "bot",
          invocation_id: "inv-1",
          content: %{parts: [%{text: "hi"}]}
        })

      plugins = [{EventCollectorPlugin, nil}]
      assert :ok = ADK.Plugin.run_on_event(plugins, ctx, event)

      calls = Agent.get(log_agent, & &1)
      assert {:event, "bot"} in calls

      Agent.stop(log_agent)
    end

    test "skips plugins that don't implement on_event" do
      plugins = [{NoHooksPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-1"}
      event = ADK.Event.new(%{author: "bot", invocation_id: "inv-1"})

      assert :ok = ADK.Plugin.run_on_event(plugins, ctx, event)
    end

    test "always returns :ok even with multiple plugins" do
      {:ok, log_agent} = Agent.start_link(fn -> [] end)
      ctx = %ADK.Context{invocation_id: "inv-1", temp_state: %{log_pid: log_agent}}
      event = ADK.Event.new(%{author: "bot", invocation_id: "inv-1"})

      plugins = [{EventCollectorPlugin, nil}, {NoHooksPlugin, %{}}, {EventCollectorPlugin, nil}]
      assert :ok = ADK.Plugin.run_on_event(plugins, ctx, event)

      calls = Agent.get(log_agent, & &1)

      event_calls =
        Enum.filter(calls, fn
          {:event, _} -> true
          _ -> false
        end)

      # Called twice (two EventCollectorPlugin instances)
      assert length(event_calls) == 2

      Agent.stop(log_agent)
    end

    test "empty plugins list returns :ok" do
      ctx = %ADK.Context{invocation_id: "inv-1"}
      event = ADK.Event.new(%{author: "bot", invocation_id: "inv-1"})
      assert :ok = ADK.Plugin.run_on_event([], ctx, event)
    end
  end

  # ---------------------------------------------------------------------------
  # ADK.Context.emit_event fires plugin on_event hooks
  # ---------------------------------------------------------------------------

  describe "Context.emit_event/2 fires plugin on_event hooks" do
    test "fires on_event for all plugins in context.plugins" do
      {:ok, log_agent} = Agent.start_link(fn -> [] end)

      ctx = %ADK.Context{
        invocation_id: "inv-emit-1",
        temp_state: %{log_pid: log_agent},
        plugins: [{EventCollectorPlugin, nil}]
      }

      event =
        ADK.Event.new(%{
          author: "agent",
          invocation_id: "inv-emit-1",
          content: %{parts: [%{text: "hello"}]}
        })

      ADK.Context.emit_event(ctx, event)

      calls = Agent.get(log_agent, & &1)
      assert {:event, "agent"} in calls

      Agent.stop(log_agent)
    end

    test "no error when plugins is empty" do
      ctx = %ADK.Context{invocation_id: "inv-emit-2", plugins: []}
      event = ADK.Event.new(%{author: "agent", invocation_id: "inv-emit-2"})
      assert :ok = ADK.Context.emit_event(ctx, event)
    end

    test "deduplicates events (same id fires hooks only once)" do
      {:ok, log_agent} = Agent.start_link(fn -> [] end)

      ctx = %ADK.Context{
        invocation_id: "inv-emit-3",
        temp_state: %{log_pid: log_agent},
        plugins: [{EventCollectorPlugin, nil}]
      }

      event =
        ADK.Event.new(%{
          author: "agent",
          invocation_id: "inv-emit-3",
          content: %{parts: [%{text: "hi"}]}
        })

      ADK.Context.emit_event(ctx, event)
      ADK.Context.emit_event(ctx, event)

      calls = Agent.get(log_agent, & &1)

      event_calls =
        Enum.filter(calls, fn
          {:event, _} -> true
          _ -> false
        end)

      assert length(event_calls) == 1

      Agent.stop(log_agent)
    end

    test "also fires on_event streaming callback and plugin hook together" do
      {:ok, log_agent} = Agent.start_link(fn -> [] end)

      streaming_called = :ets.new(:streaming_called, [:set, :public])
      on_event_fn = fn _event -> :ets.insert(streaming_called, {:called, true}) end

      ctx = %ADK.Context{
        invocation_id: "inv-emit-4",
        on_event: on_event_fn,
        temp_state: %{log_pid: log_agent},
        plugins: [{EventCollectorPlugin, nil}]
      }

      event = ADK.Event.new(%{author: "agent", invocation_id: "inv-emit-4"})
      ADK.Context.emit_event(ctx, event)

      assert :ets.lookup(streaming_called, :called) == [{:called, true}]
      calls = Agent.get(log_agent, & &1)
      assert {:event, "agent"} in calls

      :ets.delete(streaming_called)
      Agent.stop(log_agent)
    end
  end

  # ---------------------------------------------------------------------------
  # ADK.Plugin.Logging — new hooks
  # ---------------------------------------------------------------------------

  describe "ADK.Plugin.Logging new hooks" do
    test "init includes log_model_calls and log_tool_calls fields" do
      assert {:ok, state} = ADK.Plugin.Logging.init(log_model_calls: true, log_tool_calls: true)
      assert state.log_model_calls == true
      assert state.log_tool_calls == true
    end

    test "init defaults log_model_calls and log_tool_calls to false" do
      assert {:ok, state} = ADK.Plugin.Logging.init([])
      assert state.log_model_calls == false
      assert state.log_tool_calls == false
    end

    test "before_model logs when log_model_calls is true (via process dict)" do
      {:ok, state} = ADK.Plugin.Logging.init(level: :debug, log_model_calls: true)
      ctx = %ADK.Context{invocation_id: "inv-log-1", agent: %{name: "test_agent"}}

      # Simulate before_run storing config in process dict
      {:cont, _, _state} = ADK.Plugin.Logging.before_run(ctx, state)

      ctx2 = %ADK.Context{invocation_id: "inv-log-1"}
      request = %{model: "gemini-pro"}

      log =
        capture_log(fn ->
          assert {:ok, ^request} = ADK.Plugin.Logging.before_model(ctx2, request)
        end)

      assert log =~ "model call start"
      assert log =~ "gemini-pro"
    end

    test "before_model is silent when log_model_calls is false (default)" do
      {:ok, state} = ADK.Plugin.Logging.init([])
      ctx = %ADK.Context{invocation_id: "inv-log-2", agent: %{name: "test_agent"}}

      {:cont, _, _state} = ADK.Plugin.Logging.before_run(ctx, state)

      ctx2 = %ADK.Context{invocation_id: "inv-log-2"}
      request = %{model: "gemini-pro"}

      log =
        capture_log(fn ->
          assert {:ok, ^request} = ADK.Plugin.Logging.before_model(ctx2, request)
        end)

      refute log =~ "model call start"
    end

    test "before_tool logs when log_tool_calls is true" do
      {:ok, state} = ADK.Plugin.Logging.init(level: :debug, log_tool_calls: true)
      ctx = %ADK.Context{invocation_id: "inv-log-3", agent: %{name: "test_agent"}}

      {:cont, _, _state} = ADK.Plugin.Logging.before_run(ctx, state)

      ctx2 = %ADK.Context{invocation_id: "inv-log-3"}
      args = %{"q" => "search"}

      log =
        capture_log(fn ->
          assert {:ok, ^args} = ADK.Plugin.Logging.before_tool(ctx2, "search_tool", args)
        end)

      assert log =~ "tool call start"
      assert log =~ "search_tool"
    end

    test "after_model logs when log_model_calls is true" do
      {:ok, state} = ADK.Plugin.Logging.init(level: :debug, log_model_calls: true)
      ctx = %ADK.Context{invocation_id: "inv-log-4", agent: %{name: "test_agent"}}

      {:cont, _, _state} = ADK.Plugin.Logging.before_run(ctx, state)

      ctx2 = %ADK.Context{invocation_id: "inv-log-4"}
      response = {:ok, %{content: %{parts: [%{text: "hi"}]}}}

      log =
        capture_log(fn ->
          assert ^response = ADK.Plugin.Logging.after_model(ctx2, response)
        end)

      assert log =~ "model call end"
    end

    test "after_tool logs when log_tool_calls is true" do
      {:ok, state} = ADK.Plugin.Logging.init(level: :debug, log_tool_calls: true)
      ctx = %ADK.Context{invocation_id: "inv-log-5", agent: %{name: "test_agent"}}

      {:cont, _, _state} = ADK.Plugin.Logging.before_run(ctx, state)

      ctx2 = %ADK.Context{invocation_id: "inv-log-5"}
      result = {:ok, "tool output"}

      log =
        capture_log(fn ->
          assert ^result = ADK.Plugin.Logging.after_tool(ctx2, "my_tool", result)
        end)

      assert log =~ "tool call end"
    end

    test "on_event logs when include_events is true" do
      {:ok, state} = ADK.Plugin.Logging.init(level: :debug, include_events: true)
      ctx = %ADK.Context{invocation_id: "inv-log-6", agent: %{name: "test_agent"}}

      {:cont, _, _state} = ADK.Plugin.Logging.before_run(ctx, state)

      ctx2 = %ADK.Context{invocation_id: "inv-log-6", agent: %{name: "test_agent"}}
      event = ADK.Event.new(%{author: "agent", invocation_id: "inv-log-6"})

      log =
        capture_log(fn ->
          assert :ok = ADK.Plugin.Logging.on_event(ctx2, event)
        end)

      assert log =~ "event"
      assert log =~ "agent"
    end

    test "on_event is silent when include_events is false (default)" do
      {:ok, state} = ADK.Plugin.Logging.init([])
      ctx = %ADK.Context{invocation_id: "inv-log-7", agent: %{name: "test_agent"}}

      {:cont, _, _state} = ADK.Plugin.Logging.before_run(ctx, state)

      ctx2 = %ADK.Context{invocation_id: "inv-log-7"}
      event = ADK.Event.new(%{author: "agent", invocation_id: "inv-log-7"})

      log =
        capture_log(fn ->
          assert :ok = ADK.Plugin.Logging.on_event(ctx2, event)
        end)

      refute log =~ "event agent="
    end

    test "after_run cleans up process dict" do
      {:ok, state} = ADK.Plugin.Logging.init(log_model_calls: true)
      ctx = %ADK.Context{invocation_id: "inv-log-8", agent: %{name: "agent"}}

      {:cont, _, state} = ADK.Plugin.Logging.before_run(ctx, state)

      # Verify config is in process dict
      assert Process.get({ADK.Plugin.Logging, :config}) != nil

      {_, _} = ADK.Plugin.Logging.after_run([], ctx, state)

      # after_run should clean up
      assert Process.get({ADK.Plugin.Logging, :config}) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Backward compatibility — plugins without new hooks still work
  # ---------------------------------------------------------------------------

  describe "backward compatibility" do
    test "plugin without model/tool/event hooks still works" do
      plugins = [{NoHooksPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-bc-1"}
      request = %{model: "test"}
      args = %{"input" => "x"}
      result = {:ok, "done"}
      event = ADK.Event.new(%{author: "bot", invocation_id: "inv-bc-1"})

      assert {:ok, ^request} = ADK.Plugin.run_before_model(plugins, ctx, request)
      assert ^result = ADK.Plugin.run_after_model(plugins, ctx, result)
      assert {:ok, ^args} = ADK.Plugin.run_before_tool(plugins, ctx, "tool", args)
      assert ^result = ADK.Plugin.run_after_tool(plugins, ctx, "tool", result)
      assert :ok = ADK.Plugin.run_on_event(plugins, ctx, event)
    end

    test "RateLimit plugin still works unchanged" do
      {:ok, state} = ADK.Plugin.RateLimit.init(limit: 5, window_ms: 60_000)
      ctx = %ADK.Context{invocation_id: "inv-bc-2", agent: %{name: "bot"}}

      assert {:cont, ^ctx, _state} = ADK.Plugin.RateLimit.before_run(ctx, state)
    end

    test "Cache plugin still works unchanged" do
      {:ok, state} = ADK.Plugin.Cache.init(ttl_ms: 5_000)
      ctx = %ADK.Context{invocation_id: "inv-bc-3", user_content: %{parts: [%{text: "hello"}]}}

      assert {:cont, ^ctx, _state} = ADK.Plugin.Cache.before_run(ctx, state)
    end

    test "Logging before_run / after_run still work unchanged" do
      {:ok, state} = ADK.Plugin.Logging.init([])
      ctx = %ADK.Context{invocation_id: "inv-bc-4", agent: %{name: "agent"}}
      events = [ADK.Event.new(%{author: "a", content: %{parts: [%{text: "ok"}]}})]

      assert {:cont, _, new_state} = ADK.Plugin.Logging.before_run(ctx, state)
      assert {^events, _} = ADK.Plugin.Logging.after_run(events, ctx, new_state)
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: plugin skip and modify in composed scenarios
  # ---------------------------------------------------------------------------

  describe "plugin hooks compose correctly" do
    test "multiple plugins run before_model in registration order" do
      {:ok, log_agent} = Agent.start_link(fn -> [] end)

      plugins = [{OrderPluginA, nil}, {OrderPluginB, nil}]
      ctx = %ADK.Context{invocation_id: "inv-order-1", temp_state: %{log_pid: log_agent}}
      request = %{model: "test"}

      ADK.Plugin.run_before_model(plugins, ctx, request)

      calls = Agent.get(log_agent, & &1)
      # List is prepended, so reversed; first plugin prepended :a, second prepended :b
      # calls = [:b, :a] since :b was added last
      assert calls == [:b, :a]

      Agent.stop(log_agent)
    end

    test "before_model skip takes priority over request modification" do
      # SkipModelPlugin fires first and returns {:skip, ...}
      # ModifyRequestPlugin never gets called
      plugins = [{SkipModelPlugin, nil}, {ModifyRequestPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-comp-1"}
      request = %{model: "test"}

      assert {:skip, {:ok, %{content: %{parts: [%{text: "skipped by plugin"}]}}}} =
               ADK.Plugin.run_before_model(plugins, ctx, request)
    end

    test "before_tool skip takes priority over arg modification" do
      plugins = [{SkipToolPlugin, nil}, {ModifyArgsPlugin, %{}}]
      ctx = %ADK.Context{invocation_id: "inv-comp-2"}
      args = %{"input" => "x"}

      assert {:skip, {:ok, "tool my_tool was skipped"}} =
               ADK.Plugin.run_before_tool(plugins, ctx, "my_tool", args)
    end

    test "after_tool can chain transformations" do
      plugins = [{TransformResultPlugin, %{}}, {AppendPlugin, nil}]
      ctx = %ADK.Context{invocation_id: "inv-comp-3"}

      assert {:ok, "transformed: raw!"} =
               ADK.Plugin.run_after_tool(plugins, ctx, "tool", {:ok, "raw"})
    end

    test "multiple on_event plugins all fire" do
      {:ok, log_a} = Agent.start_link(fn -> 0 end)
      {:ok, log_b} = Agent.start_link(fn -> 0 end)

      event = ADK.Event.new(%{author: "agent", invocation_id: "inv-comp-4"})

      ctx = %ADK.Context{
        invocation_id: "inv-comp-4",
        temp_state: %{counter_a: log_a}
      }

      plugins = [{CounterPlugin, nil}, {CounterPlugin, nil}]
      ADK.Plugin.run_on_event(plugins, ctx, event)

      assert Agent.get(log_a, & &1) == 2

      Agent.stop(log_a)
      Agent.stop(log_b)
    end
  end
end
