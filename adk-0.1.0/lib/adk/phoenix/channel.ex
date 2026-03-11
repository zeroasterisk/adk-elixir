defmodule ADK.Phoenix.Channel do
  @moduledoc """
  A `use`-able module that adds ADK agent interaction to a Phoenix Channel.

  Requires Phoenix to be available at compile time. If Phoenix is not loaded,
  the module defines the macros but they will raise at compile time when used.

  ## Usage

  In your Phoenix application:

      defmodule MyAppWeb.AgentChannel do
        use MyAppWeb, :channel
        use ADK.Phoenix.Channel, agent: &MyApp.Agents.assistant/0

        # Optional: override to customize session/user resolution
        def adk_user_id(socket), do: socket.assigns.user_id
        def adk_session_id(socket), do: socket.assigns.session_id
      end

  This adds handlers for:
  - `"agent:run"` — synchronous run, replies with all events
  - `"agent:stream"` — async run, pushes events as they arrive
  """

  defmacro __using__(opts) do
    quote do
      @adk_agent_fn unquote(opts[:agent])
      @adk_app_name unquote(opts[:app_name] || "phoenix_app")

      def handle_in("agent:run", %{"message" => message}, socket) do
        runner = %ADK.Runner{
          app_name: @adk_app_name,
          agent: resolve_agent()
        }

        user_id = adk_user_id(socket)
        session_id = adk_session_id(socket)

        events = ADK.Runner.run(runner, user_id, session_id, message)
        event_maps = Enum.map(events, &ADK.Event.to_map/1)

        {:reply, {:ok, %{events: event_maps}}, socket}
      end

      def handle_in("agent:stream", %{"message" => message}, socket) do
        runner = %ADK.Runner{
          app_name: @adk_app_name,
          agent: resolve_agent()
        }

        user_id = adk_user_id(socket)
        session_id = adk_session_id(socket)

        {:ok, _pid} = ADK.Runner.Async.run(runner, user_id, session_id, message)

        {:noreply, socket}
      end

      def handle_info({:adk_event, event}, socket) do
        push(socket, "agent:event", ADK.Event.to_map(event))
        {:noreply, socket}
      end

      def handle_info({:adk_done, events}, socket) do
        push(socket, "agent:done", %{event_count: length(events)})
        {:noreply, socket}
      end

      def handle_info({:adk_error, reason}, socket) do
        push(socket, "agent:error", %{error: inspect(reason)})
        {:noreply, socket}
      end

      # Default implementations — override in your channel
      defp adk_user_id(socket) do
        Map.get(socket.assigns, :user_id, "anonymous")
      end

      defp adk_session_id(socket) do
        Map.get(socket.assigns, :session_id, "default")
      end

      defp resolve_agent do
        case @adk_agent_fn do
          fun when is_function(fun, 0) -> fun.()
          agent -> agent
        end
      end

      defoverridable adk_user_id: 1, adk_session_id: 1
    end
  end
end
