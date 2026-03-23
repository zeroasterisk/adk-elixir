defmodule ADK.Utils.Common do
  @moduledoc """
  Core common utility functions.
  Includes formatting, date/time utilities, and map manipulation functions.
  """

  @doc """
  Formats a `DateTime` struct as an ISO8601 string.
  Returns the current time in ISO8601 if given something else.
  """
  @spec format_timestamp(DateTime.t() | any()) :: String.t()
  def format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def format_timestamp(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc """
  Parses an ISO8601 string into a `DateTime` struct.
  Returns `DateTime.utc_now()` if parsing fails.
  """
  @spec parse_timestamp(String.t() | any()) :: DateTime.t()
  def parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  def parse_timestamp(_), do: DateTime.utc_now()

  @doc """
  Recursively updates a map (deep merge).
  """
  @spec recursive_map_update(map(), map()) :: map()
  def recursive_map_update(target, update) when is_map(target) and is_map(update) do
    Map.merge(target, update, fn _key, target_val, update_val ->
      if is_map(target_val) and is_map(update_val) do
        recursive_map_update(target_val, update_val)
      else
        update_val
      end
    end)
  end

  @doc """
  Converts a string to snake_case.
  """
  @spec to_snake_case(String.t()) :: String.t()
  def to_snake_case(str) when is_binary(str) do
    str
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.replace(~r/([a-z\d])([A-Z])/, "\\1_\\2")
    |> String.replace(~r/[-\s]+/, "_")
    |> String.downcase()
  end

  @doc """
  Converts a string to camelCase.
  """
  @spec to_camel_case(String.t()) :: String.t()
  def to_camel_case(str) when is_binary(str) do
    str
    |> to_snake_case()
    |> String.split("_", trim: true)
    |> Enum.with_index()
    |> Enum.map(fn
      {word, 0} -> String.downcase(word)
      {word, _} -> String.capitalize(word)
    end)
    |> Enum.join()
  end
end
