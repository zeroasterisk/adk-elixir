defmodule ADK.Tool.SendA2UITest do
  use ExUnit.Case, async: true
  alias ADK.Tool.SendA2UI

  test "run/2 returns validated json" do
    tool = SendA2UI.new()
    args = %{"a2ui_json" => ~s({"type": "text", "content": "hello"})}
    assert {:ok, %{"validated_a2ui_json" => %{"type" => "text", "content" => "hello"}}} = SendA2UI.run(nil, args)
  end
end
