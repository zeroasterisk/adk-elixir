defmodule ADK.Session.Store.Ecto.DynamicTermType do
  @moduledoc """
  Parity for Python's DynamicPickleType.

  In Python ADK, DynamicPickleType is a SQLAlchemy type decorator that pickles data 
  specifically for mysql and spanner. In Elixir Ecto, we can provide a generic `Ecto.Type` 
  that serializes arbitrary Elixir terms (like tuples, structs) to `:binary` using 
  `:erlang.term_to_binary/1` and `:erlang.binary_to_term/1`.
  """
  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(term), do: {:ok, term}

  @impl true
  def load(nil), do: {:ok, nil}

  def load(binary) when is_binary(binary) do
    try do
      {:ok, :erlang.binary_to_term(binary)}
    rescue
      # Fallback if it wasn't pickled/term_to_binary'd properly
      _ -> {:ok, binary}
    end
  end

  def load(other), do: {:ok, other}

  @impl true
  def dump(nil), do: {:ok, nil}

  def dump(term) do
    {:ok, :erlang.term_to_binary(term)}
  end
end
