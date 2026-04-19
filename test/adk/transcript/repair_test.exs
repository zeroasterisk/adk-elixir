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
        %{
          role: :user,
          parts: [%{function_response: %{id: "fc-1", name: "search", response: %{"ok" => true}}}]
        }
      ]

      assert Repair.repair(messages) == messages
    end

    test "synthesises response for a single orphaned call" do
      messages = [
        %{role: :user, parts: [%{text: "hello"}]},
        %{
          role: :model,
          parts: [%{function_call: %{id: "fc-1", name: "search", args: %{"q" => "elixir"}}}]
        }
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
        %{
          role: :model,
          parts: [
            %{function_call: %{id: "fc-1", name: "search", args: %{}}},
            %{function_call: %{id: "fc-2", name: "fetch", args: %{}}}
          ]
        }
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
        %{
          role: :model,
          parts: [
            %{function_call: %{id: "fc-1", name: "search", args: %{}}},
            %{function_call: %{id: "fc-2", name: "fetch", args: %{}}}
          ]
        },
        %{
          role: :user,
          parts: [
            %{function_response: %{id: "fc-1", name: "search", response: %{"ok" => true}}}
          ]
        }
      ]

      repaired = Repair.repair(messages)
      # Synthetic response is now inserted immediately after the model turn
      # Result: [model(fc-1, fc-2), user(synthetic fc-2), user(response fc-1)]
      assert length(repaired) == 3

      # The synthetic for fc-2 should be the second message (index 1)
      synthetic = Enum.at(repaired, 1)
      assert synthetic.role == :user
      assert [%{function_response: fr}] = synthetic.parts
      assert fr.id == "fc-2"
      assert fr.name == "fetch"

      # The original response for fc-1 should be the third message
      original_response = Enum.at(repaired, 2)
      assert original_response.role == :user
      assert [%{function_response: fr}] = original_response.parts
      assert fr.id == "fc-1"
    end

    test "matches by id when ids are present" do
      messages = [
        %{role: :model, parts: [%{function_call: %{id: "abc", name: "tool_a", args: %{}}}]},
        %{
          role: :user,
          parts: [%{function_response: %{id: "abc", name: "tool_a", response: "ok"}}]
        }
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
      # Synthetic response is inserted immediately after the model turn
      # Result: [model(tool_a), user(synthetic tool_a), user(response tool_b)]
      assert length(repaired) == 3

      # The synthetic for tool_a should be the second message (index 1)
      synthetic = Enum.at(repaired, 1)
      assert synthetic.role == :user
      [%{function_response: fr}] = synthetic.parts
      assert fr.name == "tool_a"
      refute Map.has_key?(fr, :id)

      # The original response for tool_b should be the third message
      original_response = Enum.at(repaired, 2)
      assert [%{function_response: fr}] = original_response.parts
      assert fr.name == "tool_b"
    end

    test "text-only messages pass through unchanged" do
      messages = [
        %{role: :user, parts: [%{text: "hello"}]},
        %{role: :model, parts: [%{text: "hi there"}]}
      ]

      assert Repair.repair(messages) == messages
    end
  end

  describe "merge_consecutive_roles/1" do
    test "returns empty list unchanged" do
      assert Repair.merge_consecutive_roles([]) == []
    end

    test "single message list unchanged" do
      messages = [%{role: :user, parts: [%{text: "hello"}]}]
      assert Repair.merge_consecutive_roles(messages) == messages
    end

    test "two consecutive model turns get merged" do
      messages = [
        %{role: :model, parts: [%{text: "first"}]},
        %{role: :model, parts: [%{text: "second"}]}
      ]

      result = Repair.merge_consecutive_roles(messages)
      assert length(result) == 1
      assert [%{role: :model, parts: [%{text: "first"}, %{text: "second"}]}] = result
    end

    test "two consecutive user turns get merged" do
      messages = [
        %{role: :user, parts: [%{text: "a"}]},
        %{role: :user, parts: [%{text: "b"}]}
      ]

      result = Repair.merge_consecutive_roles(messages)
      assert length(result) == 1
      assert [%{role: :user, parts: [%{text: "a"}, %{text: "b"}]}] = result
    end

    test "three+ consecutive same-role turns all merge" do
      messages = [
        %{role: :model, parts: [%{text: "a"}]},
        %{role: :model, parts: [%{text: "b"}]},
        %{role: :model, parts: [%{text: "c"}]}
      ]

      result = Repair.merge_consecutive_roles(messages)
      assert length(result) == 1
      assert [%{role: :model, parts: [%{text: "a"}, %{text: "b"}, %{text: "c"}]}] = result
    end

    test "mixed: user, model, model, user -> user, model, user" do
      messages = [
        %{role: :user, parts: [%{text: "u1"}]},
        %{role: :model, parts: [%{text: "m1"}]},
        %{role: :model, parts: [%{text: "m2"}]},
        %{role: :user, parts: [%{text: "u2"}]}
      ]

      result = Repair.merge_consecutive_roles(messages)
      assert length(result) == 3
      assert [
        %{role: :user, parts: [%{text: "u1"}]},
        %{role: :model, parts: [%{text: "m1"}, %{text: "m2"}]},
        %{role: :user, parts: [%{text: "u2"}]}
      ] = result
    end

    test "alternating roles unchanged" do
      messages = [
        %{role: :user, parts: [%{text: "u"}]},
        %{role: :model, parts: [%{text: "m"}]},
        %{role: :user, parts: [%{text: "u2"}]}
      ]

      assert Repair.merge_consecutive_roles(messages) == messages
    end
  end

  describe "repair/1 with consecutive roles" do
    test "consecutive model turns with function_call get merged then orphan repaired" do
      messages = [
        %{role: :user, parts: [%{text: "hello"}]},
        %{role: :model, parts: [%{text: "thinking..."}]},
        %{role: :model, parts: [%{function_call: %{id: "fc-1", name: "search", args: %{}}}]}
      ]

      repaired = Repair.repair(messages)

      # After merge: user, model (with text + function_call)
      # After orphan repair: user, model, user (synthetic response)
      assert length(repaired) == 3

      merged_model = Enum.at(repaired, 1)
      assert merged_model.role == :model
      assert length(merged_model.parts) == 2

      synthetic = List.last(repaired)
      assert synthetic.role == :user
      assert [%{function_response: fr}] = synthetic.parts
      assert fr.id == "fc-1"
    end
  end

  describe "orphaned_calls/1" do
    test "returns empty list when no orphans" do
      messages = [
        %{role: :model, parts: [%{function_call: %{id: "fc-1", name: "search", args: %{}}}]},
        %{
          role: :user,
          parts: [%{function_response: %{id: "fc-1", name: "search", response: "ok"}}]
        }
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
