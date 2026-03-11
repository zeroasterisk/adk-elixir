defmodule ADK.Phoenix.LiveHandler do
  @moduledoc """
  A `use`-able module that adds ADK agent interaction to a Phoenix LiveView.

  Manages agent sessions in socket assigns and handles async events.

  ## Usage

      defmodule MyAppWeb.ChatLive do
        use MyAppWeb, :live_view
        use ADK.Phoenix.LiveHandler, agent: &MyApp.Agents.assistant/0

        def mount(_params, _session, socket) do
          {:ok, assign(socket, messages: [], loading: false)}
        end

        def handle_event("send_message", %{"message" => msg}, socket) do
          socket = adk_run_async(socket, msg)
          {:noreply, assign(socket, loading: true)}
        end

        # Override to customize how events are handled
        def handle_adk_event(event, socket) do
          messages = socket.assigns.messages ++ [event]
          {:noreply, assign(socket, messages: messages)}
        end

        def handle_adk_done(_events, socket) do
          {:noreply, assign(socket, loading: false)}
        end
      end
  """

  defmacro __using__(opts) do
    quote do
      @adk_agent_fn unquote(opts[:agent])
      @adk_app_name unquote(opts[:app_name] || "phoenix_app")

      def handle_info({:adk_event, event}, socket) do
        handle_adk_event(event, socket)
      end

      def handle_info({:adk_done, events}, socket) do
        handle_adk_done(events, socket)
      end

      def handle_info({:adk_error, reason}, socket) do
        handle_adk_error(reason, socket)
      end

      @doc "Start an async agent run. Call from handle_event."
      def adk_run_async(socket, message, opts \\ []) do
        runner = %ADK.Runner{
          app_name: @adk_app_name,
          agent: adk_resolve_agent()
        }

        user_id = opts[:user_id] || Map.get(socket.assigns, :user_id, "anonymous")
        session_id = opts[:session_id] || Map.get(socket.assigns, :session_id, "default")

        {:ok, _pid} = ADK.Runner.Async.run(runner, user_id, session_id, message)
        socket
      end

      # Default callbacks — override in your LiveView
      def handle_adk_event(event, socket) do
        events = Map.get(socket.assigns, :adk_events, [])
        {:noreply, assign(socket, :adk_events, events ++ [event])}
      end

      def handle_adk_done(_events, socket) do
        {:noreply, socket}
      end

      def handle_adk_error(reason, socket) do
        {:noreply, assign(socket, :adk_error, inspect(reason))}
      end

      defp adk_resolve_agent do
        case @adk_agent_fn do
          fun when is_function(fun, 0) -> fun.()
          agent -> agent
        end
      end

      defoverridable handle_adk_event: 2, handle_adk_done: 2, handle_adk_error: 2
    end
  end
end
