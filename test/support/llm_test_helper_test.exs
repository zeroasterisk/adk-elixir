defmodule ADK.LLM.TestHelperTest do
  use ExUnit.Case, async: true
  use ADK.LLM.TestHelper

  describe "mock_response/1" do
    test "builds a text response" do
      assert {:ok, %{content: %{role: :model, parts: [%{text: "hello"}]}}} =
               mock_response("hello")
    end
  end

  describe "mock_tool_call/2" do
    test "builds a function call response" do
      assert {:ok, %{content: %{parts: [%{function_call: %{name: "search", args: %{"q" => "x"}}}]}}} =
               mock_tool_call("search", %{"q" => "x"})
    end
  end

  describe "mock_error/1" do
    test "builds an error tuple" do
      assert {:error, :rate_limited} = mock_error(:rate_limited)
    end
  end

  describe "setup_mock_llm/1 with MockBackend" do
    test "returns responses in order" do
      setup_mock_llm([
        mock_response("first"),
        mock_response("second"),
        mock_error(:boom)
      ])

      assert {:ok, %{content: %{parts: [%{text: "first"}]}}} =
               ADK.LLM.MockBackend.generate("model", %{})

      assert {:ok, %{content: %{parts: [%{text: "second"}]}}} =
               ADK.LLM.MockBackend.generate("model", %{})

      assert {:error, :boom} = ADK.LLM.MockBackend.generate("model", %{})

      assert call_count() == 3
      assert_called(3)

      last = last_call()
      assert last.model == "model"
    end

    test "echoes when responses exhausted" do
      setup_mock_llm([])

      assert {:ok, %{content: %{parts: [%{text: "Mock: " <> _}]}}} =
               ADK.LLM.MockBackend.generate("m", %{messages: [%{role: :user, parts: [%{text: "hi"}]}]})
    end
  end

  describe "compatibility with ADK.LLM.Mock" do
    test "set_responses also populates process dictionary mock" do
      setup_mock_llm([mock_response("via helper")])

      # The process-dict mock should also have the response
      assert {:ok, %{content: %{parts: [%{text: "via helper"}]}}} =
               ADK.LLM.Mock.generate("model", %{})
    end
  end
end
