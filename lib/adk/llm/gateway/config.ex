defmodule ADK.LLM.Gateway.Config do
  @moduledoc """
  Configuration parsing and validation for LLM Gateway.

  ADK Elixir extension — no Python equivalent.
  """

  alias ADK.LLM.Gateway.Auth

  defstruct [:backends]

  @type t :: %__MODULE__{backends: [backend_config()]}

  @type backend_config :: %{
          id: atom(),
          backend: module(),
          model: String.t(),
          auth: Auth.t() | [Auth.t()],
          priority: integer(),
          retry: keyword(),
          circuit_breaker: keyword(),
          rate_limit: map() | nil,
          base_url: String.t() | nil
        }

  @required_keys [:id, :backend, :model, :auth]

  @doc "Validates config, raising on errors."
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{backends: backends} = config) do
    if backends == nil or backends == [] do
      raise ArgumentError, "gateway config requires at least one backend"
    end

    Enum.each(backends, &validate_backend!/1)

    ids = Enum.map(backends, & &1.id)

    if length(ids) != length(Enum.uniq(ids)) do
      raise ArgumentError, "duplicate backend ids found: #{inspect(ids -- Enum.uniq(ids))}"
    end

    config
  end

  @doc "Parses config from keyword list (application env format)."
  @spec from_keyword(keyword()) :: t()
  def from_keyword(kw) do
    backends =
      Keyword.get(kw, :backends, [])
      |> Enum.map(&normalize_backend/1)

    %__MODULE__{backends: backends}
  end

  # -- Private --

  defp validate_backend!(backend) do
    Enum.each(@required_keys, fn key ->
      unless Map.has_key?(backend, key) and Map.get(backend, key) != nil do
        raise ArgumentError, "backend missing required key: #{key}"
      end
    end)

    unless is_atom(backend.id) do
      raise ArgumentError, "backend :id must be an atom, got: #{inspect(backend.id)}"
    end

    unless is_atom(backend.backend) do
      raise ArgumentError, "backend :backend must be a module, got: #{inspect(backend.backend)}"
    end

    case Code.ensure_loaded(backend.backend) do
      {:module, _} -> :ok
      {:error, _} -> raise ArgumentError, "backend module #{inspect(backend.backend)} is not available"
    end

    priority = Map.get(backend, :priority, 1)
    unless is_integer(priority) do
      raise ArgumentError, "backend :priority must be an integer, got: #{inspect(priority)}"
    end

    :ok
  end

  defp normalize_backend(backend) when is_map(backend) do
    backend
    |> Map.put_new(:priority, 1)
    |> Map.put_new(:retry, [])
    |> Map.put_new(:circuit_breaker, [])
    |> Map.put_new(:rate_limit, nil)
    |> Map.put_new(:base_url, nil)
  end

  defp normalize_backend(kw) when is_list(kw) do
    kw |> Map.new() |> normalize_backend()
  end
end
