defmodule ADK.LLM.Gateway.Auth do
  @moduledoc """
  Common auth struct for LLM provider credentials.

  ADK Elixir extension — no Python equivalent.

  Supports multiple credential sources: environment variables, static tokens,
  file-based service account keys, and application default credentials (stubbed).
  """

  defstruct [:type, :source, :resolved_token, :expires_at, metadata: %{}]

  @type source ::
          {:env, String.t()}
          | {:static, String.t()}
          | {:file, Path.t()}
          | {:adc, keyword()}

  @type t :: %__MODULE__{
          type: :api_key | :service_account | :bearer | :adc | :proxy_token,
          source: source(),
          resolved_token: String.t() | nil,
          expires_at: DateTime.t() | nil,
          metadata: map()
        }

  @doc "Resolves the auth source to a usable token, returning an updated struct or error."
  @spec resolve(t()) :: {:ok, t()} | {:error, String.t()}
  def resolve(%__MODULE__{source: {:env, var_name}} = auth) do
    case System.get_env(var_name) do
      nil -> {:error, "environment variable #{var_name} is not set"}
      val -> {:ok, %{auth | resolved_token: val}}
    end
  end

  def resolve(%__MODULE__{source: {:static, value}} = auth) do
    {:ok, %{auth | resolved_token: value}}
  end

  def resolve(%__MODULE__{source: {:file, path}} = auth) do
    case File.read(path) do
      {:ok, content} -> {:ok, %{auth | resolved_token: String.trim(content)}}
      {:error, reason} -> {:error, "cannot read file #{path}: #{inspect(reason)}"}
    end
  end

  def resolve(%__MODULE__{source: {:adc, _opts}}) do
    {:error, :not_implemented}
  end

  @doc "Checks if the token is present and not expired."
  @spec resolved?(t()) :: boolean()
  def resolved?(%__MODULE__{resolved_token: nil}), do: false

  def resolved?(%__MODULE__{resolved_token: _, expires_at: nil}), do: true

  def resolved?(%__MODULE__{resolved_token: _, expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  @doc "Converts auth to HTTP headers appropriate for the auth type."
  @spec to_headers(t()) :: [{String.t(), String.t()}]
  def to_headers(%__MODULE__{resolved_token: nil}), do: []

  def to_headers(%__MODULE__{type: :api_key, resolved_token: token}) do
    [{"x-goog-api-key", token}]
  end

  def to_headers(%__MODULE__{resolved_token: token}) do
    [{"Authorization", "Bearer #{token}"}]
  end
end
