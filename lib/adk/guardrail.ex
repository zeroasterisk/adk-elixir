defmodule ADK.Guardrail do
  @moduledoc """
  Behaviour for input/output validation guardrails.

  Guardrails validate content before or after agent execution. They're the
  "safety rails" of the Harness — lightweight checks that can block execution,
  filter content, or enforce output schemas.

  Implement the `validate/2` callback to create custom guardrails.

  ADK Elixir extension — no Python ADK equivalent exists.

  ## Built-in Guardrails

    * `ADK.Guardrail.ContentFilter` — block content matching patterns
    * `ADK.Guardrail.Schema` — validate structured output matches a schema

  ## Example

      defmodule MyApp.Guardrail.NoSecrets do
        @behaviour ADK.Guardrail

        @impl true
        def validate(content, _config) do
          if String.contains?(content, ["password", "secret", "token"]) do
            {:error, "Content contains potential secrets"}
          else
            :ok
          end
        end
      end
  """

  @type config :: struct() | map()

  @doc "Validate content. Returns `:ok` or `{:error, reason}`."
  @callback validate(content :: String.t(), config :: config()) ::
              :ok | {:error, reason :: String.t()}

  @doc """
  Run a list of guardrails against content sequentially.

  Returns `:ok` if all pass, or `{:error, reason}` on the first failure.

  ## Examples

      iex> ADK.Guardrail.run_all([], "hello")
      :ok
  """
  @spec run_all([struct()], String.t()) :: :ok | {:error, String.t()}
  def run_all(guardrails, content) do
    Enum.reduce_while(guardrails, :ok, fn guardrail, :ok ->
      module = guardrail_module(guardrail)

      case module.validate(content, guardrail) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp guardrail_module(%module{}) when is_atom(module), do: module
  defp guardrail_module(module) when is_atom(module), do: module
end

defmodule ADK.Guardrail.ContentFilter do
  @moduledoc """
  Guardrail that blocks content matching specified patterns.

  ADK Elixir extension — no Python ADK equivalent exists.

  ## Examples

      iex> g = ADK.Guardrail.ContentFilter.new(patterns: [~r/password/i])
      iex> ADK.Guardrail.ContentFilter.validate("my password is 123", g)
      {:error, "Content matched blocked pattern: ~r/password/i"}

      iex> g = ADK.Guardrail.ContentFilter.new(patterns: [~r/password/i])
      iex> ADK.Guardrail.ContentFilter.validate("hello world", g)
      :ok
  """

  @behaviour ADK.Guardrail

  defstruct patterns: [], blocked_words: []

  @doc "Create a new ContentFilter guardrail."
  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []) do
    %__MODULE__{
      patterns: opts[:patterns] || [],
      blocked_words: opts[:blocked_words] || []
    }
  end

  @impl true
  def validate(content, %__MODULE__{} = config) do
    with :ok <- check_patterns(content, config.patterns),
         :ok <- check_words(content, config.blocked_words) do
      :ok
    end
  end

  defp check_patterns(_content, []), do: :ok

  defp check_patterns(content, [pattern | rest]) do
    if Regex.match?(pattern, content) do
      {:error, "Content matched blocked pattern: #{inspect(pattern)}"}
    else
      check_patterns(content, rest)
    end
  end

  defp check_words(_content, []), do: :ok

  defp check_words(content, [word | rest]) do
    if String.contains?(String.downcase(content), String.downcase(word)) do
      {:error, "Content contains blocked word: #{word}"}
    else
      check_words(content, rest)
    end
  end
end

defmodule ADK.Guardrail.Schema do
  @moduledoc """
  Guardrail that validates output is valid JSON matching expected keys.

  ADK Elixir extension — no Python ADK equivalent exists.

  ## Examples

      iex> g = ADK.Guardrail.Schema.new(required_keys: ["summary", "confidence"])
      iex> ADK.Guardrail.Schema.validate(~s({"summary": "hi", "confidence": 0.9}), g)
      :ok

      iex> g = ADK.Guardrail.Schema.new(required_keys: ["summary"])
      iex> ADK.Guardrail.Schema.validate("not json", g)
      {:error, "Output is not valid JSON"}
  """

  @behaviour ADK.Guardrail

  defstruct required_keys: []

  @doc "Create a new Schema guardrail."
  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []) do
    %__MODULE__{
      required_keys: opts[:required_keys] || []
    }
  end

  @impl true
  def validate(content, %__MODULE__{} = config) do
    case Jason.decode(content) do
      {:ok, data} when is_map(data) ->
        missing = Enum.filter(config.required_keys, &(not Map.has_key?(data, &1)))

        if missing == [] do
          :ok
        else
          {:error, "Missing required keys: #{Enum.join(missing, ", ")}"}
        end

      {:ok, _} ->
        {:error, "Output is not a JSON object"}

      {:error, _} ->
        {:error, "Output is not valid JSON"}
    end
  end
end
