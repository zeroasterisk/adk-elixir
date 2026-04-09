defmodule ADK.Tool.GoogleSearchTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.GoogleSearch

  describe "new/0" do
    test "creates a GoogleSearch struct" do
      tool = GoogleSearch.new()
      assert %GoogleSearch{} = tool
      assert tool.name == "google_search"
      assert tool.__builtin__ == :google_search
    end
  end

  describe "ADK.Tool.declaration/1" do
    test "declaration preserves __builtin__ marker" do
      tool = GoogleSearch.new()
      decl = ADK.Tool.declaration(tool)
      assert decl.__builtin__ == :google_search
      assert decl.name == "google_search"
    end
  end

  describe "ADK.Tool.builtin?/1" do
    test "returns true for GoogleSearch" do
      tool = GoogleSearch.new()
      assert ADK.Tool.builtin?(tool)
    end

    test "returns false for FunctionTool" do
      tool = ADK.Tool.FunctionTool.new(:foo, description: "bar", func: fn _, _ -> {:ok, "hi"} end)
      refute ADK.Tool.builtin?(tool)
    end
  end

  describe "run/2" do
    test "returns error (stub — native tool)" do
      _tool = GoogleSearch.new()
      assert {:error, msg} = GoogleSearch.run(nil, %{})
      assert msg =~ "built-in"
    end
  end
end
