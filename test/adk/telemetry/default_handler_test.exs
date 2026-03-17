defmodule ADK.Telemetry.DefaultHandlerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ADK.Telemetry.DefaultHandler
  alias ADK.Telemetry.Contract

  setup do
    # Detach if already attached, then re-attach fresh
    DefaultHandler.detach()
    DefaultHandler.attach()

    on_exit(fn ->
      DefaultHandler.detach()
    end)

    :ok
  end

  describe "attach/0 and detach/0" do
    test "attach returns :ok on first call" do
      DefaultHandler.detach()
      assert :ok = DefaultHandler.attach()
    end

    test "attach returns {:error, :already_exists} on second call" do
      # Already attached in setup
      assert {:error, :already_exists} = DefaultHandler.attach()
    end

    test "detach returns :ok when attached" do
      assert :ok = DefaultHandler.detach()
    end
  end

  describe "start event logging" do
    test "logs runner start at debug level" do
      meta = %{app_name: "testapp", agent_name: "bot", session_id: "s1", user_id: "u1"}

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:adk, :runner, :start], %{monotonic_time: 0, system_time: 0}, meta)
        end)

      assert log =~ "[ADK]"
      assert log =~ "[:adk, :runner, :start]"
      assert log =~ "app_name="
      assert log =~ "agent_name="
    end

    test "logs session start at debug level" do
      meta = %{app_name: "testapp", session_id: "s1", user_id: "u1"}

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:adk, :session, :start], %{monotonic_time: 0, system_time: 0}, meta)
        end)

      assert log =~ "[ADK]"
      assert log =~ "[:adk, :session, :start]"
      assert log =~ "session_id="
    end
  end

  describe "stop event logging" do
    test "logs runner stop with duration" do
      meta = %{app_name: "testapp", agent_name: "bot", session_id: "s1", user_id: "u1"}

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:adk, :runner, :stop], %{duration: 42_500_000}, meta)
        end)

      assert log =~ "[ADK]"
      assert log =~ "[:adk, :runner, :stop]"
      assert log =~ "duration=42.5ms"
    end

    test "logs agent stop with duration" do
      meta = %{agent_name: "helper", session_id: "s1"}

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:adk, :agent, :stop], %{duration: 1_000_000}, meta)
        end)

      assert log =~ "duration=1.0ms"
      assert log =~ "agent_name="
    end

    test "logs tool stop with duration" do
      meta = %{tool_name: "search", agent_name: "bot"}

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:adk, :tool, :stop], %{duration: 250_000}, meta)
        end)

      assert log =~ "duration=0.25ms"
      assert log =~ "tool_name="
    end

    test "logs llm stop with duration and model" do
      meta = %{model: "gemini-2.0-flash", agent_name: "bot"}

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:adk, :llm, :stop], %{duration: 500_000_000}, meta)
        end)

      assert log =~ "duration=500.0ms"
      assert log =~ "model="
    end

    test "handles nil duration gracefully" do
      meta = %{agent_name: "bot"}

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:adk, :agent, :stop], %{}, meta)
        end)

      assert log =~ "duration=0ms"
    end
  end

  describe "exception event logging" do
    test "logs exception with kind and reason" do
      meta = %{
        agent_name: "bot",
        kind: :error,
        reason: %RuntimeError{message: "boom"},
        stacktrace: []
      }

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:adk, :llm, :exception], %{duration: 1_200_000}, meta)
        end)

      assert log =~ "[ADK]"
      assert log =~ "[:adk, :llm, :exception]"
      assert log =~ "kind=error"
      assert log =~ "reason="
      assert log =~ "boom"
      assert log =~ "duration=1.2ms"
    end

    test "exception metadata excludes kind/reason/stacktrace from extra fields" do
      meta = %{
        agent_name: "bot",
        session_id: "s1",
        kind: :error,
        reason: %RuntimeError{message: "oops"},
        stacktrace: [{__MODULE__, :test, 0, []}]
      }

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:adk, :tool, :exception], %{duration: 0}, meta)
        end)

      # Should show agent_name and session_id but not re-show stacktrace
      assert log =~ "agent_name="
      assert log =~ "session_id="
      # The stacktrace itself shouldn't appear in the metadata portion
      refute log =~ "stacktrace="
    end
  end

  describe "integration with Contract spans" do
    test "runner span logs start and stop" do
      meta = %{app_name: "testapp", agent_name: "bot", session_id: "s1", user_id: "u1"}

      log =
        capture_log([level: :debug], fn ->
          Contract.runner_span(meta, fn -> :ok end)
        end)

      assert log =~ "[:adk, :runner, :start]"
      assert log =~ "[:adk, :runner, :stop]"
      assert log =~ "duration="
    end

    test "session span logs start and stop" do
      meta = %{app_name: "testapp", session_id: "s1", user_id: "u1"}

      log =
        capture_log([level: :debug], fn ->
          Contract.session_span(meta, fn -> :ok end)
        end)

      assert log =~ "[:adk, :session, :start]"
      assert log =~ "[:adk, :session, :stop]"
    end

    test "exception span logs start and exception" do
      meta = %{model: "gemini-2.0-flash", agent_name: "bot", session_id: "s1"}

      log =
        capture_log([level: :debug], fn ->
          assert_raise RuntimeError, fn ->
            Contract.llm_span(meta, fn -> raise "api error" end)
          end
        end)

      assert log =~ "[:adk, :llm, :start]"
      assert log =~ "[:adk, :llm, :exception]"
      assert log =~ "api error"
    end
  end
end
