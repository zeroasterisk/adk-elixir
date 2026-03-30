defmodule ADK.StreamingAudioStorageParityTest do
  use ExUnit.Case, async: true

  alias ADK.Context
  alias ADK.Flows.LlmFlows.TranscriptionManager
  alias ADK.Agent.LlmAgent
  alias ADK.RunConfig

  setup do
    app_name = "test_app_#{System.unique_integer([:positive])}"
    user_id = "test_user"
    session_id = "test_session_#{System.unique_integer([:positive])}"

    {:ok, session_pid} =
      ADK.Session.start_link(
        app_name: app_name,
        user_id: user_id,
        session_id: session_id
      )

    agent = LlmAgent.new(name: "test_agent", model: "gemini-2.0-flash-exp")

    {:ok, artifact_store_pid} = ADK.Artifact.InMemory.start_link()

    ctx = %Context{
      app_name: app_name,
      user_id: user_id,
      invocation_id: "test_invocation",
      session_pid: session_pid,
      agent: agent,
      artifact_service: {ADK.Artifact.InMemory, pid: artifact_store_pid},
      run_config: %RunConfig{support_cfc: true}
    }

    {:ok, ctx: ctx, session_pid: session_pid, session_id: session_id}
  end

  test "test_audio_caching_direct", %{ctx: ctx, session_id: session_id} do
    audio_data = <<0, 255, 1, 2, 3, 4, 5, 6>>
    audio_mime_type = "audio/pcm"

    artifact = %{
      data: audio_data,
      content_type: audio_mime_type,
      metadata: %{}
    }

    # In python ADK, they added real-time entry blob to invocation cache, then flush saves them as artifact
    # In Elixir, we directly save artifact to simulate the flushed state of the Audio Cache
    {artifact_mod, artifact_opts} = ctx.artifact_service

    assert :ok ==
             artifact_mod.save(
               ctx.app_name,
               ctx.user_id,
               session_id,
               "audio_1.pcm",
               artifact,
               artifact_opts
             )
             |> elem(0)

    {:ok, keys} = artifact_mod.list(ctx.app_name, ctx.user_id, session_id, artifact_opts)
    assert length(keys) > 0
    assert Enum.any?(keys, &String.starts_with?(&1, "audio"))

    audio_key = List.first(keys)

    {:ok, loaded_artifact} =
      artifact_mod.load(ctx.app_name, ctx.user_id, session_id, audio_key, artifact_opts)

    assert loaded_artifact.data == audio_data
    assert loaded_artifact.content_type == audio_mime_type
  end

  test "test_transcription_handling", %{ctx: ctx, session_pid: session_pid} do
    input_transcription = %{text: "Hello, this is transcribed input", finished: true}
    output_transcription = %{text: "This is transcribed output", finished: true}

    events_before = length(ADK.Session.get_events(session_pid))
    assert events_before == 0

    input_event = TranscriptionManager.handle_input_transcription(ctx, input_transcription)
    output_event = TranscriptionManager.handle_output_transcription(ctx, output_transcription)

    assert input_event.input_transcription.text == "Hello, this is transcribed input"
    assert input_event.author == "user"

    assert output_event.output_transcription.text == "This is transcribed output"
    assert output_event.author == "test_agent"

    # Append transcription events to session
    ADK.Session.append_event(session_pid, input_event)
    ADK.Session.append_event(session_pid, output_event)

    events_after = ADK.Session.get_events(session_pid)
    assert length(events_after) == 2

    transcription_events =
      Enum.filter(events_after, fn event ->
        event.input_transcription != nil or event.output_transcription != nil
      end)

    assert length(transcription_events) >= 2

    input_events = Enum.filter(events_after, &(&1.input_transcription != nil))
    assert length(input_events) >= 1
    assert hd(input_events).input_transcription.text == "Hello, this is transcribed input"
    assert hd(input_events).author == "user"

    output_events = Enum.filter(events_after, &(&1.output_transcription != nil))
    assert length(output_events) >= 1
    assert hd(output_events).output_transcription.text == "This is transcribed output"
    assert hd(output_events).author == "test_agent"
  end
end
