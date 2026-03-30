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

defmodule ADK.Flows.LlmFlows.ContextCacheProcessorParityTest do
  @moduledoc """
  Parity tests for Python's test_context_cache_processor.py.

  Python's ContextCacheRequestProcessor scans session events to:
  1. Attach cache_config from invocation context to the LLM request
  2. Find the latest cache_metadata for the current agent from session events
  3. Increment invocations_used when metadata comes from a different invocation
  4. Extract cacheable_contents_token_count from usage_metadata

  We test these behaviors using a local helper module that implements the
  event-scanning logic, validating the same behavioral contracts as Python.
  """

  use ExUnit.Case, async: true

  alias ADK.Agents.ContextCacheConfig
  alias ADK.Models.CacheMetadata

  # ---------------------------------------------------------------------------
  # Local helper: mirrors Python's ContextCacheRequestProcessor.run_async
  # ---------------------------------------------------------------------------

  defmodule Processor do
    @moduledoc false

    @doc """
    Process an LLM request by attaching cache config and scanning session events
    for cache metadata and token counts — mirrors the Python processor logic.

    Returns `{events_yielded, updated_llm_request}`.
    """
    def run(invocation_context, llm_request) do
      cache_config = invocation_context[:context_cache_config]

      if cache_config == nil do
        # No cache config → no-op
        {[], llm_request}
      else
        llm_request = Map.put(llm_request, :cache_config, cache_config)

        agent_name = get_in(invocation_context, [:agent, :name])
        invocation_id = invocation_context[:invocation_id]
        session_events = get_in(invocation_context, [:session, :events]) || []

        # Find latest cache metadata for this agent (scan in reverse)
        {llm_request, _} =
          session_events
          |> Enum.reverse()
          |> Enum.reduce({llm_request, false}, fn event, {req, found?} = acc ->
            if found? do
              acc
            else
              if event.author == agent_name && event_cache_metadata(event) != nil do
                meta = event_cache_metadata(event)

                meta =
                  if event.invocation_id != invocation_id do
                    %{meta | invocations_used: (meta.invocations_used || 0) + 1}
                  else
                    meta
                  end

                {Map.put(req, :cache_metadata, meta), true}
              else
                acc
              end
            end
          end)

        # Find latest token count for this agent (scan in reverse)
        {llm_request, _} =
          session_events
          |> Enum.reverse()
          |> Enum.reduce({llm_request, false}, fn event, {req, found?} = acc ->
            if found? do
              acc
            else
              if event.author == agent_name && event_usage_metadata(event) != nil do
                usage = event_usage_metadata(event)
                token_count = usage[:prompt_token_count]
                {Map.put(req, :cacheable_contents_token_count, token_count), true}
              else
                acc
              end
            end
          end)

        # Processor yields no events
        {[], llm_request}
      end
    end

    defp event_cache_metadata(%{cache_metadata: meta}) when not is_nil(meta), do: meta
    defp event_cache_metadata(_), do: nil

    defp event_usage_metadata(%{usage_metadata: meta}) when not is_nil(meta), do: meta
    defp event_usage_metadata(_), do: nil
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp cache_config(overrides \\ []) do
    defaults = [cache_intervals: 10, ttl_seconds: 1800, min_tokens: 1024]
    ContextCacheConfig.new(Keyword.merge(defaults, overrides))
  end

  defp make_cache_metadata(opts) do
    invocations_used = Keyword.get(opts, :invocations_used, 1)
    cache_name = Keyword.get(opts, :cache_name, "test-cache")
    contents_count = Keyword.get(opts, :contents_count, 3)
    now = :os.system_time(:second)

    CacheMetadata.new(
      cache_name: "projects/test/locations/us-central1/cachedContents/#{cache_name}",
      expire_time: now + 1800 + 0.0,
      fingerprint: "test_fingerprint",
      invocations_used: invocations_used,
      contents_count: contents_count,
      created_at: now - 600 + 0.0
    )
  end

  defp make_event(opts) do
    # Simple event map matching ADK.Event fields used by the processor
    %{
      author: Keyword.get(opts, :author),
      cache_metadata: Keyword.get(opts, :cache_metadata),
      usage_metadata: Keyword.get(opts, :usage_metadata),
      invocation_id: Keyword.get(opts, :invocation_id)
    }
  end

  defp make_invocation_context(opts) do
    %{
      agent: %{name: Keyword.get(opts, :agent_name, "test_agent")},
      session: %{events: Keyword.get(opts, :session_events, [])},
      context_cache_config: Keyword.get(opts, :context_cache_config),
      invocation_id: Keyword.get(opts, :invocation_id, "test_invocation")
    }
  end

  defp make_llm_request do
    %{
      model: "gemini-2.0-flash",
      contents: [%{role: "user", parts: [%{text: "Hello"}]}]
    }
  end

  # ---------------------------------------------------------------------------
  # Tests — ported from test_context_cache_processor.py
  # ---------------------------------------------------------------------------

  describe "no cache config" do
    test "processor with no cache config is a no-op" do
      ctx = make_invocation_context(context_cache_config: nil)
      req = make_llm_request()

      {events, updated_req} = Processor.run(ctx, req)

      assert events == []
      assert Map.get(updated_req, :cache_config) == nil
    end
  end

  describe "with cache config, no session events" do
    test "cache config is attached but no metadata" do
      config = cache_config()
      ctx = make_invocation_context(context_cache_config: config)
      req = make_llm_request()

      {events, updated_req} = Processor.run(ctx, req)

      assert events == []
      assert updated_req.cache_config == config
      assert Map.get(updated_req, :cache_metadata) == nil
    end
  end

  describe "cache metadata from same invocation" do
    test "metadata found, invocations_used NOT incremented" do
      meta = make_cache_metadata(invocations_used: 5)

      session_events = [
        make_event(
          author: "test_agent",
          cache_metadata: meta,
          invocation_id: "test_invocation"
        )
      ]

      ctx =
        make_invocation_context(
          context_cache_config: cache_config(),
          session_events: session_events,
          invocation_id: "test_invocation"
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cache_config == cache_config()
      assert updated_req.cache_metadata == meta
      assert updated_req.cache_metadata.invocations_used == 5
    end
  end

  describe "cache metadata from different invocation" do
    test "metadata found, invocations_used IS incremented" do
      meta = make_cache_metadata(invocations_used: 5)

      session_events = [
        make_event(
          author: "test_agent",
          cache_metadata: meta,
          invocation_id: "previous_invocation"
        )
      ]

      ctx =
        make_invocation_context(
          context_cache_config: cache_config(),
          session_events: session_events,
          invocation_id: "current_invocation"
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cache_config == cache_config()
      assert updated_req.cache_metadata != nil
      assert updated_req.cache_metadata.invocations_used == 6
    end
  end

  describe "agent filtering" do
    test "cache metadata is filtered by agent name" do
      target_cache = make_cache_metadata(invocations_used: 3, cache_name: "target")
      other_cache = make_cache_metadata(invocations_used: 7, cache_name: "other")

      session_events = [
        make_event(
          author: "other_agent",
          cache_metadata: other_cache,
          invocation_id: "other_invocation"
        ),
        make_event(
          author: "target_agent",
          cache_metadata: target_cache,
          invocation_id: "target_invocation"
        )
      ]

      ctx =
        make_invocation_context(
          agent_name: "target_agent",
          context_cache_config: cache_config(),
          session_events: session_events,
          invocation_id: "current_invocation"
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cache_metadata != nil
      assert updated_req.cache_metadata.cache_name == target_cache.cache_name
      # target_cache (3) + 1 for different invocation
      assert updated_req.cache_metadata.invocations_used == 4
    end
  end

  describe "latest metadata selected" do
    test "the most recent cache metadata is selected" do
      older_cache = make_cache_metadata(invocations_used: 2, cache_name: "older")
      newer_cache = make_cache_metadata(invocations_used: 5, cache_name: "newer")

      # Events in chronological order (older first)
      session_events = [
        make_event(
          author: "test_agent",
          cache_metadata: older_cache,
          invocation_id: "older_invocation"
        ),
        make_event(
          author: "test_agent",
          cache_metadata: newer_cache,
          invocation_id: "newer_invocation"
        )
      ]

      ctx =
        make_invocation_context(
          context_cache_config: cache_config(),
          session_events: session_events,
          invocation_id: "current_invocation"
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cache_metadata != nil
      assert updated_req.cache_metadata.cache_name == newer_cache.cache_name
      assert updated_req.cache_metadata.invocations_used == 6
    end
  end

  describe "no cache metadata in events" do
    test "events exist but none have cache metadata" do
      session_events = [
        make_event(author: "test_agent", cache_metadata: nil),
        make_event(author: "other_agent", cache_metadata: nil)
      ]

      ctx =
        make_invocation_context(
          context_cache_config: cache_config(),
          session_events: session_events
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cache_config == cache_config()
      assert Map.get(updated_req, :cache_metadata) == nil
    end
  end

  describe "empty session" do
    test "empty session gets cache config but no metadata" do
      ctx =
        make_invocation_context(
          context_cache_config: cache_config(),
          session_events: []
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cache_config == cache_config()
      assert Map.get(updated_req, :cache_metadata) == nil
    end
  end

  describe "processor yields no events" do
    test "processor never yields events regardless of input" do
      ctx = make_invocation_context(context_cache_config: cache_config())
      {events, _req} = Processor.run(ctx, make_llm_request())
      assert events == []
    end
  end

  describe "mixed events scenario" do
    test "complex scenario with mixed events finds correct metadata" do
      cache_metadata = make_cache_metadata(invocations_used: 10)

      session_events = [
        make_event(author: "other_agent", cache_metadata: nil),
        make_event(author: "test_agent", cache_metadata: nil),
        make_event(
          author: "different_agent",
          cache_metadata: cache_metadata,
          invocation_id: "diff"
        ),
        make_event(
          author: "test_agent",
          cache_metadata: cache_metadata,
          invocation_id: "prev"
        )
      ]

      ctx =
        make_invocation_context(
          context_cache_config: cache_config(),
          session_events: session_events,
          invocation_id: "current"
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cache_config == cache_config()
      assert updated_req.cache_metadata != nil
      # 10 + 1 (different invocation)
      assert updated_req.cache_metadata.invocations_used == 11
    end
  end

  describe "token count extraction" do
    test "prompt token count extracted from usage metadata" do
      session_events = [
        make_event(
          author: "test_agent",
          usage_metadata: %{
            prompt_token_count: 1024,
            response_token_count: 256,
            total_token_count: 1280
          }
        )
      ]

      ctx =
        make_invocation_context(
          context_cache_config: cache_config(),
          session_events: session_events
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cacheable_contents_token_count == 1024
    end

    test "no usage metadata leaves token count unset" do
      session_events = [
        make_event(author: "test_agent", usage_metadata: nil),
        make_event(author: "other_agent", usage_metadata: nil)
      ]

      ctx =
        make_invocation_context(
          context_cache_config: cache_config(),
          session_events: session_events
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert Map.get(updated_req, :cacheable_contents_token_count) == nil
    end

    test "token count filtered by agent name" do
      session_events = [
        make_event(
          author: "other_agent",
          usage_metadata: %{prompt_token_count: 2048}
        ),
        make_event(
          author: "target_agent",
          usage_metadata: %{prompt_token_count: 1024}
        )
      ]

      ctx =
        make_invocation_context(
          agent_name: "target_agent",
          context_cache_config: cache_config(),
          session_events: session_events
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cacheable_contents_token_count == 1024
    end

    test "latest token count is selected" do
      session_events = [
        make_event(
          author: "test_agent",
          usage_metadata: %{prompt_token_count: 512}
        ),
        make_event(
          author: "test_agent",
          usage_metadata: %{prompt_token_count: 1024}
        )
      ]

      ctx =
        make_invocation_context(
          context_cache_config: cache_config(),
          session_events: session_events
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cacheable_contents_token_count == 1024
    end
  end

  describe "combined cache metadata and token count" do
    test "both found in single pass from same event" do
      cache_metadata = make_cache_metadata(invocations_used: 5)

      session_events = [
        make_event(
          author: "test_agent",
          cache_metadata: cache_metadata,
          usage_metadata: %{prompt_token_count: 1024},
          invocation_id: "previous_invocation"
        )
      ]

      ctx =
        make_invocation_context(
          context_cache_config: cache_config(),
          session_events: session_events,
          invocation_id: "current_invocation"
        )

      {_events, updated_req} = Processor.run(ctx, make_llm_request())

      assert updated_req.cache_metadata != nil
      assert updated_req.cache_metadata.invocations_used == 6
      assert updated_req.cacheable_contents_token_count == 1024
    end
  end
end
