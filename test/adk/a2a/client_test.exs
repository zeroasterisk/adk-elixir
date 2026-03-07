defmodule ADK.A2A.ClientTest do
  use ExUnit.Case, async: true

  alias ADK.A2A.Client

  describe "client functions handle connection errors" do
    test "get_agent_card/1" do
      assert {:error, _} = Client.get_agent_card("http://127.0.0.1:19999")
    end

    test "send_task/3" do
      assert {:error, _} = Client.send_task("http://127.0.0.1:19999", "hello")
    end

    test "get_task/2" do
      assert {:error, _} = Client.get_task("http://127.0.0.1:19999", "task-123")
    end

    test "cancel_task/2" do
      assert {:error, _} = Client.cancel_task("http://127.0.0.1:19999", "task-123")
    end
  end
end
