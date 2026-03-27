defmodule ADK.GuardrailTest do
  use ExUnit.Case, async: true

  describe "run_all/2" do
    test "returns :ok with no guardrails" do
      assert ADK.Guardrail.run_all([], "anything") == :ok
    end

    test "returns :ok when all pass" do
      g1 = ADK.Guardrail.ContentFilter.new(blocked_words: ["bad"])
      g2 = ADK.Guardrail.ContentFilter.new(blocked_words: ["evil"])
      assert ADK.Guardrail.run_all([g1, g2], "good content") == :ok
    end

    test "returns error on first failure" do
      g1 = ADK.Guardrail.ContentFilter.new(blocked_words: ["bad"])
      g2 = ADK.Guardrail.ContentFilter.new(blocked_words: ["evil"])
      {:error, msg} = ADK.Guardrail.run_all([g1, g2], "this is bad and evil")
      assert msg =~ "bad"
    end
  end

  describe "ContentFilter" do
    test "blocks by word" do
      g = ADK.Guardrail.ContentFilter.new(blocked_words: ["password"])
      assert {:error, _} = ADK.Guardrail.ContentFilter.validate("my password is 123", g)
    end

    test "blocks by pattern" do
      g = ADK.Guardrail.ContentFilter.new(patterns: [~r/\d{3}-\d{2}-\d{4}/])
      assert {:error, _} = ADK.Guardrail.ContentFilter.validate("SSN: 123-45-6789", g)
    end

    test "allows clean content" do
      g = ADK.Guardrail.ContentFilter.new(blocked_words: ["secret"], patterns: [~r/SSN/])
      assert :ok == ADK.Guardrail.ContentFilter.validate("hello world", g)
    end

    test "case-insensitive word matching" do
      g = ADK.Guardrail.ContentFilter.new(blocked_words: ["Password"])
      assert {:error, _} = ADK.Guardrail.ContentFilter.validate("my PASSWORD is 123", g)
    end
  end

  describe "Schema" do
    test "validates JSON with required keys" do
      g = ADK.Guardrail.Schema.new(required_keys: ["name", "age"])
      assert :ok == ADK.Guardrail.Schema.validate(~s({"name": "Zaf", "age": 1}), g)
    end

    test "rejects missing keys" do
      g = ADK.Guardrail.Schema.new(required_keys: ["name", "age"])
      {:error, msg} = ADK.Guardrail.Schema.validate(~s({"name": "Zaf"}), g)
      assert msg =~ "age"
    end

    test "rejects non-JSON" do
      g = ADK.Guardrail.Schema.new(required_keys: ["name"])
      {:error, msg} = ADK.Guardrail.Schema.validate("not json", g)
      assert msg =~ "not valid JSON"
    end

    test "rejects JSON arrays" do
      g = ADK.Guardrail.Schema.new(required_keys: [])
      {:error, msg} = ADK.Guardrail.Schema.validate("[1,2,3]", g)
      assert msg =~ "not a JSON object"
    end
  end
end
