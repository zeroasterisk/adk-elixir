defmodule ADK.Agent.LiveRequestQueueTest do
  use ExUnit.Case, async: true

  alias ADK.Agent.LiveRequestQueue

  test "close_queue/1" do
    queue = LiveRequestQueue.new()
    queue = LiveRequestQueue.close(queue)
    assert queue.requests == [{:close}]
  end

  test "send_content/2" do
    queue = LiveRequestQueue.new()
    content = %{parts: [%{text: "Hello"}]}
    queue = LiveRequestQueue.send_content(queue, content)
    assert queue.requests == [{:content, content}]
  end

  test "send_realtime/2" do
    queue = LiveRequestQueue.new()
    blob = %{mime_type: "application/octet-stream", data: <<1, 2, 3>>}
    queue = LiveRequestQueue.send_realtime(queue, blob)
    assert queue.requests == [{:blob, blob}]
  end

  test "send/2" do
    queue = LiveRequestQueue.new()
    req = %{content: %{parts: [%{text: "Hello"}]}}
    queue = LiveRequestQueue.send(queue, req)
    assert queue.requests == [req]
  end

  test "get/1" do
    queue = LiveRequestQueue.new()
    content = %{parts: [%{text: "Hello"}]}
    queue = LiveRequestQueue.send_content(queue, content)
    {result, _queue} = LiveRequestQueue.get(queue)
    assert result == {:content, content}
  end
end
