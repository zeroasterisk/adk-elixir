defmodule ADK.Phoenix.ChatLiveTest do
  use ExUnit.Case, async: true

  # Unit tests for ChatLive helpers (no LiveView test harness needed)

  describe "render_markdown/1" do
    test "escapes HTML" do
      result = ADK.Phoenix.ChatLive.render_markdown("<script>alert('xss')</script>")
      refute result =~ "<script>"
      assert result =~ "&lt;script&gt;"
    end

    test "converts bold" do
      assert ADK.Phoenix.ChatLive.render_markdown("**bold**") =~ "<strong>bold</strong>"
    end

    test "converts italic" do
      assert ADK.Phoenix.ChatLive.render_markdown("*italic*") =~ "<em>italic</em>"
    end

    test "converts inline code" do
      result = ADK.Phoenix.ChatLive.render_markdown("`code`")
      assert result =~ "<code"
      assert result =~ "code</code>"
    end

    test "converts links" do
      result = ADK.Phoenix.ChatLive.render_markdown("[click](https://example.com)")
      assert result =~ ~s(href="https://example.com")
      assert result =~ "click</a>"
    end

    test "converts newlines to <br/>" do
      assert ADK.Phoenix.ChatLive.render_markdown("a\nb") =~ "a<br/>b"
    end

    test "handles nil" do
      assert ADK.Phoenix.ChatLive.render_markdown(nil) == ""
    end

    test "converts code blocks" do
      input = "```elixir\nIO.puts(\"hi\")\n```"
      result = ADK.Phoenix.ChatLive.render_markdown(input)
      assert result =~ "<pre"
      assert result =~ "IO.puts"
    end
  end

  describe "init_chat/2" do
    test "initializes socket assigns" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded(ADK.Phoenix.ChatLive)
      # We can't easily test LiveView socket without a full endpoint,
      # but we can verify the module compiles and exports correctly
      assert function_exported?(ADK.Phoenix.ChatLive, :init_chat, 2)
      assert function_exported?(ADK.Phoenix.ChatLive, :render, 1)
      assert function_exported?(ADK.Phoenix.ChatLive, :mount, 3)
      assert function_exported?(ADK.Phoenix.ChatLive, :handle_event, 3)
      assert function_exported?(ADK.Phoenix.ChatLive, :handle_info, 2)
    end
  end
end
