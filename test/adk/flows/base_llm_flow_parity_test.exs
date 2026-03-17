# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule ADK.Flows.BaseLlmFlowParityTest do
  @moduledoc """
  Parity tests ported from Python ADK's
  `tests/unittests/flows/llm_flows/test_base_llm_flow.py`.

  The Python test focuses on BaseLlmFlow internals: toolset `process_llm_request`
  preprocessing, Google Search workarounds, grounding metadata, and canonical tools
  caching. Most of these are deeply tied to Python-specific plumbing.

  This Elixir parity file tests the *equivalent behaviours* through the Runner +
  Callback pipeline:

  - Before/after model callback pipeline (halt, passthrough, transform)
  - Callback chains (multiple before/after model callbacks in sequence)
  - Model error handling callbacks (retry, fallback, propagate)
  - LLM Mock responses (text, function_call, echo mode)
  - Runner integration with agent-level callbacks (before_agent / after_agent)
  - Tool call flow through Custom agents simulating LLM pipeline

  Parity divergences (Python-only, not ported):
  - `process_llm_request` on toolsets — Elixir Toolset behaviour has no equivalent
  - Google Search bypass_multi_tools_limit workaround — internal to Gemini adapter
  - Grounding metadata propagation — not implemented in Elixir
  - Canonical tools caching — not implemented in Elixir
  - `_convert_tool_union_to_tools` — Python internal dispatch
  """

  use ExUnit.Case, async: false

  alias ADK.Agent.Custom
  alias ADK.Event
  alias ADK.Runner

  setup do
    Process.put(:adk_mock_responses, nil)
    :ok
  end

  # ── Helper: run an agent through Runner ──────────────────────────────

  defp run_agent(agent, message, opts \\ []) do
    runner = Runner.new(app_name: "flow_test", agent: agent)
    sid = "s-#{System.unique_integer([:positive])}"
    Runner.run(runner, "u1", sid, message, opts)
  end

  defp make_event(text, author \\ "agent") do
    Event.new(%{
      author: author,
      content: %{"role" => "model", "parts" => [%{"text" => text}]}
    })
  end

  # ── Callback modules ─────────────────────────────────────────────────

  defmodule BeforeModelHalt do
    @moduledoc false
    @behaviour ADK.Callback

    @impl true
    def before_model(_ctx) do
      response = %{
        content: %{role: :model, parts: [%{text: "intercepted_before_model"}]},
        usage_metadata: nil
      }

      {:halt, {:ok, response}}
    end
  end

  defmodule BeforeModelPassthrough do
    @moduledoc false
    @behaviour ADK.Callback

    @impl true
    def before_model(ctx) do
      send(self(), :before_model_passthrough_called)
      {:cont, ctx}
    end
  end

  defmodule AfterModelAppend do
    @moduledoc false
    @behaviour ADK.Callback

    @impl true
    def after_model({:ok, resp}, _ctx) do
      new_parts =
        Enum.map(resp.content.parts, fn
          %{text: t} = part -> %{part | text: t <> " [after_model]"}
          part -> part
        end)

      {:ok, %{resp | content: %{resp.content | parts: new_parts}}}
    end

    def after_model(error, _ctx), do: error
  end

  defmodule AfterModelReplace do
    @moduledoc false
    @behaviour ADK.Callback

    @impl true
    def after_model({:ok, _resp}, _ctx) do
      {:ok,
       %{
         content: %{role: :model, parts: [%{text: "replaced_by_after_model"}]},
         usage_metadata: nil
       }}
    end

    def after_model(error, _ctx), do: error
  end

  defmodule OnModelErrorRetry do
    @moduledoc false
    @behaviour ADK.Callback

    @impl true
    def on_model_error({:error, _reason}, ctx) do
      send(self(), :on_model_error_retry_called)
      {:retry, ctx}
    end
  end

  defmodule OnModelErrorFallback do
    @moduledoc false
    @behaviour ADK.Callback

    @impl true
    def on_model_error({:error, _reason}, _ctx) do
      send(self(), :on_model_error_fallback_called)

      {:fallback,
       {:ok,
        %{
          content: %{role: :model, parts: [%{text: "fallback_response"}]},
          usage_metadata: nil
        }}}
    end
  end

  defmodule BeforeAgentHalt do
    @moduledoc false
    @behaviour ADK.Callback

    @impl true
    def before_agent(_ctx) do
      event =
        Event.new(%{
          author: "callback",
          content: %{"role" => "model", "parts" => [%{"text" => "halted_before_agent"}]}
        })

      {:halt, [event]}
    end
  end

  defmodule AfterAgentAppend do
    @moduledoc false
    @behaviour ADK.Callback

    @impl true
    def after_agent(events, _ctx) do
      extra =
        Event.new(%{
          author: "callback",
          content: %{"role" => "model", "parts" => [%{"text" => "appended_by_after_agent"}]}
        })

      events ++ [extra]
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Tests: Callback.run_before / run_after (unit) — mirrors Python's
  # test of before/after model callback pipeline in BaseLlmFlow
  # ────────────────────────────────────────────────────────────────────

  describe "Callback.run_before/3" do
    test "empty callbacks pass through" do
      ctx = %{agent: nil, context: nil}
      assert {:cont, ^ctx} = ADK.Callback.run_before([], :before_model, ctx)
    end

    test "halting callback stops pipeline" do
      assert {:halt, {:ok, resp}} =
               ADK.Callback.run_before([BeforeModelHalt], :before_model, %{})

      assert hd(resp.content.parts).text == "intercepted_before_model"
    end

    test "passthrough callback continues pipeline" do
      ctx = %{agent: nil, context: nil}

      assert {:cont, ^ctx} =
               ADK.Callback.run_before([BeforeModelPassthrough], :before_model, ctx)

      assert_received :before_model_passthrough_called
    end

    test "passthrough then halt — halt wins" do
      assert {:halt, {:ok, _resp}} =
               ADK.Callback.run_before(
                 [BeforeModelPassthrough, BeforeModelHalt],
                 :before_model,
                 %{}
               )

      assert_received :before_model_passthrough_called
    end

    test "multiple passthrough callbacks all execute" do
      ctx = %{agent: nil, context: nil}

      assert {:cont, ^ctx} =
               ADK.Callback.run_before(
                 [BeforeModelPassthrough, BeforeModelPassthrough],
                 :before_model,
                 ctx
               )

      # Should receive the message twice
      assert_received :before_model_passthrough_called
      assert_received :before_model_passthrough_called
    end
  end

  describe "Callback.run_after/4" do
    test "empty callbacks return result unchanged" do
      result =
        {:ok, %{content: %{role: :model, parts: [%{text: "unchanged"}]}, usage_metadata: nil}}

      assert ^result = ADK.Callback.run_after([], :after_model, result, %{})
    end

    test "single after callback transforms result" do
      result =
        {:ok, %{content: %{role: :model, parts: [%{text: "Hi"}]}, usage_metadata: nil}}

      transformed = ADK.Callback.run_after([AfterModelAppend], :after_model, result, %{})
      assert {:ok, resp} = transformed
      assert hd(resp.content.parts).text == "Hi [after_model]"
    end

    test "chained after callbacks compose transforms" do
      result =
        {:ok, %{content: %{role: :model, parts: [%{text: "Hi"}]}, usage_metadata: nil}}

      transformed =
        ADK.Callback.run_after(
          [AfterModelAppend, AfterModelAppend],
          :after_model,
          result,
          %{}
        )

      assert {:ok, resp} = transformed
      assert hd(resp.content.parts).text == "Hi [after_model] [after_model]"
    end

    test "replace callback overrides original content" do
      result =
        {:ok, %{content: %{role: :model, parts: [%{text: "original"}]}, usage_metadata: nil}}

      transformed = ADK.Callback.run_after([AfterModelReplace], :after_model, result, %{})
      assert {:ok, resp} = transformed
      assert hd(resp.content.parts).text == "replaced_by_after_model"
    end

    test "replace then append composes correctly" do
      result =
        {:ok, %{content: %{role: :model, parts: [%{text: "original"}]}, usage_metadata: nil}}

      transformed =
        ADK.Callback.run_after(
          [AfterModelReplace, AfterModelAppend],
          :after_model,
          result,
          %{}
        )

      assert {:ok, resp} = transformed
      assert hd(resp.content.parts).text == "replaced_by_after_model [after_model]"
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Tests: on_model_error callbacks — mirrors Python's grounding/error
  # callback handling in _handle_after_model_callback
  # ────────────────────────────────────────────────────────────────────

  describe "Callback.run_on_error/3" do
    test "no callbacks propagates error unchanged" do
      assert {:error, :boom} = ADK.Callback.run_on_error([], {:error, :boom}, %{})
    end

    test "retry callback signals retry" do
      ctx = %{agent: nil, context: nil}

      assert {:retry, ^ctx} =
               ADK.Callback.run_on_error([OnModelErrorRetry], {:error, :boom}, ctx)

      assert_received :on_model_error_retry_called
    end

    test "fallback callback provides canned response" do
      assert {:fallback, {:ok, resp}} =
               ADK.Callback.run_on_error([OnModelErrorFallback], {:error, :boom}, %{})

      assert hd(resp.content.parts).text == "fallback_response"
      assert_received :on_model_error_fallback_called
    end

    test "first non-error wins in chain" do
      # OnModelErrorRetry returns :retry, should win over fallback
      ctx = %{agent: nil, context: nil}

      assert {:retry, ^ctx} =
               ADK.Callback.run_on_error(
                 [OnModelErrorRetry, OnModelErrorFallback],
                 {:error, :boom},
                 ctx
               )

      assert_received :on_model_error_retry_called
      # OnModelErrorFallback should NOT have been called
      refute_received :on_model_error_fallback_called
    end

    test "skips callbacks without on_model_error" do
      defmodule NoOpErrorCb do
        @behaviour ADK.Callback
      end

      assert {:error, :boom} =
               ADK.Callback.run_on_error([NoOpErrorCb], {:error, :boom}, %{})
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Tests: LLM Mock — directly tests the mock used for LLM flow
  # ────────────────────────────────────────────────────────────────────

  describe "ADK.LLM.Mock" do
    test "returns configured text responses in order" do
      ADK.LLM.Mock.set_responses(["first", "second"])

      {:ok, r1} = ADK.LLM.Mock.generate("test", %{})
      assert hd(r1.content.parts).text == "first"

      {:ok, r2} = ADK.LLM.Mock.generate("test", %{})
      assert hd(r2.content.parts).text == "second"
    end

    test "echo mode when responses exhausted" do
      ADK.LLM.Mock.set_responses(["only_one"])
      {:ok, _r1} = ADK.LLM.Mock.generate("test", %{})

      {:ok, r2} =
        ADK.LLM.Mock.generate("test", %{
          messages: [%{role: :user, parts: [%{text: "Hello echo"}]}]
        })

      assert String.contains?(hd(r2.content.parts).text, "Hello echo")
    end

    test "echo mode when no responses set" do
      {:ok, resp} =
        ADK.LLM.Mock.generate("test", %{
          messages: [%{role: :user, parts: [%{text: "Echo me"}]}]
        })

      assert String.contains?(hd(resp.content.parts).text, "Echo me")
    end

    test "supports function_call response format" do
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "my_tool", args: %{"x" => 1}, id: "fc-1"}}
      ])

      {:ok, resp} = ADK.LLM.Mock.generate("test", %{})
      assert hd(resp.content.parts).function_call.name == "my_tool"
    end

    test "supports raw content response format" do
      raw = %{content: %{role: :model, parts: [%{text: "raw"}]}, usage_metadata: nil}
      ADK.LLM.Mock.set_responses([raw])

      {:ok, resp} = ADK.LLM.Mock.generate("test", %{})
      assert resp == raw
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Tests: Runner integration with before/after agent callbacks
  # Uses Custom agents to simulate LLM flow behavior
  # ────────────────────────────────────────────────────────────────────

  describe "Runner + before_agent callback" do
    test "halt callback bypasses agent execution" do
      agent =
        Custom.new(
          name: "should_not_run",
          run_fn: fn _agent, _ctx -> raise "agent should not execute" end
        )

      events = run_agent(agent, "Hi", callbacks: [BeforeAgentHalt])

      assert length(events) == 1
      assert Event.text(hd(events)) == "halted_before_agent"
    end
  end

  describe "Runner + after_agent callback" do
    test "appends extra event after agent execution" do
      agent =
        Custom.new(
          name: "simple",
          run_fn: fn _agent, _ctx -> [make_event("original_response", "simple")] end
        )

      events = run_agent(agent, "Hi", callbacks: [AfterAgentAppend])

      assert length(events) == 2
      assert Event.text(Enum.at(events, 0)) == "original_response"
      assert Event.text(Enum.at(events, 1)) == "appended_by_after_agent"
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Tests: Simulated LLM flow via Custom agent
  # Mirrors Python's test_preprocess_calls_toolset_process_llm_request
  # and test_preprocess_handles_mixed_tools_and_toolsets by verifying
  # that tool resolution and LLM call occur in the agent execution path
  # ────────────────────────────────────────────────────────────────────

  describe "simulated LLM flow via Custom agent" do
    test "agent calls LLM and returns response as event" do
      ADK.LLM.Mock.set_responses(["Hello from LLM!"])

      agent =
        Custom.new(
          name: "llm_sim",
          run_fn: fn _agent, ctx ->
            user_text =
              case ctx.user_content do
                %{text: t} -> t
                t when is_binary(t) -> t
              end

            {:ok, resp} =
              ADK.LLM.generate("test", %{
                messages: [%{role: :user, parts: [%{text: user_text}]}]
              })

            text = hd(resp.content.parts).text

            [
              Event.new(%{
                author: "llm_sim",
                content: %{"role" => "model", "parts" => [%{"text" => text}]}
              })
            ]
          end
        )

      events = run_agent(agent, "Hi")
      assert length(events) == 1
      assert Event.text(hd(events)) == "Hello from LLM!"
    end

    test "agent handles function_call then final response (tool loop)" do
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "get_temp", args: %{"city" => "Berlin"}, id: "fc-1"}},
        "Berlin is 20°C."
      ])

      agent =
        Custom.new(
          name: "tool_sim",
          run_fn: fn _agent, ctx ->
            user_text =
              case ctx.user_content do
                %{text: t} -> t
                t when is_binary(t) -> t
              end

            # First LLM call — may return function_call
            {:ok, resp1} =
              ADK.LLM.generate("test", %{
                messages: [%{role: :user, parts: [%{text: user_text}]}]
              })

            first_part = hd(resp1.content.parts)

            case Map.get(first_part, :function_call) do
              nil ->
                [
                  Event.new(%{
                    author: "tool_sim",
                    content: %{"role" => "model", "parts" => [%{"text" => first_part.text}]}
                  })
                ]

              fc ->
                # Emit function_call event
                fc_event =
                  Event.new(%{
                    author: "tool_sim",
                    content: %{
                      "role" => "model",
                      "parts" => [
                        %{
                          "function_call" => %{
                            "name" => fc.name,
                            "args" => fc.args,
                            "id" => fc.id
                          }
                        }
                      ]
                    }
                  })

                # Execute tool (simulated)
                tool_result = %{temp: 20, city: fc.args["city"]}

                # Emit function_response event
                fr_event =
                  Event.new(%{
                    author: "tool_sim",
                    content: %{
                      "role" => "user",
                      "parts" => [
                        %{
                          "function_response" => %{
                            name: fc.name,
                            response: tool_result
                          }
                        }
                      ]
                    }
                  })

                # Second LLM call with tool result
                {:ok, resp2} = ADK.LLM.generate("test", %{messages: []})
                final_text = hd(resp2.content.parts).text

                final_event =
                  Event.new(%{
                    author: "tool_sim",
                    content: %{"role" => "model", "parts" => [%{"text" => final_text}]}
                  })

                [fc_event, fr_event, final_event]
            end
          end
        )

      events = run_agent(agent, "What's the temp in Berlin?")

      assert length(events) == 3

      # First: function_call
      fc_parts = hd(events).content["parts"]
      assert hd(fc_parts)["function_call"]["name"] == "get_temp"

      # Second: function_response
      fr_parts = Enum.at(events, 1).content["parts"]
      assert hd(fr_parts)["function_response"].name == "get_temp"

      # Third: final text
      assert Event.text(List.last(events)) == "Berlin is 20°C."
    end

    test "LLM error produces error event" do
      agent =
        Custom.new(
          name: "err_sim",
          run_fn: fn _agent, _ctx ->
            case ADK.LLM.generate("test", %{}) do
              {:ok, resp} ->
                text = hd(resp.content.parts).text

                [
                  Event.new(%{
                    author: "err_sim",
                    content: %{"role" => "model", "parts" => [%{"text" => text}]}
                  })
                ]

              {:error, reason} ->
                [Event.new(%{author: "err_sim", error: reason})]
            end
          end
        )

      # Force error backend
      Application.put_env(:adk, :llm_backend, ADK.LLM.AlwaysErrorFlow)
      on_exit(fn -> Application.put_env(:adk, :llm_backend, ADK.LLM.Mock) end)

      events = run_agent(agent, "Hi")
      assert length(events) == 1
      assert hd(events).error == :internal_server_error
    end

    test "multi-turn: two sequential tool calls" do
      ADK.LLM.Mock.set_responses([
        %{function_call: %{name: "step", args: %{}, id: "fc-1"}},
        %{function_call: %{name: "step", args: %{}, id: "fc-2"}},
        "Done after 2 steps."
      ])

      call_count = :counters.new(1, [:atomics])

      agent =
        Custom.new(
          name: "multi_turn",
          run_fn: fn _agent, _ctx ->
            events = []

            # Turn 1
            {:ok, resp1} = ADK.LLM.generate("test", %{})

            case Map.get(hd(resp1.content.parts), :function_call) do
              nil ->
                events

              fc1 ->
                :counters.add(call_count, 1, 1)

                events =
                  events ++
                    [
                      make_event("call:#{fc1.name}", "multi_turn"),
                      make_event("result:step1", "multi_turn")
                    ]

                # Turn 2
                {:ok, resp2} = ADK.LLM.generate("test", %{})

                case Map.get(hd(resp2.content.parts), :function_call) do
                  nil ->
                    events ++ [make_event(hd(resp2.content.parts).text, "multi_turn")]

                  fc2 ->
                    :counters.add(call_count, 1, 1)

                    events =
                      events ++
                        [
                          make_event("call:#{fc2.name}", "multi_turn"),
                          make_event("result:step2", "multi_turn")
                        ]

                    # Turn 3 — final
                    {:ok, resp3} = ADK.LLM.generate("test", %{})
                    final = hd(resp3.content.parts).text
                    events ++ [make_event(final, "multi_turn")]
                end
            end
          end
        )

      events = run_agent(agent, "Do 2 steps")
      assert :counters.get(call_count, 1) == 2
      assert Event.text(List.last(events)) == "Done after 2 steps."
      assert length(events) == 5
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Tests: Callback.run_before/run_after for before_agent/after_agent
  # (unit level, mirrors Python's agent-level callback tests)
  # ────────────────────────────────────────────────────────────────────

  describe "agent-level callbacks (unit)" do
    test "before_agent halt returns events directly" do
      assert {:halt, events} =
               ADK.Callback.run_before([BeforeAgentHalt], :before_agent, %{})

      assert length(events) == 1
      assert Event.text(hd(events)) == "halted_before_agent"
    end

    test "after_agent appends event" do
      original = [make_event("original")]
      result = ADK.Callback.run_after([AfterAgentAppend], :after_agent, original, %{})

      assert length(result) == 2
      assert Event.text(Enum.at(result, 0)) == "original"
      assert Event.text(Enum.at(result, 1)) == "appended_by_after_agent"
    end
  end
end

# ── Error mock for flow tests ────────────────────────────────────────

defmodule ADK.LLM.AlwaysErrorFlow do
  @moduledoc false
  @behaviour ADK.LLM

  @impl true
  def generate(_model, _request), do: {:error, :internal_server_error}
end
