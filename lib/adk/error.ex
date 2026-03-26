# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Error do
  @moduledoc """
  Structured error types for the ADK.

  Provides a consistent exception struct with error codes, categories,
  recovery hints, and cause chaining. Useful for both internal error
  handling and A2A error responses.

  ## Examples

      iex> error = ADK.Error.new(:llm_timeout, "Model timed out after 30s")
      iex> error.code
      :llm_timeout
      iex> error.category
      :llm
      iex> ADK.Error.retryable?(error)
      true

      iex> error = ADK.Error.tool_error("Calculator crashed", details: %{tool: "calc"})
      iex> error.category
      :tool
      iex> error.details
      %{tool: "calc"}
  """

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          category: atom(),
          recovery: String.t() | nil,
          details: map(),
          cause: any()
        }

  defexception code: :unknown,
               message: "",
               category: :internal,
               recovery: nil,
               details: %{},
               cause: nil

  @retryable_codes MapSet.new([:llm_timeout, :rate_limited])
  @retryable_categories MapSet.new([:network])

  @category_prefixes ~w(llm tool auth config session workflow network internal)a

  @doc """
  Builds a new `ADK.Error` struct.

  Category is auto-inferred from the code prefix when not provided.
  """
  @spec new(atom(), String.t(), keyword()) :: t()
  def new(code, message, opts \\ []) do
    category = Keyword.get(opts, :category) || infer_category(code)

    %__MODULE__{
      code: code,
      message: message,
      category: category,
      recovery: Keyword.get(opts, :recovery),
      details: Keyword.get(opts, :details, %{}),
      cause: Keyword.get(opts, :cause)
    }
  end

  @doc """
  Wraps an existing error as the cause of a new `ADK.Error`.
  """
  @spec wrap(atom(), String.t(), any(), keyword()) :: t()
  def wrap(code, message, original_error, opts \\ []) do
    new(code, message, Keyword.put(opts, :cause, original_error))
  end

  @doc "Shortcut for creating an error with category `:llm`."
  @spec llm_error(String.t(), keyword()) :: t()
  def llm_error(message, opts \\ []) do
    code = Keyword.get(opts, :code, :llm_error)
    new(code, message, Keyword.put(opts, :category, :llm))
  end

  @doc "Shortcut for creating an error with category `:tool`."
  @spec tool_error(String.t(), keyword()) :: t()
  def tool_error(message, opts \\ []) do
    code = Keyword.get(opts, :code, :tool_error)
    new(code, message, Keyword.put(opts, :category, :tool))
  end

  @doc "Shortcut for creating an error with category `:config`."
  @spec config_error(String.t(), keyword()) :: t()
  def config_error(message, opts \\ []) do
    code = Keyword.get(opts, :code, :config_error)
    new(code, message, Keyword.put(opts, :category, :config))
  end

  @doc "Shortcut for creating an error with category `:auth`."
  @spec auth_error(String.t(), keyword()) :: t()
  def auth_error(message, opts \\ []) do
    code = Keyword.get(opts, :code, :auth_error)
    new(code, message, Keyword.put(opts, :category, :auth))
  end

  @doc """
  Returns `true` if the error is retryable.

  Retryable errors include `:llm_timeout`, `:rate_limited` codes,
  and any error in the `:network` category.
  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{code: code, category: category}) do
    MapSet.member?(@retryable_codes, code) or MapSet.member?(@retryable_categories, category)
  end

  @doc """
  Serializes the error to a map, useful for A2A error responses.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    map = %{
      code: error.code,
      message: error.message,
      category: error.category,
      details: error.details
    }

    map = if error.recovery, do: Map.put(map, :recovery, error.recovery), else: map
    map = if error.cause, do: Map.put(map, :cause, format_cause(error.cause)), else: map
    map
  end

  @impl true
  def message(%__MODULE__{code: code, message: msg, category: category}) do
    "[#{category}:#{code}] #{msg}"
  end

  # --- Private helpers ---

  defp infer_category(code) do
    code_string = Atom.to_string(code)

    Enum.find(@category_prefixes, :internal, fn prefix ->
      String.starts_with?(code_string, Atom.to_string(prefix) <> "_")
    end)
  end

  defp format_cause(%__MODULE__{} = error), do: to_map(error)
  defp format_cause(%{__exception__: true} = error), do: Exception.message(error)
  defp format_cause(other), do: inspect(other)
end
