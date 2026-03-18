defmodule ADK.Agents.LiveRequestQueueParityTest do
  @moduledoc """
  Parity placeholder for Python ADK's `tests/unittests/agents/test_live_request_queue.py`.

  ## Why skipped

  Python's `LiveRequestQueue` is a realtime/live streaming component that wraps
  an `asyncio.Queue` to manage live audio/video request ordering for the Gemini
  Live API. It provides:

    - `close/0` — enqueues a sentinel `LiveRequest(close=True)`
    - `send_content/1` — enqueues `LiveRequest(content=...)` for text content
    - `send_realtime/1` — enqueues `LiveRequest(blob=...)` for binary audio/video
    - `send/1` — enqueues an arbitrary `LiveRequest`
    - `get/0` — async dequeue (await next request)

  ADK Elixir does not yet have a live realtime streaming infrastructure equivalent.
  There is no `ADK.Agent.LiveRequestQueue` module in `lib/`.

  Note: An earlier test file exists at `test/adk/live_request_queue_test.exs` with
  5 tests that fail because the module is not implemented. This parity file documents
  the Python test scenarios for future reference when live streaming is added.

  ## Python test scenarios (5 tests)

  1. `test_close_queue` — closing enqueues a `LiveRequest(close=True)` sentinel
  2. `test_send_content` — `send_content(content)` enqueues `LiveRequest(content=content)`
  3. `test_send_realtime` — `send_realtime(blob)` enqueues `LiveRequest(blob=blob)`
  4. `test_send` — `send(req)` enqueues an arbitrary `LiveRequest`
  5. `test_get` — `get()` async dequeues the next request from the queue
  """
  use ExUnit.Case, async: true

  @moduletag :skip

  test "close_queue enqueues close sentinel" do
    # Python: queue.close() → put_nowait(LiveRequest(close=True))
    # Elixir: not implemented — no LiveRequestQueue module
  end

  test "send_content enqueues content request" do
    # Python: queue.send_content(content) → put_nowait(LiveRequest(content=content))
  end

  test "send_realtime enqueues blob request" do
    # Python: queue.send_realtime(blob) → put_nowait(LiveRequest(blob=blob))
  end

  test "send enqueues arbitrary request" do
    # Python: queue.send(req) → put_nowait(req)
  end

  test "get dequeues next request" do
    # Python: await queue.get() → returns next item from asyncio.Queue
  end
end
