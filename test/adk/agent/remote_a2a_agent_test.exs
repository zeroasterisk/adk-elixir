defmodule ADK.Agent.RemoteA2aAgentTest do
  use ExUnit.Case, async: true
  @moduletag :a2a

  alias ADK.Agent.RemoteA2aAgent
  alias ADK.Context
  alias ADK.Event

  defmodule MockA2aServer do
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      case {conn.request_path, payload["method"]} do
        {"/", "SendMessage"} ->
          # Simulate A2A SendMessage response
          msg = payload["params"]["message"]
          input_text = hd(msg["parts"])["text"]
          context_id = payload["params"]["contextId"] || "new-ctx-123"

          response = %{
            "jsonrpc" => "2.0",
            "id" => payload["id"],
            "result" => %{
              "message" => %{
                "role" => "ROLE_MODEL",
                "parts" => [%{"text" => "Reply to: #{input_text}", "mediaType" => "text/plain"}],
                "contextId" => context_id
              }
            }
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(response))

        _ ->
          conn
          |> Plug.Conn.send_resp(404, "Not found")
      end
    end
  end

  setup do
    port = :rand.uniform(10000) + 40000
    {:ok, pid} = Bandit.start_link(plug: MockA2aServer, port: port)
    url = "http://127.0.0.1:#{port}"

    on_exit(fn ->
      Process.exit(pid, :normal)
    end)

    {:ok, url: url}
  end

  test "agent sends events and returns response", %{url: url} do
    agent = RemoteA2aAgent.new(name: "remote_agent", target: url)

    ctx = %Context{
      invocation_id: "inv-1",
      user_content: %{parts: [%{text: "Hello!"}]}
    }

    [response_event] = ADK.Agent.run(agent, ctx)

    assert response_event.author == "remote_agent"
    assert ADK.Event.text(response_event) == "Reply to: Hello!"
    # It should save contextId in state_delta
    assert response_event.actions.state_delta["a2a_context_id_remote_agent"] == "new-ctx-123"
  end

  test "agent correctly limits events to only those after its last reply", %{url: url} do
    agent = RemoteA2aAgent.new(name: "remote_agent", target: url)

    {:ok, session_pid} = ADK.Session.start_link([])

    ADK.Session.append_event(
      session_pid,
      Event.new(%{author: "user", content: %{parts: [%{text: "Old stuff"}]}})
    )

    ADK.Session.append_event(
      session_pid,
      Event.new(%{author: "remote_agent", content: %{parts: [%{text: "Reply 1"}]}})
    )

    ADK.Session.append_event(
      session_pid,
      Event.new(%{author: "user", content: %{parts: [%{text: "New stuff"}]}})
    )

    ADK.Session.put_state(session_pid, "a2a_context_id_remote_agent", "existing-ctx-456")

    ctx = %Context{
      invocation_id: "inv-2",
      session_pid: session_pid
    }

    [response_event] = ADK.Agent.run(agent, ctx)

    assert response_event.author == "remote_agent"
    assert ADK.Event.text(response_event) == "Reply to: New stuff"
    # Should keep context
    assert response_event.actions.state_delta["a2a_context_id_remote_agent"] == "existing-ctx-456"
  end

  test "agent respects full_history_when_stateless when false", %{url: url} do
    agent =
      RemoteA2aAgent.new(name: "remote_agent", target: url, full_history_when_stateless: false)

    {:ok, session_pid} = ADK.Session.start_link([])

    ADK.Session.append_event(
      session_pid,
      Event.new(%{author: "user", content: %{parts: [%{text: "Msg 1"}]}})
    )

    ADK.Session.append_event(
      session_pid,
      Event.new(%{author: "remote_agent", content: %{parts: [%{text: "Reply 1"}]}})
    )

    ADK.Session.append_event(
      session_pid,
      Event.new(%{author: "user", content: %{parts: [%{text: "Msg 2"}]}})
    )

    ctx = %Context{
      invocation_id: "inv-3",
      session_pid: session_pid
    }

    [response_event] = ADK.Agent.run(agent, ctx)

    # It should only send "Msg 2" because it breaks at remote_agent
    assert ADK.Event.text(response_event) == "Reply to: Msg 2"
  end

  test "agent respects full_history_when_stateless when true", %{url: url} do
    agent =
      RemoteA2aAgent.new(name: "remote_agent", target: url, full_history_when_stateless: true)

    {:ok, session_pid} = ADK.Session.start_link([])

    ADK.Session.append_event(
      session_pid,
      Event.new(%{author: "user", content: %{parts: [%{text: "Msg 1"}]}})
    )

    ADK.Session.append_event(
      session_pid,
      Event.new(%{author: "remote_agent", content: %{parts: [%{text: "Reply 1"}]}})
    )

    ADK.Session.append_event(
      session_pid,
      Event.new(%{author: "user", content: %{parts: [%{text: "Msg 2"}]}})
    )

    ctx = %Context{
      invocation_id: "inv-4",
      session_pid: session_pid
    }

    [response_event] = ADK.Agent.run(agent, ctx)

    # If full_history_when_stateless is true, it sends everything
    assert String.starts_with?(ADK.Event.text(response_event), "Reply to: Msg 1")
  end

  test "agent gracefully handles errors" do
    agent =
      RemoteA2aAgent.new(
        name: "remote_agent",
        target: "http://127.0.0.1:9999",
        client_opts: [req_opts: [retry: false]]
      )

    ctx = %Context{
      invocation_id: "inv-5",
      user_content: %{parts: [%{text: "Hello!"}]}
    }

    [response_event] = ADK.Agent.run(agent, ctx)

    assert response_event.author == "remote_agent"
    assert response_event.error != nil
    assert String.contains?(response_event.error, "econnrefused")
  end
end
