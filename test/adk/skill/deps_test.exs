defmodule ADK.Skill.DepsTest do
  use ExUnit.Case, async: true

  alias ADK.Skill.Deps

  describe "check/1" do
    test "returns available and missing deps" do
      {available, missing} = Deps.check(["ls", "nonexistent_binary_xyz_999"])
      assert "ls" in available
      assert "nonexistent_binary_xyz_999" in missing
    end

    test "returns all available when all exist" do
      {available, missing} = Deps.check(["ls"])
      assert available == ["ls"]
      assert missing == []
    end

    test "returns all missing when none exist" do
      {available, missing} = Deps.check(["no_such_bin_aaa", "no_such_bin_bbb"])
      assert available == []
      assert "no_such_bin_aaa" in missing
      assert "no_such_bin_bbb" in missing
    end

    test "returns empty lists for empty input" do
      assert {[], []} = Deps.check([])
    end
  end

  describe "available?/1" do
    test "returns true for a binary that exists" do
      assert Deps.available?("ls")
    end

    test "returns false for a binary that does not exist" do
      refute Deps.available?("nonexistent_binary_xyz_999")
    end

    test "caches results in process dictionary" do
      # Prime the cache
      Deps.available?("ls")
      assert Process.get({:adk_skill_dep, "ls"}) == true

      Deps.available?("nonexistent_binary_xyz_999")
      assert Process.get({:adk_skill_dep, "nonexistent_binary_xyz_999"}) == false
    end
  end
end
