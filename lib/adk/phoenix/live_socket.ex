
defmodule ADK.Phoenix.LiveSocket do
  @moduledoc """
  Handles the `run_live` WebSocket connection for the ADK.
  """
  alias ADK.RunConfig

  def run_live_socket(params, agent_loader, session_service, runner) do
    # This is a mock function for testing purposes
    run_config = build_run_config(params)

    runner.run_live(%{
      run_config: run_config,
      app_name: params["app_name"],
      user_id: params["user_id"],
      session_id: params["session_id"],
      agent_loader: agent_loader,
      session_service: session_service
    })
  end

  defp build_run_config(params) do
    %RunConfig{
      response_modalities: params["modalities"],
      enable_affective_dialog: to_boolean(params["enable_affective_dialog"]),
      proactivity: proactivity_config(params),
      session_resumption: session_resumption_config(params)
    }
  end

  defp proactivity_config(params) do
    case params["proactive_audio"] do
      "true" -> %{proactive_audio: true}
      "false" -> %{proactive_audio: false}
      _ -> nil
    end
  end

  defp session_resumption_config(params) do
    case params["enable_session_resumption"] do
      "true" -> %{transparent: true}
      "false" -> %{transparent: false}
      _ -> nil
    end
  end

  defp to_boolean("true"), do: true
  defp to_boolean("false"), do: false
  defp to_boolean(_), do: nil
end
