defmodule ADK.Session.Store.Ecto.DynamicTermTypeTest do
  use ExUnit.Case, async: true

  alias ADK.Session.Store.Ecto.DynamicTermType

  describe "type/0" do
    test "returns :binary" do
      assert DynamicTermType.type() == :binary
    end
  end

  describe "cast/1" do
    test "accepts any term" do
      term = %{"key" => "value", "nested" => [1, 2, 3]}
      assert {:ok, ^term} = DynamicTermType.cast(term)
    end

    test "handles nil" do
      assert {:ok, nil} = DynamicTermType.cast(nil)
    end
  end

  describe "dump/1" do
    test "serializes term to binary" do
      term = %{"key" => "value", "nested" => [1, 2, 3]}
      assert {:ok, binary} = DynamicTermType.dump(term)
      assert is_binary(binary)
      assert :erlang.binary_to_term(binary) == term
    end

    test "handles nil" do
      assert {:ok, nil} = DynamicTermType.dump(nil)
    end
  end

  describe "load/1" do
    test "deserializes binary to term" do
      term = %{"key" => "value", "nested" => [1, 2, 3]}
      binary = :erlang.term_to_binary(term)

      assert {:ok, ^term} = DynamicTermType.load(binary)
    end

    test "handles nil" do
      assert {:ok, nil} = DynamicTermType.load(nil)
    end

    test "falls back safely if not an erlang term" do
      # If for some reason we load a string that isn't a valid term binary
      str = "just a string"
      assert {:ok, "just a string"} = DynamicTermType.load(str)
    end
  end

  describe "roundtrip parity (test_dynamic_pickle_type.py equivalent)" do
    test "simulates full bind and result mapping" do
      original_data = %{
        "string" => "test",
        "number" => 42,
        "list" => [1, 2, 3],
        "nested" => %{"a" => 1, "b" => 2},
        # Elixir specific: tuples which wouldn't normally serialize in JSON easily
        "tuple" => {:ok, :tuple_supported}
      }

      # Simulate bind (Python process_bind_param -> DB)
      assert {:ok, bound_value} = DynamicTermType.dump(original_data)
      assert is_binary(bound_value)

      # Simulate result (DB process_result_value -> Python)
      assert {:ok, result_value} = DynamicTermType.load(bound_value)
      assert result_value == original_data
    end
  end
end
