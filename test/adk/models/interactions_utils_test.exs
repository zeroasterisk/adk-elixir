defmodule ADK.Models.InteractionsUtilsTest do
  use ExUnit.Case, async: true
  alias ADK.Models.InteractionsUtils

  describe "convert_part_to_interaction_content" do
    test "text part" do
      part = %{text: "Hello, world!"}

      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{
               type: "text",
               text: "Hello, world!"
             }
    end

    test "function call part" do
      part = %{
        function_call: %{
          id: "call_123",
          name: "get_weather",
          args: %{"city" => "London"}
        }
      }

      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{
               type: "function_call",
               id: "call_123",
               name: "get_weather",
               arguments: %{"city" => "London"}
             }
    end

    test "function call part no id" do
      part = %{
        function_call: %{
          name: "get_weather",
          args: %{"city" => "London"}
        }
      }

      res = InteractionsUtils.convert_part_to_interaction_content(part)
      assert res.id == ""
      assert res.name == "get_weather"
    end

    test "function call part with thought signature" do
      part = %{
        function_call: %{
          id: "call_456",
          name: "my_tool",
          args: %{"doc" => "content"}
        },
        thought_signature: "test_signature_bytes"
      }

      res = InteractionsUtils.convert_part_to_interaction_content(part)
      assert res.type == "function_call"
      assert res.id == "call_456"
      assert res.name == "my_tool"
      assert res.arguments == %{"doc" => "content"}
      assert Map.has_key?(res, "thought_signature")
      assert Base.decode64!(res["thought_signature"]) == "test_signature_bytes"
    end

    test "function call part without thought signature" do
      part = %{
        function_call: %{
          id: "call_789",
          name: "other_tool",
          args: %{}
        }
      }

      res = InteractionsUtils.convert_part_to_interaction_content(part)
      assert res.type == "function_call"
      refute Map.has_key?(res, "thought_signature")
    end

    test "function response dict" do
      part = %{
        function_response: %{
          id: "call_123",
          name: "get_weather",
          response: %{"temperature" => 20, "condition" => "sunny"}
        }
      }

      res = InteractionsUtils.convert_part_to_interaction_content(part)
      assert res.type == "function_result"
      assert res.call_id == "call_123"
      assert res.name == "get_weather"
      assert Jason.decode!(res.result) == %{"temperature" => 20, "condition" => "sunny"}
    end

    test "function response simple" do
      part = %{
        function_response: %{
          id: "call_123",
          name: "check_weather",
          response: %{"message" => "Weather is sunny"}
        }
      }

      res = InteractionsUtils.convert_part_to_interaction_content(part)
      assert res.type == "function_result"
      assert Jason.decode!(res.result) == %{"message" => "Weather is sunny"}
    end

    test "inline data image" do
      part = %{
        inline_data: %{
          data: "image_data",
          mime_type: "image/png"
        }
      }

      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{
               type: "image",
               data: "image_data",
               mime_type: "image/png"
             }
    end

    test "inline data audio" do
      part = %{
        inline_data: %{
          data: "audio_data",
          mime_type: "audio/mp3"
        }
      }

      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{
               type: "audio",
               data: "audio_data",
               mime_type: "audio/mp3"
             }
    end

    test "inline data video" do
      part = %{
        inline_data: %{
          data: "video_data",
          mime_type: "video/mp4"
        }
      }

      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{
               type: "video",
               data: "video_data",
               mime_type: "video/mp4"
             }
    end

    test "inline data document" do
      part = %{
        inline_data: %{
          data: "doc_data",
          mime_type: "application/pdf"
        }
      }

      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{
               type: "document",
               data: "doc_data",
               mime_type: "application/pdf"
             }
    end

    test "file data image" do
      part = %{
        file_data: %{
          file_uri: "gs://bucket/image.png",
          mime_type: "image/png"
        }
      }

      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{
               type: "image",
               uri: "gs://bucket/image.png",
               mime_type: "image/png"
             }
    end

    test "text with thought flag" do
      part = %{text: "Let me think about this...", thought: true}

      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{
               type: "text",
               text: "Let me think about this..."
             }
    end

    test "thought only part" do
      part = %{thought: true, thought_signature: "test-thought-signature"}
      res = InteractionsUtils.convert_part_to_interaction_content(part)
      assert res.type == "thought"
      assert res["signature"] == Base.encode64("test-thought-signature")
    end

    test "thought only part without signature" do
      part = %{thought: true}
      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{type: "thought"}
    end

    test "code execution result" do
      part = %{
        code_execution_result: %{
          output: "Hello from code",
          outcome: :OUTCOME_OK
        }
      }

      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{
               type: "code_execution_result",
               call_id: "",
               result: "Hello from code",
               is_error: false
             }
    end

    test "code execution result with error" do
      part = %{
        code_execution_result: %{
          output: "Error",
          outcome: :OUTCOME_FAILED
        }
      }

      assert InteractionsUtils.convert_part_to_interaction_content(part).is_error == true
    end

    test "executable code" do
      part = %{
        executable_code: %{
          code: "print(\"hello\")",
          language: "PYTHON"
        }
      }

      assert InteractionsUtils.convert_part_to_interaction_content(part) == %{
               type: "code_execution_call",
               id: "",
               arguments: %{
                 code: "print(\"hello\")",
                 language: "PYTHON"
               }
             }
    end

    test "empty part" do
      assert InteractionsUtils.convert_part_to_interaction_content(%{}) == nil
    end
  end

  describe "convert_content_to_turn" do
    test "user content" do
      content = %{
        role: "user",
        parts: [%{text: "Hello!"}]
      }

      assert InteractionsUtils.convert_content_to_turn(content) == %{
               role: "user",
               content: [%{type: "text", text: "Hello!"}]
             }
    end

    test "model content" do
      content = %{
        role: "model",
        parts: [%{text: "Hi there!"}]
      }

      assert InteractionsUtils.convert_content_to_turn(content) == %{
               role: "model",
               content: [%{type: "text", text: "Hi there!"}]
             }
    end

    test "multiple parts" do
      content = %{
        role: "user",
        parts: [
          %{text: "Look at this:"},
          %{inline_data: %{data: "img", mime_type: "image/png"}}
        ]
      }

      res = InteractionsUtils.convert_content_to_turn(content)
      assert length(res.content) == 2
      assert Enum.at(res.content, 0) == %{type: "text", text: "Look at this:"}
      assert Enum.at(res.content, 1).type == "image"
    end
  end

  describe "convert_contents_to_turns" do
    test "single content" do
      contents = [
        %{role: "user", parts: [%{text: "What is 2+2?"}]}
      ]

      res = InteractionsUtils.convert_contents_to_turns(contents)
      assert length(res) == 1
      assert Enum.at(res, 0).role == "user"
    end

    test "multi turn conversation" do
      contents = [
        %{role: "user", parts: [%{text: "Hi"}]},
        %{role: "model", parts: [%{text: "Hello!"}]},
        %{role: "user", parts: [%{text: "How are you?"}]}
      ]

      res = InteractionsUtils.convert_contents_to_turns(contents)
      assert length(res) == 3
      assert Enum.at(res, 0).role == "user"
      assert Enum.at(res, 1).role == "model"
      assert Enum.at(res, 2).role == "user"
    end

    test "empty content skipped" do
      contents = [
        %{role: "user", parts: [%{text: "Hi"}]},
        %{role: "model", parts: []}
      ]

      res = InteractionsUtils.convert_contents_to_turns(contents)
      assert length(res) == 1
    end
  end

  describe "convert_tools_config_to_interactions_format" do
    test "function declaration" do
      config = %{
        tools: [
          %{
            function_declarations: [
              %{
                name: "get_weather",
                description: "Get weather for a city",
                parameters: %{
                  type: "OBJECT",
                  properties: %{
                    "city" => %{type: "STRING"}
                  },
                  required: ["city"]
                }
              }
            ]
          }
        ]
      }

      res = InteractionsUtils.convert_tools_config_to_interactions_format(config)
      assert length(res) == 1
      assert Enum.at(res, 0).type == "function"
      assert Enum.at(res, 0).name == "get_weather"
      assert Enum.at(res, 0).description == "Get weather for a city"
      assert Enum.at(res, 0).parameters.type == "object"
    end

    test "google search tool" do
      config = %{tools: [%{google_search: %{}}]}
      res = InteractionsUtils.convert_tools_config_to_interactions_format(config)
      assert res == [%{type: "google_search"}]
    end

    test "code execution tool" do
      config = %{tools: [%{code_execution: %{}}]}
      res = InteractionsUtils.convert_tools_config_to_interactions_format(config)
      assert res == [%{type: "code_execution"}]
    end

    test "no tools" do
      assert InteractionsUtils.convert_tools_config_to_interactions_format(%{}) == []
    end
  end

  describe "convert_interaction_output_to_part" do
    test "text output" do
      output = %{type: "text", text: "Hello!"}
      assert InteractionsUtils.convert_interaction_output_to_part(output).text == "Hello!"
    end

    test "function call output" do
      output = %{
        type: "function_call",
        id: "call_123",
        name: "get_weather",
        arguments: %{"city" => "London"}
      }

      res = InteractionsUtils.convert_interaction_output_to_part(output)
      assert res.function_call.id == "call_123"
      assert res.function_call.name == "get_weather"
      assert res.function_call.args == %{"city" => "London"}
    end

    test "function call output with thought signature" do
      output = %{
        type: "function_call",
        id: "call_sig_123",
        name: "gemini3_tool",
        arguments: %{"content" => "hello"},
        thought_signature: Base.encode64("gemini3_signature")
      }

      res = InteractionsUtils.convert_interaction_output_to_part(output)
      assert res.function_call.id == "call_sig_123"
      assert res.function_call.name == "gemini3_tool"
      assert res.thought_signature == "gemini3_signature"
    end

    test "function call output without thought signature" do
      output = %{
        type: "function_call",
        id: "call_no_sig",
        name: "regular_tool",
        arguments: %{}
      }

      res = InteractionsUtils.convert_interaction_output_to_part(output)
      assert res.thought_signature == nil
    end

    test "code execution result output" do
      output = %{
        type: "code_execution_result",
        result: "Output from code",
        is_error: false
      }

      res = InteractionsUtils.convert_interaction_output_to_part(output)
      assert res.code_execution_result.output == "Output from code"
      assert res.code_execution_result.outcome == :OUTCOME_OK
    end

    test "thought output returns none" do
      output = %{type: "thought", signature: "thinking..."}
      assert InteractionsUtils.convert_interaction_output_to_part(output) == nil
    end

    test "no type attribute" do
      assert InteractionsUtils.convert_interaction_output_to_part(%{}) == nil
    end
  end

  describe "convert_interaction_to_llm_response" do
    test "successful text response" do
      interaction = %{
        id: "interaction_123",
        status: "completed",
        outputs: [
          %{type: "text", text: "The answer is 4."}
        ],
        usage: %{
          total_input_tokens: 10,
          total_output_tokens: 5
        }
      }

      res = InteractionsUtils.convert_interaction_to_llm_response(interaction)
      assert res.interaction_id == "interaction_123"
      assert Enum.at(res.content.parts, 0).text == "The answer is 4."
      assert res.usage_metadata.prompt_token_count == 10
      assert res.usage_metadata.candidates_token_count == 5
      assert res.finish_reason == :STOP
      assert res.turn_complete == true
    end

    test "failed response" do
      interaction = %{
        id: "interaction_123",
        status: "failed",
        outputs: [],
        error: %{code: "INVALID_REQUEST", message: "Bad request"}
      }

      res = InteractionsUtils.convert_interaction_to_llm_response(interaction)
      assert res.interaction_id == "interaction_123"
      assert res.error_code == "INVALID_REQUEST"
      assert res.error_message == "Bad request"
    end

    test "requires action response" do
      interaction = %{
        id: "interaction_123",
        status: "requires_action",
        outputs: [
          %{
            type: "function_call",
            id: "call_1",
            name: "get_weather",
            arguments: %{"city" => "Paris"}
          }
        ]
      }

      res = InteractionsUtils.convert_interaction_to_llm_response(interaction)
      assert Enum.at(res.content.parts, 0).function_call.name == "get_weather"
      assert res.finish_reason == :STOP
      assert res.turn_complete == true
    end
  end

  describe "build_generation_config" do
    test "all parameters" do
      config = %{
        temperature: 0.7,
        top_p: 0.9,
        top_k: 40,
        max_output_tokens: 100,
        stop_sequences: ["END"],
        presence_penalty: 0.5,
        frequency_penalty: 0.3
      }

      res = InteractionsUtils.build_generation_config(config)
      assert res == config
    end

    test "partial parameters" do
      config = %{temperature: 0.5, max_output_tokens: 50}
      assert InteractionsUtils.build_generation_config(config) == config
    end

    test "empty config" do
      assert InteractionsUtils.build_generation_config(%{}) == %{}
    end
  end

  describe "extract_system_instruction" do
    test "string instruction" do
      config = %{system_instruction: "You are a helpful assistant."}

      assert InteractionsUtils.extract_system_instruction(config) ==
               "You are a helpful assistant."
    end

    test "content instruction" do
      config = %{
        system_instruction: %{
          parts: [%{text: "Be helpful."}, %{text: "Be concise."}]
        }
      }

      assert InteractionsUtils.extract_system_instruction(config) == "Be helpful.\nBe concise."
    end

    test "no instruction" do
      assert InteractionsUtils.extract_system_instruction(%{}) == nil
    end
  end

  describe "get_latest_user_contents" do
    test "empty contents" do
      assert InteractionsUtils.get_latest_user_contents([]) == []
    end

    test "single user message" do
      contents = [%{role: "user", parts: [%{text: "Hello"}]}]
      res = InteractionsUtils.get_latest_user_contents(contents)
      assert length(res) == 1
    end

    test "stops at model message" do
      contents = [
        %{role: "user", parts: [%{text: "First user"}]},
        %{role: "model", parts: [%{text: "Model response"}]},
        %{role: "user", parts: [%{text: "Second user"}]}
      ]

      res = InteractionsUtils.get_latest_user_contents(contents)
      assert length(res) == 1
      assert Enum.at(res, 0).parts |> Enum.at(0) |> Map.get(:text) == "Second user"
    end

    test "full conversation" do
      contents = [
        %{role: "user", parts: [%{text: "Hi"}]},
        %{role: "model", parts: [%{text: "Hello!"}]},
        %{role: "user", parts: [%{text: "How are you?"}]},
        %{role: "model", parts: [%{text: "I am fine."}]},
        %{role: "user", parts: [%{text: "Great"}]},
        %{role: "user", parts: [%{text: "Tell me more"}]}
      ]

      res = InteractionsUtils.get_latest_user_contents(contents)
      assert length(res) == 2
      assert Enum.at(res, 0).role == "user"
      assert Enum.at(res, 0).parts |> Enum.at(0) |> Map.get(:text) == "Great"
      assert Enum.at(res, 1).parts |> Enum.at(0) |> Map.get(:text) == "Tell me more"
    end

    test "function result" do
      contents = [
        %{role: "user", parts: [%{text: "Do something"}]},
        %{role: "model", parts: [%{function_call: %{name: "tool"}}]},
        %{role: "user", parts: [%{function_response: %{id: "123"}}]}
      ]

      res = InteractionsUtils.get_latest_user_contents(contents)
      assert length(res) == 2
      assert Enum.at(res, 0).role == "model"
      assert Enum.at(res, 1).role == "user"
    end
  end

  describe "convert_interaction_event_to_llm_response" do
    test "text delta event" do
      event = %{
        event_type: "content.delta",
        delta: %{
          type: "text",
          text: "Hello world"
        }
      }

      {res, aggregated_parts} =
        InteractionsUtils.convert_interaction_event_to_llm_response(event, [], "int_123")

      assert res != nil
      assert res.partial == true
      assert res.interaction_id == "int_123"
      assert Enum.at(res.content.parts, 0).text == "Hello world"
      assert length(aggregated_parts) == 1
    end

    test "function call delta with thought signature" do
      event = %{
        event_type: "content.delta",
        delta: %{
          type: "function_call",
          id: "fc_delta_123",
          name: "streaming_tool",
          arguments: %{"param" => "value"},
          thought_signature: Base.encode64("delta_signature")
        }
      }

      {res, aggregated_parts} =
        InteractionsUtils.convert_interaction_event_to_llm_response(event, [], "int_456")

      assert res == nil
      assert length(aggregated_parts) == 1
      fc_part = Enum.at(aggregated_parts, 0)
      assert fc_part.function_call.id == "fc_delta_123"
      assert fc_part.function_call.name == "streaming_tool"
      assert fc_part.thought_signature == "delta_signature"
    end

    test "function call delta without thought signature" do
      event = %{
        event_type: "content.delta",
        delta: %{
          type: "function_call",
          id: "fc_no_sig",
          name: "regular_tool",
          arguments: %{}
        }
      }

      {res, aggregated_parts} =
        InteractionsUtils.convert_interaction_event_to_llm_response(event, [], "int_789")

      assert res == nil
      assert Enum.at(aggregated_parts, 0).function_call.name == "regular_tool"
      assert Enum.at(aggregated_parts, 0).thought_signature == nil
    end

    test "function call delta without name skipped" do
      event = %{
        event_type: "content.delta",
        delta: %{
          type: "function_call",
          id: "fc_no_name",
          name: nil,
          arguments: %{}
        }
      }

      {res, aggregated_parts} =
        InteractionsUtils.convert_interaction_event_to_llm_response(event, [], "int_000")

      assert res == nil
      assert Enum.empty?(aggregated_parts)
    end
  end
end
