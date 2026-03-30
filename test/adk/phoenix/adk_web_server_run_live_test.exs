defmodule Adk.Phoenix.AdkWebServerRunLiveTest do
  use ExUnit.Case, async: true

  alias ADK.RunConfig
  alias ADK.Phoenix.LiveSocket

  defmodule DummyAgent do
    defstruct ~w[name sub_agents]a
  end

  defmodule DummyAgentLoader do
    def load_agent(_app_name), do: %DummyAgent{}
    def list_agents, do: ["test_app"]
    def list_agents_detailed, do: []
  end

  defmodule CapturingRunner do
    def run_live(opts) do
      Process.put(:captured_run_config, opts[:run_config])
      {:ok, %{}}
    end
  end

  defmodule DummySessionService do
    def create_session(_opts), do: {:ok, %{}}
    def get_session(_opts), do: {:ok, %{}}
  end

  test "run_live applies run_config query_options" do
    params = %{
      "app_name" => "test_app",
      "user_id" => "user",
      "session_id" => "session",
      "modalities" => ["TEXT", "AUDIO"],
      "proactive_audio" => "true",
      "enable_affective_dialog" => "true",
      "enable_session_resumption" => "true"
    }

    LiveSocket.run_live_socket(
      params,
      DummyAgentLoader,
      DummySessionService,
      CapturingRunner
    )

    run_config = Process.get(:captured_run_config)

    assert %RunConfig{
             response_modalities: ["TEXT", "AUDIO"],
             enable_affective_dialog: true,
             proactivity: %{proactive_audio: true},
             session_resumption: %{transparent: true}
           } = run_config
  end

  for {query, expected_enable_affective, expected_proactive_audio,
       expected_session_resumption_transparent} <-
        [
          [%{}, nil, nil, nil],
          [%{"proactive_audio" => "true"}, nil, true, nil],
          [%{"proactive_audio" => "false"}, nil, false, nil],
          [%{"enable_affective_dialog" => "true"}, true, nil, nil],
          [%{"enable_affective_dialog" => "false"}, false, nil, nil],
          [%{"enable_session_resumption" => "true"}, nil, nil, true],
          [%{"enable_session_resumption" => "false"}, nil, nil, false]
        ] do
    test "run_live defaults and individual options with query #{inspect(query)}" do
      params =
        %{
          "app_name" => "test_app",
          "user_id" => "user",
          "session_id" => "session",
          "modalities" => ["AUDIO"]
        }
        |> Map.merge(unquote(Macro.escape(query)))

      AdkWebServer.run_live_socket(
        params,
        DummyAgentLoader,
        DummySessionService,
        CapturingRunner
      )

      run_config = Process.get(:captured_run_config)

      assert run_config.enable_affective_dialog == unquote(expected_enable_affective)

      if unquote(expected_proactive_audio) == nil do
        assert run_config.proactivity == nil
      else
        assert run_config.proactivity.proactive_audio == unquote(expected_proactive_audio)
      end

      if unquote(expected_session_resumption_transparent) == nil do
        assert run_config.session_resumption == nil
      else
        assert run_config.session_resumption.transparent ==
                 unquote(expected_session_resumption_transparent)
      end
    end
  end
end
