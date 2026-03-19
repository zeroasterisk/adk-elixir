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

defmodule ADK.Flows.LlmFlows.IdentityTest do
  @moduledoc """
  Parity tests for Python ADK's
  `tests/unittests/flows/llm_flows/test_identity.py`.

  Verifies identity instruction generation — how agent name and description
  are injected into the system instruction via `InstructionCompiler`.

  ## Python vs Elixir format divergence

  Python format:
    - No desc:  `You are an agent. Your internal name is "agent".`
    - With desc: `You are an agent. Your internal name is "agent". The description about you is "test description".`

  Elixir format:
    - No desc:  `You are agent.`
    - With desc: `You are agent. test description`

  The behavioral intent is identical — agent identity is injected into the
  system instruction — but the exact phrasing differs.
  """

  use ExUnit.Case, async: true

  alias ADK.Agent.LlmAgent
  alias ADK.InstructionCompiler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_ctx do
    %ADK.Context{
      invocation_id: "test_identity",
      session_pid: nil,
      agent: nil,
      user_content: %{text: "test"}
    }
  end

  # ---------------------------------------------------------------------------
  # Identity instruction — parity with test_identity.py
  # ---------------------------------------------------------------------------

  describe "identity instruction (parity: test_identity.py)" do
    test "agent with no description produces name-only identity" do
      # Python: test_no_description
      # Python produces: You are an agent. Your internal name is "agent".
      # Elixir produces: You are agent.
      agent = LlmAgent.new(name: "agent", model: "test", instruction: "")
      ctx = make_ctx()

      compiled = InstructionCompiler.compile(agent, ctx)

      assert compiled =~ "You are agent."
      refute compiled =~ "description"
    end

    test "agent with description includes description in identity" do
      # Python: test_with_description
      # Python produces: You are an agent. Your internal name is "agent".
      #                  The description about you is "test description".
      # Elixir produces: You are agent. test description
      agent =
        LlmAgent.new(
          name: "agent",
          model: "test",
          instruction: "",
          description: "test description"
        )

      ctx = make_ctx()

      compiled = InstructionCompiler.compile(agent, ctx)

      assert compiled =~ "You are agent."
      assert compiled =~ "test description"
    end

    test "identity instruction is placed in static part of split" do
      agent =
        LlmAgent.new(
          name: "my_bot",
          model: "test",
          instruction: "Do things.",
          description: "A test bot"
        )

      ctx = make_ctx()
      {static, dynamic} = InstructionCompiler.compile_split(agent, ctx)

      # Identity should be in static (cacheable) part
      assert static =~ "You are my_bot."
      assert static =~ "A test bot"
      # Dynamic should NOT contain identity
      refute dynamic =~ "You are my_bot."
    end
  end

  # ---------------------------------------------------------------------------
  # Extended identity edge cases
  # ---------------------------------------------------------------------------

  describe "identity instruction edge cases" do
    test "agent with empty string description omits description" do
      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "",
          description: ""
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      assert compiled =~ "You are bot."
      # Empty description should not add extra text
      refute compiled =~ "You are bot. "
    end

    test "agent with nil description omits description" do
      agent =
        LlmAgent.new(
          name: "bot",
          model: "test",
          instruction: "",
          description: nil
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      assert compiled =~ "You are bot."
    end

    test "identity uses agent name verbatim" do
      agent =
        LlmAgent.new(
          name: "My-Special_Agent.v2",
          model: "test",
          instruction: ""
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      assert compiled =~ "You are My-Special_Agent.v2."
    end

    test "identity with multiword description" do
      agent =
        LlmAgent.new(
          name: "helper",
          model: "test",
          instruction: "",
          description: "A helpful assistant that specializes in code review"
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      assert compiled =~ "You are helper."
      assert compiled =~ "A helpful assistant that specializes in code review"
    end

    test "identity combined with instruction and global_instruction" do
      agent =
        LlmAgent.new(
          name: "root",
          model: "test",
          instruction: "Be helpful.",
          global_instruction: "Always be safe.",
          description: "The main agent"
        )

      ctx = make_ctx()
      compiled = InstructionCompiler.compile(agent, ctx)

      # All parts should be present
      assert compiled =~ "Always be safe."
      assert compiled =~ "You are root."
      assert compiled =~ "The main agent"
      assert compiled =~ "Be helpful."
    end
  end
end
