defmodule ADK.Transcript.RepairTest do
  use ExUnit.Case, async: true

  alias ADK.Transcript.Repair

  describe "repair/1" do
    test "returns empty list unchanged" do
      assert Repair.repair([]) == []
    end

    test "no-op when there are no orphaned calls" do
      messages = [
        %{role: :model, parts: [%{function_call: %{id: "fc-1", name: "search", args: %{}}}]},
        %{role: :user, parts: [%{function_response: %{id: "fc-1", name: "search", response: %{"ok" => true}}}]}
      ]

      assert Repair.repair(messages) == messages
    end

    test "synthesises response for a single orphaned call" do
      messages = [
        %{role: :user, parts: [%{text: "hello"}]},
        %{role: :model, parts: [%{function_call: %{id: "fc-1", name: "search", args: %{"q" => "elixir"}}}]}
      ]

      repaired = Repair.repair(messages)
      assert length(repaired) == 3

      synthetic = List.last(repaired)
      assert synthetic.role == :user
      assert length(synthetic.parts) == 1

      [%{function_response: fr}] = synthetic.parts
      assert fr.id == "fc-1"
      assert fr.name == "search"
      assert fr.response.error =~ "interrupted"
    end

    test "synthesises responses for multiple orphaned calls" do
      messages = [
        %{role: :model, parts: [
          %{function_call: %{id: "fc-1", name: "search", args: %{}}},
          %{function_call: %{id: "fc-2", name: "fetch", args: %{}}}
        ]}
      ]

      repaired = Repair.repair(messages)
      synthetic = List.last(repaired)
      assert length(synthetic.parts) == 2

      names = Enum.map(synthetic.parts, fn %{function_response: fr} -> fr.name end)
      assert "search" in names
      assert "fetch" in names
    end

    test "handles mixed matched and orphaned calls" do
      messages = [
        %{role: :model, parts: [
          %{function_call: %{id: "fc-1", name: "search", args: %{}}},
          %{function_call: %{id: "fc-2", name: "fetch", args: %{}}}
        ]},
        %{role: :user, parts: [
          %{function_response: %{id: "fc-1", name: "search", response: %{"ok" => true}}}
        ]}
      ]

      repaired = Repair.repair(messages)
      assert length(repaired) == 3

      synthetic = List.last(repaired)
      assert [%{function_response: fr}] = synthetic.parts
      assert fr.id == "fc-2"
      assert fr.name == "fetch"
    end

    test "matches by id when ids are present" do
      messages = [
        %{role: :model, parts: [%{function_call: %{id: "abc", name: "tool_a", args: %{}}}]},
        %{role: :user, parts: [%{function_response: %{id: "abc", name: "tool_a", response: "ok"}}]}
      ]

      assert Repair.repair(messages) == messages
    end

    test "falls back to name-based matching when no ids" do
      messages = [
        %{role: :model, parts: [%{function_call: %{name: "tool_a", args: %{}}}]},
        %{role: :user, parts: [%{function_response: %{name: "tool_a", response: "ok"}}]}
      ]

      assert Repair.repair(messages) == messages
    end

    test "name-based fallback detects orphan when names differ" do
      messages = [
        %{role: :model, parts: [%{function_call: %{name: "tool_a", args: %{}}}]},
        %{role: :user, parts: [%{function_response: %{name: "tool_b", response: "ok"}}]}
      ]

      repaired = Repair.repair(messages)
      assert length(repaired) == 3

      synthetic = List.last(repaired)
      [%{function_response: fr}] = synthetic.parts
      assert fr.name == "tool_a"
      refute Map.has_key?(fr, :id)
    end

    test "text-only messages pass through unchanged" do
      messages = [
        %{role: :user, parts: [%{text: "hello"}]},
        %{role: :model, parts: [%{text: "hi there"}]}
      ]

      assert Repair.repair(messages) == messages
    end
  end

  describe "orphaned_calls/1" do
    test "returns empty list when no orphans" do
      messages = [
        %{role: :model, parts: [%{function_call: %{id: "fc-1", name: "search", args: %{}}}]},
        %{role: :user, parts: [%{function_response: %{id: "fc-1", name: "search", response: "ok"}}]}
      ]

      assert Repair.orphaned_calls(messages) == []
    end

    test "returns orphaned function_call parts" do
      messages = [
        %{role: :model, parts: [%{function_call: %{id: "fc-1", name: "search", args: %{}}}]}
      ]

      orphans = Repair.orphaned_calls(messages)
      assert length(orphans) == 1
      assert %{function_call: %{id: "fc-1", name: "search"}} = hd(orphans)
    end

    test "returns empty list for empty messages" do
      assert Repair.orphaned_calls([]) == []
    end
  end
end
