defmodule ADK.FeatureTest do
  use ExUnit.Case, async: false

  alias ADK.Feature

  setup do
    Feature.clear()
    on_exit(fn -> Feature.clear() end)
  end

  describe "enable/1 and enabled?/1" do
    test "single feature can be enabled" do
      refute Feature.enabled?(:json_schema_for_func_decl)
      Feature.enable(:json_schema_for_func_decl)
      assert Feature.enabled?(:json_schema_for_func_decl)
    end

    test "default-on features are enabled without explicit enable" do
      assert Feature.enabled?(:progressive_sse_streaming)
    end

    test "default-off features are disabled without explicit enable" do
      refute Feature.enabled?(:json_schema_for_func_decl)
    end

    test "unknown feature raises ArgumentError" do
      assert_raise ArgumentError, fn -> Feature.enable(:totally_fake_feature) end
      assert_raise ArgumentError, fn -> Feature.enabled?(:totally_fake_feature) end
    end
  end

  describe "disable/1" do
    test "disables a default-on feature" do
      assert Feature.enabled?(:computer_use)
      Feature.disable(:computer_use)
      refute Feature.enabled?(:computer_use)
    end

    test "unknown feature raises ArgumentError" do
      assert_raise ArgumentError, fn -> Feature.disable(:nope) end
    end
  end

  describe "apply_overrides/1" do
    test "single feature name" do
      {:ok, 1} = Feature.apply_overrides("JSON_SCHEMA_FOR_FUNC_DECL")
      assert Feature.enabled?(:json_schema_for_func_decl)
    end

    test "comma-separated features" do
      {:ok, 2} = Feature.apply_overrides("JSON_SCHEMA_FOR_FUNC_DECL,COMPUTER_USE")
      assert Feature.enabled?(:json_schema_for_func_decl)
      assert Feature.enabled?(:computer_use)
    end

    test "whitespace is trimmed" do
      {:ok, 1} = Feature.apply_overrides("  JSON_SCHEMA_FOR_FUNC_DECL  ")
      assert Feature.enabled?(:json_schema_for_func_decl)
    end

    test "empty string is ignored" do
      {:ok, 0} = Feature.apply_overrides("")
    end

    test "empty segments are skipped" do
      {:ok, 1} = Feature.apply_overrides(",JSON_SCHEMA_FOR_FUNC_DECL,,")
      assert Feature.enabled?(:json_schema_for_func_decl)
    end

    test "unknown feature logs warning and is skipped" do
      import ExUnit.CaptureLog
      log = capture_log(fn -> {:ok, 0} = Feature.apply_overrides("TOTALLY_UNKNOWN") end)
      assert log =~ "Unknown feature"
      assert log =~ "TOTALLY_UNKNOWN"
    end

    test "mixed known and unknown" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          {:ok, 1} = Feature.apply_overrides("JSON_SCHEMA_FOR_FUNC_DECL,FAKE_ONE")
        end)

      assert Feature.enabled?(:json_schema_for_func_decl)
      assert log =~ "FAKE_ONE"
    end

    test "case insensitive" do
      {:ok, 1} = Feature.apply_overrides("json_schema_for_func_decl")
      assert Feature.enabled?(:json_schema_for_func_decl)
    end

    test "duplicate features counted once each" do
      {:ok, 2} = Feature.apply_overrides("JSON_SCHEMA_FOR_FUNC_DECL,JSON_SCHEMA_FOR_FUNC_DECL")
      assert Feature.enabled?(:json_schema_for_func_decl)
    end
  end

  describe "clear/0" do
    test "resets all overrides" do
      Feature.enable(:json_schema_for_func_decl)
      assert Feature.enabled?(:json_schema_for_func_decl)
      Feature.clear()
      refute Feature.enabled?(:json_schema_for_func_decl)
    end
  end

  describe "names/0" do
    test "returns list of known feature atoms" do
      names = Feature.names()
      assert is_list(names)
      assert :json_schema_for_func_decl in names
      assert :computer_use in names
    end
  end

  describe "config/1" do
    test "returns config for known feature" do
      config = Feature.config(:json_schema_for_func_decl)
      assert config.stage == :wip
      assert config.default_on == false
    end

    test "returns nil for unknown feature" do
      assert Feature.config(:nope) == nil
    end
  end
end
