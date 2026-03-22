defmodule ADK.Models.LlmResponseTest do
  use ExUnit.Case, async: true

  alias ADK.Models.LlmResponse

  describe "create/1" do
    test "extracts logprobs from candidate" do
      avg_logprobs = -0.75
      logprobs_result = %{chosen_candidates: [], top_candidates: []}

      generate_content_response = %{
        candidates: [
          %{
            content: %{parts: [%{text: "Response text"}]},
            finish_reason: "STOP",
            avg_logprobs: avg_logprobs,
            logprobs_result: logprobs_result
          }
        ]
      }

      response = LlmResponse.create(generate_content_response)

      assert response.avg_logprobs == avg_logprobs
      assert response.logprobs_result == logprobs_result
      assert hd(response.content.parts).text == "Response text"
      assert response.finish_reason == "STOP"
    end

    test "handles missing logprobs gracefully" do
      generate_content_response = %{
        candidates: [
          %{
            content: %{parts: [%{text: "Response text"}]},
            finish_reason: "STOP",
            avg_logprobs: nil,
            logprobs_result: nil
          }
        ]
      }

      response = LlmResponse.create(generate_content_response)

      assert response.avg_logprobs == nil
      assert response.logprobs_result == nil
      assert hd(response.content.parts).text == "Response text"
    end

    test "includes logprobs in error cases" do
      avg_logprobs = -2.1

      generate_content_response = %{
        candidates: [
          %{
            content: nil,
            finish_reason: "SAFETY",
            finish_message: "Safety filter triggered",
            avg_logprobs: avg_logprobs,
            logprobs_result: nil
          }
        ]
      }

      response = LlmResponse.create(generate_content_response)

      assert response.avg_logprobs == avg_logprobs
      assert response.logprobs_result == nil
      assert response.error_code == "SAFETY"
      assert response.error_message == "Safety filter triggered"
    end

    test "with no candidates" do
      generate_content_response = %{
        candidates: [],
        prompt_feedback: %{
          block_reason: "SAFETY",
          block_reason_message: "Prompt blocked for safety"
        }
      }

      response = LlmResponse.create(generate_content_response)

      assert response.avg_logprobs == nil
      assert response.logprobs_result == nil
      assert response.error_code == "SAFETY"
      assert response.error_message == "Prompt blocked for safety"
    end

    test "with concrete logprobs_result" do
      chosen_candidates = [
        %{token: "The", log_probability: -0.1, token_id: 123},
        %{token: " capital", log_probability: -0.5, token_id: 456},
        %{token: " of", log_probability: -0.2, token_id: 789}
      ]

      top_candidates = [
        %{
          candidates: [
            %{token: "The", log_probability: -0.1, token_id: 123},
            %{token: "A", log_probability: -2.3, token_id: 124},
            %{token: "This", log_probability: -3.1, token_id: 125}
          ]
        },
        %{
          candidates: [
            %{token: " capital", log_probability: -0.5, token_id: 456},
            %{token: " city", log_probability: -1.2, token_id: 457},
            %{token: " main", log_probability: -2.8, token_id: 458}
          ]
        }
      ]

      avg_logprobs = -0.27

      logprobs_result = %{
        chosen_candidates: chosen_candidates,
        top_candidates: top_candidates
      }

      generate_content_response = %{
        candidates: [
          %{
            content: %{parts: [%{text: "The capital of France is Paris."}]},
            finish_reason: "STOP",
            avg_logprobs: avg_logprobs,
            logprobs_result: logprobs_result
          }
        ]
      }

      response = LlmResponse.create(generate_content_response)

      assert response.avg_logprobs == avg_logprobs
      assert response.logprobs_result != nil

      # Test chosen candidates
      assert length(response.logprobs_result.chosen_candidates) == 3
      c1 = Enum.at(response.logprobs_result.chosen_candidates, 0)
      assert c1.token == "The"
      assert c1.log_probability == -0.1
      assert c1.token_id == 123

      c2 = Enum.at(response.logprobs_result.chosen_candidates, 1)
      assert c2.token == " capital"
      assert c2.log_probability == -0.5
      assert c2.token_id == 456

      # Test top candidates
      assert length(response.logprobs_result.top_candidates) == 2
      t1 = Enum.at(response.logprobs_result.top_candidates, 0)
      assert length(t1.candidates) == 3

      t1c1 = Enum.at(t1.candidates, 0)
      assert t1c1.token == "The"
      assert t1c1.token_id == 123

      t1c2 = Enum.at(t1.candidates, 1)
      assert t1c2.token == "A"
      assert t1c2.token_id == 124
    end

    test "with partial logprobs_result" do
      chosen_candidates = [
        %{token: "Hello", log_probability: -0.05, token_id: 111},
        %{token: " world", log_probability: -0.8, token_id: 222}
      ]

      logprobs_result = %{
        chosen_candidates: chosen_candidates,
        top_candidates: []
      }

      generate_content_response = %{
        candidates: [
          %{
            content: %{parts: [%{text: "Hello world"}]},
            finish_reason: "STOP",
            avg_logprobs: -0.425,
            logprobs_result: logprobs_result
          }
        ]
      }

      response = LlmResponse.create(generate_content_response)

      assert response.avg_logprobs == -0.425
      assert response.logprobs_result != nil
      assert length(response.logprobs_result.chosen_candidates) == 2
      assert length(response.logprobs_result.top_candidates) == 0

      c1 = Enum.at(response.logprobs_result.chosen_candidates, 0)
      assert c1.token == "Hello"

      c2 = Enum.at(response.logprobs_result.chosen_candidates, 1)
      assert c2.token == " world"
    end

    test "extracts citation_metadata from candidate" do
      citation_metadata = %{
        citations: [
          %{
            start_index: 0,
            end_index: 10,
            uri: "https://example.com"
          }
        ]
      }

      generate_content_response = %{
        candidates: [
          %{
            content: %{parts: [%{text: "Response text"}]},
            finish_reason: "STOP",
            citation_metadata: citation_metadata
          }
        ]
      }

      response = LlmResponse.create(generate_content_response)

      assert response.citation_metadata == citation_metadata
      assert hd(response.content.parts).text == "Response text"
    end

    test "handles missing citation_metadata gracefully" do
      generate_content_response = %{
        candidates: [
          %{
            content: %{parts: [%{text: "Response text"}]},
            finish_reason: "STOP",
            citation_metadata: nil
          }
        ]
      }

      response = LlmResponse.create(generate_content_response)

      assert response.citation_metadata == nil
      assert hd(response.content.parts).text == "Response text"
    end

    test "includes citation_metadata in error cases" do
      citation_metadata = %{
        citations: [
          %{
            start_index: 0,
            end_index: 10,
            uri: "https://example.com"
          }
        ]
      }

      generate_content_response = %{
        candidates: [
          %{
            content: nil,
            finish_reason: "RECITATION",
            finish_message: "Response blocked due to recitation triggered",
            citation_metadata: citation_metadata
          }
        ]
      }

      response = LlmResponse.create(generate_content_response)

      assert response.citation_metadata == citation_metadata
      assert response.error_code == "RECITATION"
      assert response.error_message == "Response blocked due to recitation triggered"
    end

    test "empty content with stop reason" do
      generate_content_response = %{
        candidates: [
          %{
            content: %{parts: []},
            finish_reason: "STOP"
          }
        ]
      }

      response = LlmResponse.create(generate_content_response)

      assert response.error_code == nil
      assert response.content != nil
    end

    test "includes model version" do
      generate_content_response = %{
        model_version: "gemini-2.0-flash",
        candidates: [
          %{
            content: %{parts: [%{text: "Response text"}]},
            finish_reason: "STOP"
          }
        ]
      }

      response = LlmResponse.create(generate_content_response)
      assert response.model_version == "gemini-2.0-flash"
    end
  end
end
