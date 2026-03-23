defmodule ADK.Utils.CommonTest do
  use ExUnit.Case, async: true
  alias ADK.Utils.Common

  describe "date/time utils" do
    test "format_timestamp/1 formats DateTime to ISO8601" do
      dt = ~U[2026-03-23 02:00:00Z]
      assert Common.format_timestamp(dt) == "2026-03-23T02:00:00Z"
    end

    test "format_timestamp/1 handles nil or invalid by returning current time string" do
      result = Common.format_timestamp(nil)
      assert is_binary(result)
      assert {:ok, _, _} = DateTime.from_iso8601(result)
    end

    test "parse_timestamp/1 parses valid ISO8601 string" do
      iso = "2026-03-23T02:00:00Z"
      dt = Common.parse_timestamp(iso)
      assert %DateTime{} = dt
      assert dt.year == 2026
      assert dt.month == 3
      assert dt.day == 23
    end

    test "parse_timestamp/1 handles invalid string by returning current time" do
      dt = Common.parse_timestamp("invalid-date")
      assert %DateTime{} = dt
    end

    test "parse_timestamp/1 handles nil by returning current time" do
      dt = Common.parse_timestamp(nil)
      assert %DateTime{} = dt
    end
  end

  describe "formatting and string manipulation" do
    test "to_snake_case/1 converts camelCase and PascalCase" do
      assert Common.to_snake_case("camelCase") == "camel_case"
      assert Common.to_snake_case("PascalCase") == "pascal_case"
      assert Common.to_snake_case("AlreadySnakeCase") == "already_snake_case"
      assert Common.to_snake_case("some-dashed-string") == "some_dashed_string"
      assert Common.to_snake_case("Some Spaces Here") == "some_spaces_here"
    end

    test "to_camel_case/1 converts snake_case and PascalCase" do
      assert Common.to_camel_case("snake_case") == "snakeCase"
      assert Common.to_camel_case("PascalCase") == "pascalCase"
      assert Common.to_camel_case("already_camelCase") == "alreadyCamelCase"
      assert Common.to_camel_case("some-dashed-string") == "someDashedString"
    end
  end

  describe "map manipulation" do
    test "recursive_map_update/2 deep merges maps" do
      target = %{a: 1, b: %{x: 10, y: 20}}
      update = %{b: %{y: 30, z: 40}, c: 3}
      expected = %{a: 1, b: %{x: 10, y: 30, z: 40}, c: 3}
      assert Common.recursive_map_update(target, update) == expected
    end

    test "recursive_map_update/2 overwrites non-maps with maps and vice versa" do
      target = %{a: 1, b: 2}
      update = %{b: %{x: 10}}
      assert Common.recursive_map_update(target, update) == %{a: 1, b: %{x: 10}}

      target2 = %{a: 1, b: %{x: 10}}
      update2 = %{b: 2}
      assert Common.recursive_map_update(target2, update2) == %{a: 1, b: 2}
    end
  end
end
