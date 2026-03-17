defmodule ADK.RunConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ADK.RunConfig

  # -- new/1 tests --

  test "new/0 returns defaults" do
    config = RunConfig.new()
    assert config.streaming_mode == :none
    assert config.max_llm_calls == 500
    assert config.output_format == "text"
    assert config.speech_config == nil
    assert config.response_modalities == nil
    assert config.output_config == nil
    assert config.support_cfc == false
    assert config.custom_metadata == nil
    assert config.output_audio_transcription == %{}
    assert config.input_audio_transcription == %{}
  end

  test "new/1 accepts valid streaming modes" do
    assert RunConfig.new(streaming_mode: :none).streaming_mode == :none
    assert RunConfig.new(streaming_mode: :sse).streaming_mode == :sse
    assert RunConfig.new(streaming_mode: :live).streaming_mode == :live
  end

  test "new/1 rejects invalid streaming mode" do
    assert_raise ArgumentError, ~r/invalid streaming_mode/, fn ->
      RunConfig.new(streaming_mode: :invalid)
    end
  end

  # -- max_llm_calls parity with Python test_run_config.py --

  test "validate_max_llm_calls valid" do
    config = RunConfig.new(max_llm_calls: 100)
    assert config.max_llm_calls == 100
  end

  test "validate_max_llm_calls negative warns but allows" do
    log =
      capture_log(fn ->
        config = RunConfig.new(max_llm_calls: -1)
        assert config.max_llm_calls == -1
      end)

    assert log =~ "max_llm_calls is less than or equal to 0"
  end

  test "validate_max_llm_calls warns on zero" do
    log =
      capture_log(fn ->
        config = RunConfig.new(max_llm_calls: 0)
        assert config.max_llm_calls == 0
      end)

    assert log =~ "max_llm_calls is less than or equal to 0"
  end

  test "validate_max_llm_calls too large" do
    max = RunConfig.max_integer()

    assert_raise ArgumentError, ~r/max_llm_calls should be less than/, fn ->
      RunConfig.new(max_llm_calls: max)
    end
  end

  test "validate_max_llm_calls rejects non-integer" do
    assert_raise ArgumentError, ~r/max_llm_calls must be an integer/, fn ->
      RunConfig.new(max_llm_calls: "five")
    end
  end

  test "new/1 accepts valid max_llm_calls" do
    assert RunConfig.new(max_llm_calls: 1).max_llm_calls == 1
    assert RunConfig.new(max_llm_calls: 100).max_llm_calls == 100
    assert RunConfig.new(max_llm_calls: 500).max_llm_calls == 500
  end

  # -- Audio transcription configs not shared between instances --

  test "audio transcription configs are not shared between instances" do
    config1 = RunConfig.new()
    config2 = RunConfig.new()

    # Validate output_audio_transcription exists and is independent
    assert config1.output_audio_transcription != nil
    assert config2.output_audio_transcription != nil

    # In Elixir, maps with same content are structurally equal but are
    # separate values (immutable). We verify they default to %{} independently.
    assert config1.output_audio_transcription == %{}
    assert config2.output_audio_transcription == %{}

    # Validate input_audio_transcription exists and is independent
    assert config1.input_audio_transcription != nil
    assert config2.input_audio_transcription != nil
    assert config1.input_audio_transcription == %{}
    assert config2.input_audio_transcription == %{}

    # Verify that setting one doesn't affect the other
    config3 = RunConfig.new(output_audio_transcription: %{enabled: true})
    config4 = RunConfig.new()
    assert config3.output_audio_transcription == %{enabled: true}
    assert config4.output_audio_transcription == %{}
  end

  test "new/1 accepts output_format" do
    assert RunConfig.new(output_format: "json").output_format == "json"
  end

  test "new/1 accepts speech_config stub" do
    speech = %{voice: "alloy", model: "tts-1"}
    assert RunConfig.new(speech_config: speech).speech_config == speech
  end

  # -- New fields --

  test "new/1 accepts response_modalities" do
    config = RunConfig.new(response_modalities: ["text", "audio"])
    assert config.response_modalities == ["text", "audio"]
  end

  test "new/1 accepts output_config" do
    oc = %{response_mime_type: "application/json", response_schema: %{type: "object"}}
    config = RunConfig.new(output_config: oc)
    assert config.output_config == oc
  end

  test "new/1 accepts support_cfc" do
    config = RunConfig.new(support_cfc: true)
    assert config.support_cfc == true
  end

  test "new/1 accepts custom_metadata" do
    meta = %{trace_id: "abc-123", env: "prod"}
    config = RunConfig.new(custom_metadata: meta)
    assert config.custom_metadata == meta
  end

  test "new/1 accepts audio transcription configs" do
    config = RunConfig.new(
      output_audio_transcription: %{language: "en"},
      input_audio_transcription: %{language: "fr"}
    )

    assert config.output_audio_transcription == %{language: "en"}
    assert config.input_audio_transcription == %{language: "fr"}
  end

  # -- build/1 tests --

  test "build/0 returns ok tuple with defaults" do
    assert {:ok, %RunConfig{streaming_mode: :none}} = RunConfig.build()
  end

  test "build/1 returns ok tuple" do
    assert {:ok, config} = RunConfig.build(streaming_mode: :sse, max_llm_calls: 10)
    assert config.streaming_mode == :sse
    assert config.max_llm_calls == 10
  end

  test "build/1 returns error for invalid config" do
    assert {:error, msg} = RunConfig.build(streaming_mode: :bad)
    assert msg =~ "invalid streaming_mode"
  end

  # -- Context integration --

  test "RunConfig can be stored in Context" do
    config = RunConfig.new(streaming_mode: :live)
    ctx = %ADK.Context{invocation_id: "test", run_config: config}
    assert ctx.run_config.streaming_mode == :live
  end

  test "all new fields round-trip through Context" do
    config = RunConfig.new(
      output_config: %{response_mime_type: "application/json"},
      response_modalities: ["text"],
      support_cfc: true,
      custom_metadata: %{foo: "bar"}
    )
    ctx = %ADK.Context{invocation_id: "test", run_config: config}
    assert ctx.run_config.output_config == %{response_mime_type: "application/json"}
    assert ctx.run_config.response_modalities == ["text"]
    assert ctx.run_config.support_cfc == true
    assert ctx.run_config.custom_metadata == %{foo: "bar"}
  end

  # -- Doctests --

  doctest ADK.RunConfig
end
