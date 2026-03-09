defmodule ADK.RunConfig do
  @moduledoc """
  Configuration struct for controlling Runner execution behavior.

  ## Fields

  - `:streaming_mode` — `:none`, `:sse`, or `:live` (default: `:none`)
  - `:max_llm_calls` — Maximum number of LLM calls per run (default: `nil` = unlimited)
  - `:output_format` — Output format hint, e.g. `"text"`, `"json"` (default: `"text"`)
  - `:speech_config` — Speech configuration stub (default: `nil`)

  ## Examples

      config = ADK.RunConfig.new(streaming_mode: :sse, max_llm_calls: 10)
      ADK.Runner.run(runner, "user", "sess", "hello", run_config: config)
  """

  defstruct [
    streaming_mode: :none,
    max_llm_calls: nil,
    output_format: "text",
    speech_config: nil
  ]

  @type streaming_mode :: :none | :sse | :live
  @type t :: %__MODULE__{
          streaming_mode: streaming_mode(),
          max_llm_calls: pos_integer() | nil,
          output_format: String.t(),
          speech_config: map() | nil
        }

  @valid_streaming_modes [:none, :sse, :live]

  @doc """
  Create a new RunConfig.

  ## Examples

      iex> config = ADK.RunConfig.new()
      iex> config.streaming_mode
      :none

      iex> config = ADK.RunConfig.new(streaming_mode: :sse, max_llm_calls: 5)
      iex> config.max_llm_calls
      5
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    config = struct!(__MODULE__, opts)
    validate!(config)
    config
  end

  @doc """
  Create a RunConfig with validation, returning `{:ok, config}` or `{:error, reason}`.

  ## Examples

      iex> {:ok, config} = ADK.RunConfig.build(streaming_mode: :live)
      iex> config.streaming_mode
      :live

      iex> {:error, _} = ADK.RunConfig.build(streaming_mode: :invalid)
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(opts \\ []) do
    {:ok, new(opts)}
  rescue
    e in ArgumentError -> {:error, Exception.message(e)}
  end

  defp validate!(%__MODULE__{streaming_mode: mode}) when mode not in @valid_streaming_modes do
    raise ArgumentError, "invalid streaming_mode: #{inspect(mode)}, must be one of #{inspect(@valid_streaming_modes)}"
  end

  defp validate!(%__MODULE__{max_llm_calls: max}) when not is_nil(max) and (not is_integer(max) or max < 1) do
    raise ArgumentError, "max_llm_calls must be a positive integer or nil, got: #{inspect(max)}"
  end

  defp validate!(_config), do: :ok
end
