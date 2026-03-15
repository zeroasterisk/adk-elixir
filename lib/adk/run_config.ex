defmodule ADK.RunConfig do
  @moduledoc """
  Configuration struct for controlling Runner execution behavior.

  Mirrors Python ADK's `RunConfig` for parity. All new fields are optional
  (nil by default) and only take effect when explicitly set.

  ## Fields

  - `:streaming_mode` — `:none`, `:sse`, or `:live` (default: `:none`)
  - `:max_llm_calls` — Maximum number of LLM calls per run (default: `nil` = unlimited)
  - `:output_format` — Output format hint, e.g. `"text"`, `"json"` (default: `"text"`)
  - `:speech_config` — Speech configuration map (voice, language) (default: `nil`)
  - `:generate_config` — Generation config overrides (temperature, etc.) (default: `%{}`)
  - `:response_modalities` — Output modalities, e.g. `["text"]`, `["audio"]` (default: `nil`)
  - `:output_config` — Structured output config: `response_mime_type`, `response_schema` (default: `nil`)
  - `:support_cfc` — Enable Compositional Function Calling via Live API (default: `false`)
  - `:custom_metadata` — Arbitrary metadata map for the invocation (default: `nil`)
  - `:get_session_config` — Configuration for getting a session (`num_recent_events`, `after_timestamp`) (default: `nil`)

  ## Examples

      config = ADK.RunConfig.new(streaming_mode: :sse, max_llm_calls: 10)
      ADK.Runner.run(runner, "user", "sess", "hello", run_config: config)

      # Structured JSON output
      config = ADK.RunConfig.new(
        output_config: %{
          response_mime_type: "application/json",
          response_schema: %{type: "object", properties: %{name: %{type: "string"}}}
        }
      )
  """

  defstruct [
    streaming_mode: :none,
    max_llm_calls: nil,
    output_format: "text",
    speech_config: nil,
    generate_config: %{},
    response_modalities: nil,
    output_config: nil,
    support_cfc: false,
    custom_metadata: nil,
    get_session_config: nil
  ]

  @type streaming_mode :: :none | :sse | :live

  @type output_config :: %{
          optional(:response_mime_type) => String.t(),
          optional(:response_schema) => map()
        }

  @type get_session_config :: %{
          optional(:num_recent_events) => non_neg_integer(),
          optional(:after_timestamp) => float()
        }

  @type t :: %__MODULE__{
          streaming_mode: streaming_mode(),
          max_llm_calls: pos_integer() | nil,
          output_format: String.t(),
          speech_config: map() | nil,
          generate_config: map(),
          response_modalities: [String.t()] | nil,
          output_config: output_config() | nil,
          support_cfc: boolean(),
          custom_metadata: map() | nil,
          get_session_config: get_session_config() | nil
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

  defp validate!(%__MODULE__{get_session_config: config}) when not is_nil(config) and not is_map(config) do
    raise ArgumentError, "get_session_config must be a map or nil, got: #{inspect(config)}"
  end

  defp validate!(%__MODULE__{get_session_config: %{num_recent_events: num}}) when not is_nil(num) and (not is_integer(num) or num < 0) do
    raise ArgumentError, "get_session_config.num_recent_events must be a non-negative integer or nil, got: #{inspect(num)}"
  end

  defp validate!(_config), do: :ok
end
