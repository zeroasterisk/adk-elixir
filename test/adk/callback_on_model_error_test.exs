defmodule ADK.CallbackOnModelErrorTest do
  use ExUnit.Case, async: true

  alias ADK.Callback

  defmodule RetryCallback do
    @behaviour ADK.Callback

    @impl true
    def on_model_error({:error, _reason}, callback_ctx) do
      {:retry, callback_ctx}
    end
  end

  defmodule FallbackCallback do
    @behaviour ADK.Callback

    @impl true
    def on_model_error({:error, _reason}, _callback_ctx) do
      {:fallback, {:ok, %{content: %{role: :model, parts: [%{text: "fallback response"}]}, usage_metadata: nil}}}
    end
  end

  defmodule PassthroughCallback do
    @behaviour ADK.Callback

    @impl true
    def on_model_error({:error, reason}, _callback_ctx) do
      {:error, reason}
    end
  end

  defmodule NoErrorCallback do
    @behaviour ADK.Callback
    # Does not implement on_model_error
  end

  describe "run_on_error/3" do
    test "returns retry when callback says retry" do
      cb_ctx = %{agent: nil, context: nil}
      result = Callback.run_on_error([RetryCallback], {:error, :rate_limited}, cb_ctx)
      assert {:retry, _} = result
    end

    test "returns fallback when callback provides fallback" do
      cb_ctx = %{agent: nil, context: nil}
      result = Callback.run_on_error([FallbackCallback], {:error, :rate_limited}, cb_ctx)
      assert {:fallback, {:ok, response}} = result
      assert response.content.parts == [%{text: "fallback response"}]
    end

    test "passes through error when callback re-raises" do
      cb_ctx = %{agent: nil, context: nil}
      result = Callback.run_on_error([PassthroughCallback], {:error, :boom}, cb_ctx)
      assert {:error, :boom} = result
    end

    test "skips callbacks that don't implement on_model_error" do
      cb_ctx = %{agent: nil, context: nil}
      result = Callback.run_on_error([NoErrorCallback], {:error, :boom}, cb_ctx)
      assert {:error, :boom} = result
    end

    test "first non-error callback wins" do
      cb_ctx = %{agent: nil, context: nil}
      result = Callback.run_on_error([PassthroughCallback, FallbackCallback], {:error, :boom}, cb_ctx)
      assert {:fallback, _} = result
    end
  end
end
