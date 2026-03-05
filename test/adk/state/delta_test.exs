defmodule ADK.State.DeltaTest do
  use ExUnit.Case, async: true
  doctest ADK.State.Delta

  test "diff detects additions" do
    assert ADK.State.Delta.diff(%{}, %{a: 1}) == %{added: %{a: 1}, changed: %{}, removed: []}
  end

  test "diff detects removals" do
    result = ADK.State.Delta.diff(%{a: 1}, %{})
    assert result.removed == [:a]
    assert result.added == %{}
  end

  test "diff detects changes" do
    result = ADK.State.Delta.diff(%{a: 1}, %{a: 2})
    assert result.changed == %{a: 2}
  end

  test "apply_delta applies all operations" do
    delta = %{added: %{c: 3}, changed: %{a: 10}, removed: [:b]}
    assert ADK.State.Delta.apply_delta(%{a: 1, b: 2}, delta) == %{a: 10, c: 3}
  end
end
