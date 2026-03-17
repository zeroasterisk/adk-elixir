defmodule ADK.LLM.GemmaTest do
  @moduledoc """
  Tests for ADK.LLM.Gemma — Gemma-specific preprocessing and response parsing.

  Gemma models differ from Gemini in two key ways:
  1. No native system instructions → converted to initial user message
  2. No native function calling → function declarations serialised as text,
     function call/response turns converted to text, and model JSON responses
     parsed back into structured function_call parts.

  These tests focus on behavioral parity with the Python ADK `test_gemma_llm.py`
  test suite, adapted to Elixir idioms.
  """

  use ExUnit.Case, async: true

  alias ADK.LLM.Gemma

  # ---------------------------------------------------------------------------
  # Fixtures (mirroring Python fixtures)
  # ---------------------------------------------------------------------------

  defp base_request do
    %{
      model: "gemma-3-4b-it",
      instruction: "You are a helpful assistant",
      messages: [%{role: :user, parts: [%{text: "Hello"}]}]
    }
  end

  defp request_with_duplicate_instruction do
    %{
      model: "gemma-3-1b-it",
      instruction: "Talk like a pirate.",
      messages: [
        %{role: :user, parts: [%{text: "Talk like a pirate."}]},
        %{role: :user, parts: [%{text: "Hello"}]}
      ]
    }
  end

  defp request_with_tools do
    %{
      model: "gemma-3-1b-it",
      messages: [%{role: :user, parts: [%{text: "Hello"}]}],
      tools: [
        %{
          function_declarations: [
            %{
              name: "search_web",
              description: "Search the web for a query.",
              parameters: %{
                type: "OBJECT",
                properties: %{query: %{type: "STRING"}},
                required: ["query"]
              }
            },
            %{
              name: "get_current_time",
              description: "Gets the current time.",
              parameters: %{type: "OBJECT", properties: %{}}
            }
          ]
        }
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # Model validation
  # ---------------------------------------------------------------------------

  describe "generate/2 — model validation" do
    test "raises on non-Gemma model" do
      assert_raise ArgumentError, ~r/non-Gemma model/, fn ->
        Gemma.generate("not-a-gemma-model", %{messages: []})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # preprocess_request — system instruction handling
  # ---------------------------------------------------------------------------

  describe "preprocess_request/1 — system instruction → initial user message" do
    test "moves system instruction to first user message and clears instruction field" do
      req = base_request()
      want_text = req.instruction

      result = Gemma.preprocess_request(req)

      # instruction should be cleared
      assert result.instruction in [nil, ""]

      # first message in contents should be user: <original system instruction>
      [first | _rest] = result.messages
      assert first.role == :user
      assert [%{text: ^want_text}] = first.parts
    end

    test "total message count is original + 1 (instruction prepended)" do
      req = base_request()
      result = Gemma.preprocess_request(req)
      # 1 original message + 1 prepended instruction message
      assert length(result.messages) == 2
    end

    test "deduplicates instruction — does not prepend if already present as first user message" do
      req = request_with_duplicate_instruction()
      result = Gemma.preprocess_request(req)

      # Should have instruction + 2 original messages = 3, but first original
      # IS the instruction text, so should not double-prepend.
      # Python behaviour: still 2 total because instruction deduped.
      assert length(result.messages) == 2
    end

    test "first message has role :user and contains the instruction text" do
      req = base_request()
      result = Gemma.preprocess_request(req)
      [first | _] = result.messages
      assert first.role == :user
      assert [%{text: "You are a helpful assistant"}] = first.parts
    end
  end

  # ---------------------------------------------------------------------------
  # preprocess_request — tool conversion
  # ---------------------------------------------------------------------------

  describe "preprocess_request/1 — tools → system instruction" do
    test "clears tools from request after processing" do
      req = request_with_tools()
      result = Gemma.preprocess_request(req)
      assert result.tools == [] or is_nil(result.tools) or result.tools == []
    end

    test "original user message becomes the second message after tool instruction" do
      req = request_with_tools()
      result = Gemma.preprocess_request(req)

      # The second message should be the original user Hello
      [_instruction_msg, second | _] = result.messages
      assert second.role == :user
      assert [%{text: "Hello"}] = second.parts
    end

    test "tool system instruction contains 'You have access to the following functions'" do
      req = request_with_tools()
      result = Gemma.preprocess_request(req)

      [first | _] = result.messages
      assert first.role == :user
      [%{text: sys_text}] = first.parts
      assert sys_text =~ "You have access to the following functions"
    end

    test "tool system instruction includes search_web function description" do
      req = request_with_tools()
      result = Gemma.preprocess_request(req)

      [first | _] = result.messages
      [%{text: sys_text}] = first.parts
      assert sys_text =~ "search_web"
      assert sys_text =~ "Search the web for a query."
    end

    test "tool system instruction includes get_current_time function" do
      req = request_with_tools()
      result = Gemma.preprocess_request(req)

      [first | _] = result.messages
      [%{text: sys_text}] = first.parts
      assert sys_text =~ "get_current_time"
      assert sys_text =~ "Gets the current time."
    end
  end

  # ---------------------------------------------------------------------------
  # preprocess_request — function response conversion
  # ---------------------------------------------------------------------------

  describe "preprocess_request/1 — function response → user text" do
    test "function_response part is converted to user-role text content" do
      req = %{
        model: "gemma-3-1b-it",
        messages: [
          %{
            role: :model,
            parts: [
              %{
                function_response: %{
                  name: "search_web",
                  response: %{"results" => [%{"title" => "ADK"}]}
                }
              }
            ]
          }
        ]
      }

      result = Gemma.preprocess_request(req)

      assert length(result.messages) == 1
      [msg] = result.messages
      assert msg.role == :user
      [part] = msg.parts
      assert part.text =~ "Invoking tool `search_web` produced:"
      assert part.text =~ "ADK"
      assert not Map.has_key?(part, :function_response)
      assert not Map.has_key?(part, :function_call)
    end
  end

  # ---------------------------------------------------------------------------
  # preprocess_request — function call conversion
  # ---------------------------------------------------------------------------

  describe "preprocess_request/1 — function call → model text" do
    test "function_call part is converted to model-role text content" do
      req = %{
        model: "gemma-3-1b-it",
        messages: [
          %{
            role: :user,
            parts: [
              %{function_call: %{name: "get_current_time", args: %{}}}
            ]
          }
        ]
      }

      result = Gemma.preprocess_request(req)

      assert length(result.messages) == 1
      [msg] = result.messages
      assert msg.role == :model
      [part] = msg.parts
      assert is_binary(part.text)
      {:ok, decoded} = Jason.decode(part.text)
      assert decoded["name"] == "get_current_time"
      assert not Map.has_key?(part, :function_call)
      assert not Map.has_key?(part, :function_response)
    end
  end

  # ---------------------------------------------------------------------------
  # preprocess_request — mixed content
  # ---------------------------------------------------------------------------

  describe "preprocess_request/1 — mixed conversation history" do
    test "correctly transforms all turns in a mixed conversation" do
      req = %{
        model: "gemma-3-1b-it",
        messages: [
          %{role: :user, parts: [%{text: "Hello!"}]},
          %{role: :model, parts: [%{function_call: %{name: "get_weather", args: %{city: "London"}}}]},
          %{
            role: :some_function,
            parts: [%{function_response: %{name: "get_weather", response: %{temp: "15C"}}}]
          },
          %{role: :user, parts: [%{text: "How are you?"}]}
        ]
      }

      result = Gemma.preprocess_request(req)

      # Expect 4 messages (no deduplication here, no system instruction to prepend)
      assert length(result.messages) == 4

      [m0, m1, m2, m3] = result.messages

      # First: original user text unchanged
      assert m0.role == :user
      assert [%{text: "Hello!"}] = m0.parts

      # Second: function call → model text
      assert m1.role == :model
      [p1] = m1.parts
      {:ok, fc_decoded} = Jason.decode(p1.text)
      assert fc_decoded["name"] == "get_weather"
      assert not Map.has_key?(p1, :function_call)

      # Third: function response → user text
      assert m2.role == :user
      [p2] = m2.parts
      assert p2.text =~ "Invoking tool `get_weather` produced:"
      assert p2.text =~ "15C"
      assert not Map.has_key?(p2, :function_response)

      # Fourth: original user text unchanged
      assert m3.role == :user
      assert [%{text: "How are you?"}] = m3.parts
    end
  end

  # ---------------------------------------------------------------------------
  # extract_function_calls_from_response — structured JSON
  # ---------------------------------------------------------------------------

  describe "extract_function_calls_from_response/1 — JSON function call in text" do
    test "converts JSON function call text to structured function_call part" do
      json_str = ~s({"name": "search_web", "parameters": {"query": "latest news"}})

      response = %{
        content: %{role: :model, parts: [%{text: json_str}]},
        usage_metadata: nil
      }

      result = Gemma.extract_function_calls_from_response(response)

      [part] = result.content.parts
      assert %{function_call: fc} = part
      assert fc.name == "search_web"
      assert fc.args == %{"query" => "latest news"}
      assert not Map.has_key?(part, :text)
    end

    test "leaves plain text response unchanged" do
      text = "This is a regular text response."

      response = %{
        content: %{role: :model, parts: [%{text: text}]},
        usage_metadata: nil
      }

      result = Gemma.extract_function_calls_from_response(response)

      [part] = result.content.parts
      assert part.text == text
      assert not Map.has_key?(part, :function_call)
    end

    test "leaves valid JSON that does not match function call schema unchanged" do
      malformed = ~s({"not_a_function": "value", "another_field": 123})

      response = %{
        content: %{role: :model, parts: [%{text: malformed}]},
        usage_metadata: nil
      }

      result = Gemma.extract_function_calls_from_response(response)

      [part] = result.content.parts
      assert part.text == malformed
      assert not Map.has_key?(part, :function_call)
    end
  end

  # ---------------------------------------------------------------------------
  # extract_function_calls_from_response — edge cases
  # ---------------------------------------------------------------------------

  describe "extract_function_calls_from_response/1 — edge cases" do
    test "returns response unchanged when content is nil" do
      response = %{content: nil, usage_metadata: nil}
      result = Gemma.extract_function_calls_from_response(response)
      assert result.content == nil
    end

    test "returns response unchanged when parts list is empty" do
      response = %{content: %{role: :model, parts: []}, usage_metadata: nil}
      result = Gemma.extract_function_calls_from_response(response)
      assert result.content.parts == []
    end

    test "returns response unchanged when multiple parts are present" do
      response = %{
        content: %{
          role: :model,
          parts: [%{text: "part one"}, %{text: "part two"}]
        },
        usage_metadata: nil
      }

      result = Gemma.extract_function_calls_from_response(response)
      assert length(result.content.parts) == 2
      assert Enum.at(result.content.parts, 0).text == "part one"
    end

    test "returns response unchanged when single part has empty text" do
      response = %{
        content: %{role: :model, parts: [%{text: ""}]},
        usage_metadata: nil
      }

      result = Gemma.extract_function_calls_from_response(response)
      [part] = result.content.parts
      assert part.text == ""
      assert not Map.has_key?(part, :function_call)
    end
  end

  # ---------------------------------------------------------------------------
  # extract_function_calls_from_response — markdown code blocks
  # ---------------------------------------------------------------------------

  describe "extract_function_calls_from_response/1 — markdown code blocks" do
    test "extracts function call from markdown json code block" do
      json_text = "\n```json\n{\"name\": \"search_web\", \"parameters\": {\"query\": \"latest news\"}}\n```"

      response = %{
        content: %{role: :model, parts: [%{text: json_text}]},
        usage_metadata: nil
      }

      result = Gemma.extract_function_calls_from_response(response)

      [part] = result.content.parts
      assert %{function_call: fc} = part
      assert fc.name == "search_web"
      assert fc.args == %{"query" => "latest news"}
      assert not Map.has_key?(part, :text)
    end

    test "extracts function call from markdown tool_code code block with surrounding text" do
      json_text =
        "Some text before.\n```tool_code\n{\"name\": \"get_current_time\", \"parameters\": {}}\n```\nAnd some text after."

      response = %{
        content: %{role: :model, parts: [%{text: json_text}]},
        usage_metadata: nil
      }

      result = Gemma.extract_function_calls_from_response(response)

      [part] = result.content.parts
      assert %{function_call: fc} = part
      assert fc.name == "get_current_time"
      assert fc.args == %{}
      assert not Map.has_key?(part, :text)
    end
  end

  # ---------------------------------------------------------------------------
  # extract_function_calls_from_response — JSON embedded in text
  # ---------------------------------------------------------------------------

  describe "extract_function_calls_from_response/1 — embedded JSON" do
    test "extracts function call JSON embedded in surrounding text" do
      embedded = ~s(Please call the tool: {"name": "search_web", "parameters": {"query": "new features"}} thanks!)

      response = %{
        content: %{role: :model, parts: [%{text: embedded}]},
        usage_metadata: nil
      }

      result = Gemma.extract_function_calls_from_response(response)

      [part] = result.content.parts
      assert %{function_call: fc} = part
      assert fc.name == "search_web"
      assert fc.args == %{"query" => "new features"}
      assert not Map.has_key?(part, :text)
    end

    test "uses last valid JSON object when multiple JSON objects appear in text" do
      multiple = ~s(I thought about {"name": "first_call", "parameters": {"a": 1}} but then decided to call: {"name": "second_call", "parameters": {"b": 2}})

      response = %{
        content: %{role: :model, parts: [%{text: multiple}]},
        usage_metadata: nil
      }

      result = Gemma.extract_function_calls_from_response(response)

      [part] = result.content.parts
      assert %{function_call: fc} = part
      assert fc.name == "second_call"
      assert fc.args == %{"b" => 2}
      assert not Map.has_key?(part, :text)
    end
  end

  # ---------------------------------------------------------------------------
  # extract_function_calls_from_response — flexible key aliases
  # ---------------------------------------------------------------------------

  describe "extract_function_calls_from_response/1 — flexible parsing (function/args keys)" do
    test "supports 'function' and 'args' key aliases for function call JSON" do
      flexible = ~s({"function": "do_something", "args": {"value": 123}})

      response = %{
        content: %{role: :model, parts: [%{text: flexible}]},
        usage_metadata: nil
      }

      result = Gemma.extract_function_calls_from_response(response)

      [part] = result.content.parts
      assert %{function_call: fc} = part
      assert fc.name == "do_something"
      assert fc.args == %{"value" => 123}
      assert not Map.has_key?(part, :text)
    end
  end

  # ---------------------------------------------------------------------------
  # supported_models/0
  # ---------------------------------------------------------------------------

  describe "supported_models/0" do
    test "returns regex patterns matching gemma-3 models" do
      patterns = Gemma.supported_models()
      assert is_list(patterns)
      assert Enum.any?(patterns, fn p -> Regex.match?(p, "gemma-3-27b-it") end)
      assert Enum.any?(patterns, fn p -> Regex.match?(p, "gemma-3-1b-it") end)
      assert Enum.any?(patterns, fn p -> Regex.match?(p, "gemma-3-12b-it") end)
      refute Enum.any?(patterns, fn p -> Regex.match?(p, "gemini-2.0-flash") end)
    end
  end
end
