defmodule ADK.Plugin.ContextFilterTest do
  use ExUnit.Case, async: true

  alias ADK.Plugin.ContextFilter
  alias ADK.Models.LlmRequest

  defp create_content(role, text) do
    %{role: role, parts: [%{text: text}]}
  end

  defp create_function_call_content(name, call_id) do
    %{
      role: "model",
      parts: [
        %{function_call: %{id: call_id, name: name, args: %{}}}
      ]
    }
  end

  defp create_function_response_content(name, call_id) do
    %{
      role: "user",
      parts: [
        %{function_response: %{id: call_id, name: name, response: %{"result" => "ok"}}}
      ]
    }
  end

  describe "ContextFilter plugin" do
    test "test_filter_last_n_invocations" do
      {:ok, state} = ContextFilter.init(num_invocations_to_keep: 1)
      Process.put({ContextFilter, :config}, state)

      contents = [
        create_content("user", "user_prompt_1"),
        create_content("model", "model_response_1"),
        create_content("user", "user_prompt_2"),
        create_content("model", "model_response_2")
      ]

      req = %LlmRequest{contents: contents}

      {:ok, updated_req} = ContextFilter.before_model(%{}, req)

      assert length(updated_req.contents) == 2
      assert Enum.at(updated_req.contents, 0).parts == [%{text: "user_prompt_2"}]
      assert Enum.at(updated_req.contents, 1).parts == [%{text: "model_response_2"}]
    end

    test "test_filter_with_function" do
      filter_fn = fn contents ->
        Enum.filter(contents, fn c -> c.role != "model" end)
      end

      {:ok, state} = ContextFilter.init(custom_filter: filter_fn)
      Process.put({ContextFilter, :config}, state)

      contents = [
        create_content("user", "user_prompt_1"),
        create_content("model", "model_response_1"),
        create_content("user", "user_prompt_2"),
        create_content("model", "model_response_2")
      ]

      req = %LlmRequest{contents: contents}

      {:ok, updated_req} = ContextFilter.before_model(%{}, req)

      assert length(updated_req.contents) == 2
      assert Enum.all?(updated_req.contents, fn c -> c.role == "user" end)
    end

    test "test_filter_with_function_and_last_n_invocations" do
      filter_fn = fn contents -> Enum.drop(contents, 2) end

      {:ok, state} = ContextFilter.init(num_invocations_to_keep: 1, custom_filter: filter_fn)
      Process.put({ContextFilter, :config}, state)

      contents = [
        create_content("user", "user_prompt_1"),
        create_content("model", "model_response_1"),
        create_content("user", "user_prompt_2"),
        create_content("model", "model_response_2"),
        create_content("user", "user_prompt_3"),
        create_content("model", "model_response_3")
      ]

      req = %LlmRequest{contents: contents}

      {:ok, updated_req} = ContextFilter.before_model(%{}, req)

      assert length(updated_req.contents) == 0
    end

    test "test_no_filtering_when_no_options_provided" do
      {:ok, state} = ContextFilter.init([])
      Process.put({ContextFilter, :config}, state)

      contents = [
        create_content("user", "user_prompt_1"),
        create_content("model", "model_response_1")
      ]

      req = %LlmRequest{contents: contents}

      {:ok, updated_req} = ContextFilter.before_model(%{}, req)

      assert updated_req.contents == contents
    end

    test "test_last_n_invocations_with_multiple_user_turns" do
      {:ok, state} = ContextFilter.init(num_invocations_to_keep: 1)
      Process.put({ContextFilter, :config}, state)

      contents = [
        create_content("user", "user_prompt_1"),
        create_content("model", "model_response_1"),
        create_content("user", "user_prompt_2a"),
        create_content("user", "user_prompt_2b"),
        create_content("model", "model_response_2")
      ]

      req = %LlmRequest{contents: contents}

      {:ok, updated_req} = ContextFilter.before_model(%{}, req)

      assert length(updated_req.contents) == 3
      assert Enum.at(updated_req.contents, 0).parts == [%{text: "user_prompt_2a"}]
      assert Enum.at(updated_req.contents, 1).parts == [%{text: "user_prompt_2b"}]
    end

    test "test_last_n_invocations_more_than_existing_invocations" do
      {:ok, state} = ContextFilter.init(num_invocations_to_keep: 3)
      Process.put({ContextFilter, :config}, state)

      contents = [
        create_content("user", "user_prompt_1"),
        create_content("model", "model_response_1"),
        create_content("user", "user_prompt_2"),
        create_content("model", "model_response_2")
      ]

      req = %LlmRequest{contents: contents}

      {:ok, updated_req} = ContextFilter.before_model(%{}, req)

      assert updated_req.contents == contents
    end

    test "test_filter_function_raises_exception" do
      filter_fn = fn _contents -> raise "Filter error" end

      {:ok, state} = ContextFilter.init(custom_filter: filter_fn)
      Process.put({ContextFilter, :config}, state)

      contents = [
        create_content("user", "user_prompt_1"),
        create_content("model", "model_response_1")
      ]

      req = %LlmRequest{contents: contents}

      {:ok, updated_req} = ContextFilter.before_model(%{}, req)

      assert updated_req.contents == contents
    end

    test "test_filter_preserves_function_call_response_pairs" do
      {:ok, state} = ContextFilter.init(num_invocations_to_keep: 2)
      Process.put({ContextFilter, :config}, state)

      contents = [
        create_content("user", "Hello"),
        create_content("model", "Hi there!"),
        create_content("user", "I want to know about X"),
        create_function_call_content("knowledge_base", "call_1"),
        create_function_response_content("knowledge_base", "call_1"),
        create_content("model", "I found some information..."),
        create_content("user", "can you explain more about Y"),
        create_function_call_content("knowledge_base", "call_2"),
        create_function_response_content("knowledge_base", "call_2")
      ]

      req = %LlmRequest{contents: contents}

      {:ok, updated_req} = ContextFilter.before_model(%{}, req)

      call_ids =
        MapSet.new(
          for content <- updated_req.contents,
              part <- Map.get(content, :parts, []),
              Map.has_key?(part, :function_call) do
            part.function_call.id
          end
        )

      response_ids =
        MapSet.new(
          for content <- updated_req.contents,
              part <- Map.get(content, :parts, []),
              Map.has_key?(part, :function_response) do
            part.function_response.id
          end
        )

      assert MapSet.subset?(response_ids, call_ids)
    end

    test "test_filter_with_nested_function_calls" do
      {:ok, state} = ContextFilter.init(num_invocations_to_keep: 1)
      Process.put({ContextFilter, :config}, state)

      contents = [
        create_content("user", "Hello"),
        create_content("model", "Hi!"),
        create_content("user", "Do task"),
        create_function_call_content("tool_a", "call_a"),
        create_function_response_content("tool_a", "call_a"),
        create_function_call_content("tool_b", "call_b"),
        create_function_response_content("tool_b", "call_b"),
        create_content("model", "Done with tasks")
      ]

      req = %LlmRequest{contents: contents}

      {:ok, updated_req} = ContextFilter.before_model(%{}, req)

      call_ids =
        MapSet.new(
          for content <- updated_req.contents,
              part <- Map.get(content, :parts, []),
              Map.has_key?(part, :function_call) do
            part.function_call.id
          end
        )

      response_ids =
        MapSet.new(
          for content <- updated_req.contents,
              part <- Map.get(content, :parts, []),
              Map.has_key?(part, :function_response) do
            part.function_response.id
          end
        )

      texts =
        for content <- updated_req.contents,
            part <- Map.get(content, :parts, []),
            Map.has_key?(part, :text) do
          part.text
        end

      assert "Do task" in texts
      assert "Done with tasks" in texts
      assert "Hello" not in texts
      assert "Hi!" not in texts

      assert MapSet.subset?(response_ids, call_ids)
    end

    test "test_last_invocation_with_tool_call_keeps_user_prompt" do
      {:ok, state} = ContextFilter.init(num_invocations_to_keep: 1)
      Process.put({ContextFilter, :config}, state)

      contents = [
        create_content("user", "user_prompt_1"),
        create_content("model", "model_response_1"),
        create_content("user", "user_prompt_2"),
        create_function_call_content("get_weather", "call_1"),
        create_function_response_content("get_weather", "call_1"),
        create_content("model", "final_answer_2")
      ]

      req = %LlmRequest{contents: contents}

      {:ok, updated_req} = ContextFilter.before_model(%{}, req)

      texts =
        for content <- updated_req.contents,
            part <- Map.get(content, :parts, []),
            Map.has_key?(part, :text) do
          part.text
        end

      assert "user_prompt_2" in texts
      assert "final_answer_2" in texts
    end
  end
end
