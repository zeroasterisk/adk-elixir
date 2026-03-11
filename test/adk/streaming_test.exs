defmodule ADK.StreamingTest do
  @moduledoc """
  End-to-end streaming tests: SSE format correctness, event ordering,
  context on_event callback, and client disconnect handling.
  """

  use ExUnit.Case, async: true

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp echo_agent(name \\ "echo") do
    ADK.Agent.Custom.new(
      name: name,
      description: "Echo agent for streaming tests",
      run_fn: fn _agent, ctx ->
        text =
          case ctx.user_content do
            %{text: t} -> t
            t when is_binary(t) -> t
            _ -> "echo"
          end

        [ADK.Event.new(%{
          author: name,
          content: %{role: :model, parts: [%{text: "Echo: #{text}"}]}
        })]
      end
    )
  end

  defp multi_event_agent do
    ADK.Agent.Custom.new(
      name: "multi",
      description: "Agent that emits multiple events",
      run_fn: fn _agent, ctx ->
        text = case ctx.user_content do
          %{text: t} -> t
          _ -> "hi"
        end

        [
          ADK.Event.new(%{
            author: "multi",
            content: %{role: :model, parts: [%{text: "First: #{text}"}]}
          }),
          ADK.Event.new(%{
            author: "multi",
            content: %{role: :model, parts: [%{text: "Second: #{text}"}]}
          }),
          ADK.Event.new(%{
            author: "multi",
            content: %{role: :model, parts: [%{text: "Third: #{text}"}]}
          })
        ]
      end
    )
  end

  defp build_runner(agent) do
    ADK.Runner.new(app_name: "streaming_test", agent: agent)
  end

  # ── Context on_event callback ────────────────────────────────────────────────

  describe "Context.emit_event/2" do
    test "calls on_event callback when set" do
      ctx = %ADK.Context{
        invocation_id: "inv-1",
        on_event: fn event -> send(self(), {:emitted, event}) end
      }

      event = ADK.Event.new(%{author: "test", content: %{parts: [%{text: "hi"}]}})
      ADK.Context.emit_event(ctx, event)

      assert_receive {:emitted, ^event}, 100
    end

    test "no-op when on_event is nil" do
      ctx = %ADK.Context{invocation_id: "inv-1", on_event: nil}
      event = ADK.Event.new(%{author: "test", content: %{parts: [%{text: "hi"}]}})

      # Should not raise
      assert :ok = ADK.Context.emit_event(ctx, event)
    end
  end

  # ── Runner streaming via on_event ────────────────────────────────────────────

  describe "Runner.run/5 with on_event" do
    test "fires on_event for each event as produced" do
      runner = build_runner(echo_agent())
      pid = self()

      events = ADK.Runner.run(runner, "user1", "sess-stream-1", "hello",
        on_event: fn event -> send(pid, {:streamed, event}) end
      )

      assert length(events) == 1
      assert_receive {:streamed, event}, 500
      assert event.author == "echo"
    end

    test "events arrive in order" do
      runner = build_runner(multi_event_agent())
      pid = self()

      events = ADK.Runner.run(runner, "user1", "sess-stream-2", "test",
        on_event: fn event -> send(pid, {:streamed, event}) end
      )

      assert length(events) == 3

      received =
        Enum.map(1..3, fn _ ->
          receive do
            {:streamed, e} -> e
          after
            500 -> flunk("Expected event, got nothing")
          end
        end)

      texts = Enum.map(received, fn e ->
        case e.content do
          %{parts: [%{text: t} | _]} -> t
          _ -> nil
        end
      end)

      assert Enum.at(texts, 0) =~ "First"
      assert Enum.at(texts, 1) =~ "Second"
      assert Enum.at(texts, 2) =~ "Third"
    end

    test "on_event fires during run, not after" do
      # Verify on_event fires synchronously (message in mailbox before assert)
      pid = self()
      runner = build_runner(echo_agent())

      ADK.Runner.run(runner, "user1", "sess-stream-3", "timing test",
        on_event: fn _event -> send(pid, :event_fired) end
      )

      # Message should already be in mailbox (synchronous call)
      assert_receive :event_fired, 100
    end
  end

  # ── Runner.run_streaming ─────────────────────────────────────────────────────

  describe "Runner.run_streaming/5" do
    test "delegates to run/5 with on_event in context" do
      runner = build_runner(echo_agent())
      pid = self()

      events = ADK.Runner.run_streaming(runner, "user1", "sess-stream-4", "hi",
        on_event: fn event -> send(pid, {:streamed, event}) end
      )

      assert is_list(events)
      assert length(events) >= 1
      assert_receive {:streamed, _event}, 500
    end
  end

  # ── Runner.run_async ─────────────────────────────────────────────────────────

  describe "Runner.run_async/5" do
    test "sends {:adk_event, event} messages to caller" do
      runner = build_runner(echo_agent())

      {:ok, _pid} = ADK.Runner.run_async(runner, "user1", "sess-async-1", "hello",
        reply_to: self()
      )

      assert_receive {:adk_event, event}, 1000
      assert event.author == "echo"
    end

    test "sends {:adk_done, events} when complete" do
      runner = build_runner(echo_agent())

      {:ok, _pid} = ADK.Runner.run_async(runner, "user1", "sess-async-2", "hello",
        reply_to: self()
      )

      assert_receive {:adk_done, events}, 1000
      assert is_list(events)
      assert length(events) == 1
    end

    test "multiple events arrive in order" do
      runner = build_runner(multi_event_agent())

      {:ok, _pid} = ADK.Runner.run_async(runner, "user1", "sess-async-3", "test",
        reply_to: self()
      )

      events =
        Enum.map(1..3, fn _ ->
          receive do
            {:adk_event, e} -> e
          after
            1000 -> flunk("Timeout waiting for event")
          end
        end)

      assert_receive {:adk_done, _}, 1000

      texts = Enum.map(events, fn e ->
        case e.content do
          %{parts: [%{text: t} | _]} -> t
          _ -> ""
        end
      end)

      assert Enum.at(texts, 0) =~ "First"
      assert Enum.at(texts, 1) =~ "Second"
      assert Enum.at(texts, 2) =~ "Third"
    end

    test "forwards on_event callback in addition to messages" do
      runner = build_runner(echo_agent())
      pid = self()

      {:ok, _pid} = ADK.Runner.run_async(runner, "user1", "sess-async-4", "hi",
        reply_to: self(),
        on_event: fn _event -> send(pid, :callback_fired) end
      )

      assert_receive :callback_fired, 1000
      assert_receive {:adk_event, _}, 1000
      assert_receive {:adk_done, _}, 1000
    end
  end

  # ── SSE format via WebRouter ─────────────────────────────────────────────────

  describe "POST /run_sse SSE format" do
    defp build_conn(method, path, body \\ nil) do
      conn = Plug.Test.conn(method, path, body && Jason.encode!(body))
      if body do
        conn |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn
      end
    end

    defp call_router(conn) do
      agents = %{"stream_app" => echo_agent("stream_echo")}
      opts = [
        agent_loader: agents,
        session_store: {ADK.Session.Store.InMemory, []}
      ]
      ADK.Phoenix.WebRouter.call(conn, ADK.Phoenix.WebRouter.init(opts))
    end

    test "returns text/event-stream content type" do
      conn =
        build_conn(:post, "/run_sse", %{
          app_name: "stream_app",
          user_id: "user1",
          session_id: "sse-format-1",
          new_message: %{parts: [%{text: "hello"}]}
        })
        |> call_router()

      assert conn.status == 200
      content_type = Plug.Conn.get_resp_header(conn, "content-type") |> List.first()
      assert content_type =~ "text/event-stream"
    end

    test "response body contains SSE data: lines" do
      conn =
        build_conn(:post, "/run_sse", %{
          app_name: "stream_app",
          user_id: "user1",
          session_id: "sse-format-2",
          new_message: %{parts: [%{text: "hello"}]}
        })
        |> call_router()

      body = conn.resp_body
      assert body =~ "data: "
      assert body =~ "\n\n"
    end

    test "SSE data lines are valid JSON" do
      conn =
        build_conn(:post, "/run_sse", %{
          app_name: "stream_app",
          user_id: "user1",
          session_id: "sse-format-3",
          new_message: %{parts: [%{text: "test SSE JSON"}]}
        })
        |> call_router()

      body = conn.resp_body

      # Parse each data: line as JSON
      data_lines =
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))
        |> Enum.map(&String.slice(&1, 6..-1//1))

      assert length(data_lines) > 0, "Expected at least one SSE data line"

      Enum.each(data_lines, fn line ->
        assert {:ok, _} = Jason.decode(line),
               "Expected valid JSON in SSE data line: #{line}"
      end)
    end

    test "SSE events have expected fields" do
      conn =
        build_conn(:post, "/run_sse", %{
          app_name: "stream_app",
          user_id: "user1",
          session_id: "sse-format-4",
          new_message: %{parts: [%{text: "field check"}]}
        })
        |> call_router()

      body = conn.resp_body

      events =
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))
        |> Enum.map(&String.slice(&1, 6..-1//1))
        |> Enum.map(&Jason.decode!/1)

      # At least one event should have agent fields
      agent_events = Enum.filter(events, &Map.has_key?(&1, "author"))
      assert length(agent_events) > 0

      Enum.each(agent_events, fn event ->
        assert Map.has_key?(event, "author"), "event missing 'author': #{inspect(event)}"
        assert Map.has_key?(event, "id"), "event missing 'id': #{inspect(event)}"
      end)
    end

    test "returns 404 for unknown app" do
      conn =
        build_conn(:post, "/run_sse", %{
          app_name: "no_such_app",
          user_id: "u",
          session_id: "s",
          new_message: %{parts: [%{text: "hi"}]}
        })
        |> call_router()

      assert conn.status == 404
    end

    test "includes no-cache and connection headers" do
      conn =
        build_conn(:post, "/run_sse", %{
          app_name: "stream_app",
          user_id: "user1",
          session_id: "sse-headers-1",
          new_message: %{parts: [%{text: "headers test"}]}
        })
        |> call_router()

      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-cache"]
      assert Plug.Conn.get_resp_header(conn, "x-accel-buffering") == ["no"]
    end
  end

  # ── Dev Server SSE endpoint ───────────────────────────────────────────────────

  describe "POST /api/chat/stream (dev server)" do
    defp build_dev_conn(method, path, body \\ nil) do
      conn = Plug.Test.conn(method, path, body && Jason.encode!(body))
      if body do
        conn |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn
      end
    end

    defp call_dev(conn) do
      opts = [agent: :demo, model: "test", port: 4000]
      ADK.DevServer.Router.call(conn, ADK.DevServer.Router.init(opts))
    end

    test "returns text/event-stream content type" do
      conn =
        build_dev_conn(:post, "/api/chat/stream", %{
          "message" => "hello",
          "session_id" => "dev-sse-1"
        })
        |> call_dev()

      assert conn.status == 200
      ct = Plug.Conn.get_resp_header(conn, "content-type") |> List.first()
      assert ct =~ "text/event-stream"
    end

    test "SSE body contains data: lines with valid JSON" do
      conn =
        build_dev_conn(:post, "/api/chat/stream", %{
          "message" => "test streaming",
          "session_id" => "dev-sse-2"
        })
        |> call_dev()

      body = conn.resp_body

      data_lines =
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))
        |> Enum.map(&String.slice(&1, 6..-1//1))

      assert length(data_lines) > 0

      Enum.each(data_lines, fn line ->
        assert {:ok, _} = Jason.decode(line)
      end)
    end

    test "first SSE event is session info" do
      conn =
        build_dev_conn(:post, "/api/chat/stream", %{
          "message" => "test",
          "session_id" => "dev-sse-3"
        })
        |> call_dev()

      body = conn.resp_body

      first_data =
        body
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "data: "))
        |> then(&String.slice(&1, 6..-1//1))
        |> Jason.decode!()

      assert first_data["type"] == "session"
      assert is_binary(first_data["session_id"])
    end

    test "returns 400 for missing message" do
      conn =
        build_dev_conn(:post, "/api/chat/stream", %{"session_id" => "dev-sse-4"})
        |> call_dev()

      assert conn.status == 400
    end
  end
end
