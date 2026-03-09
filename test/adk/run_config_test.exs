defmodule ADK.RunConfigTest do
  use ExUnit.Case, async: true

  alias ADK.RunConfig

  # -- new/1 tests --

  test "new/0 returns defaults" do
    config = RunConfig.new()
    assert config.streaming_mode == :none
    assert config.max_llm_calls == nil
    assert config.output_format == "text"
    assert config.speech_config == nil
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

  test "new/1 accepts valid max_llm_calls" do
    assert RunConfig.new(max_llm_calls: 1).max_llm_calls == 1
    assert RunConfig.new(max_llm_calls: 100).max_llm_calls == 100
    assert RunConfig.new(max_llm_calls: nil).max_llm_calls == nil
  end

  test "new/1 rejects invalid max_llm_calls" do
    assert_raise ArgumentError, ~r/max_llm_calls/, fn ->
      RunConfig.new(max_llm_calls: 0)
    end

    assert_raise ArgumentError, ~r/max_llm_calls/, fn ->
      RunConfig.new(max_llm_calls: -1)
    end

    assert_raise ArgumentError, ~r/max_llm_calls/, fn ->
      RunConfig.new(max_llm_calls: "five")
    end
  end

  test "new/1 accepts output_format" do
    assert RunConfig.new(output_format: "json").output_format == "json"
  end

  test "new/1 accepts speech_config stub" do
    speech = %{voice: "alloy", model: "tts-1"}
    assert RunConfig.new(speech_config: speech).speech_config == speech
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

  # -- Doctests --

  doctest ADK.RunConfig
end
