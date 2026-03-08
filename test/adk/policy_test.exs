defmodule ADK.PolicyTest do
  use ExUnit.Case, async: true

  alias ADK.Policy
  alias ADK.Context

  defmodule AllowAllPolicy do
    @behaviour ADK.Policy

    @impl true
    def authorize_tool(_tool, _args, _ctx), do: :allow

    @impl true
    def filter_input(content, _ctx), do: {:cont, content}

    @impl true
    def filter_output(events, _ctx), do: events
  end

  defmodule DenyDangerousPolicy do
    @behaviour ADK.Policy

    @impl true
    def authorize_tool(%{name: "dangerous"}, _args, _ctx), do: {:deny, "tool is dangerous"}
    def authorize_tool(_tool, _args, _ctx), do: :allow
  end

  defmodule BlockBadWordsPolicy do
    @behaviour ADK.Policy

    @impl true
    def filter_input(%{text: text} = content, _ctx) do
      if String.contains?(text, "bad_word") do
        {:halt, [ADK.Event.new(%{invocation_id: "test", author: "policy", content: %{parts: [%{text: "Input blocked"}]}})]}
      else
        {:cont, content}
      end
    end
  end

  defmodule UppercaseOutputPolicy do
    @behaviour ADK.Policy

    @impl true
    def filter_output(events, _ctx) do
      Enum.map(events, fn event ->
        case event.content do
          %{parts: parts} ->
            new_parts = Enum.map(parts, fn
              %{text: t} -> %{text: String.upcase(t)}
              other -> other
            end)
            %{event | content: %{parts: new_parts}}
          _ -> event
        end
      end)
    end
  end

  defmodule RedactOutputPolicy do
    @behaviour ADK.Policy

    @impl true
    def filter_output(events, _ctx) do
      Enum.map(events, fn event ->
        case event.content do
          %{parts: parts} ->
            new_parts = Enum.map(parts, fn
              %{text: t} -> %{text: String.replace(t, "secret", "[REDACTED]")}
              other -> other
            end)
            %{event | content: %{parts: new_parts}}
          _ -> event
        end
      end)
    end
  end

  defp ctx, do: %Context{invocation_id: "test", policies: []}

  describe "check_tool_authorization/4" do
    test "allows when no policies" do
      assert :allow == Policy.check_tool_authorization([], %{name: "foo"}, %{}, ctx())
    end

    test "allows with permissive policy" do
      assert :allow == Policy.check_tool_authorization([AllowAllPolicy], %{name: "foo"}, %{}, ctx())
    end

    test "denies dangerous tool" do
      assert {:deny, "tool is dangerous"} ==
               Policy.check_tool_authorization([DenyDangerousPolicy], %{name: "dangerous"}, %{}, ctx())
    end

    test "allows safe tool through deny policy" do
      assert :allow == Policy.check_tool_authorization([DenyDangerousPolicy], %{name: "safe"}, %{}, ctx())
    end

    test "first deny wins in composition" do
      assert {:deny, "tool is dangerous"} ==
               Policy.check_tool_authorization(
                 [AllowAllPolicy, DenyDangerousPolicy],
                 %{name: "dangerous"},
                 %{},
                 ctx()
               )
    end
  end

  describe "run_input_filters/3" do
    test "passes through with no policies" do
      assert {:cont, %{text: "hello"}} == Policy.run_input_filters([], %{text: "hello"}, ctx())
    end

    test "passes through with permissive policy" do
      assert {:cont, %{text: "hello"}} ==
               Policy.run_input_filters([AllowAllPolicy], %{text: "hello"}, ctx())
    end

    test "halts on bad content" do
      assert {:halt, [%ADK.Event{} | _]} =
               Policy.run_input_filters([BlockBadWordsPolicy], %{text: "bad_word here"}, ctx())
    end

    test "continues on clean content" do
      assert {:cont, %{text: "good content"}} ==
               Policy.run_input_filters([BlockBadWordsPolicy], %{text: "good content"}, ctx())
    end
  end

  describe "run_output_filters/3" do
    test "returns events unchanged with no policies" do
      events = [ADK.Event.new(%{invocation_id: "test", author: "bot", content: %{parts: [%{text: "hi"}]}})]
      assert events == Policy.run_output_filters([], events, ctx())
    end

    test "transforms output" do
      events = [ADK.Event.new(%{invocation_id: "test", author: "bot", content: %{parts: [%{text: "hi"}]}})]
      [event] = Policy.run_output_filters([UppercaseOutputPolicy], events, ctx())
      assert %{parts: [%{text: "HI"}]} = event.content
    end

    test "chains multiple output filters" do
      events = [ADK.Event.new(%{invocation_id: "test", author: "bot", content: %{parts: [%{text: "my secret data"}]}})]
      [event] = Policy.run_output_filters([RedactOutputPolicy, UppercaseOutputPolicy], events, ctx())
      assert %{parts: [%{text: "MY [REDACTED] DATA"}]} = event.content
    end
  end

  describe "DefaultPolicy" do
    test "allows all tools" do
      assert :allow == ADK.Policy.DefaultPolicy.authorize_tool(%{name: "anything"}, %{}, ctx())
    end

    test "passes input through" do
      assert {:cont, %{text: "hi"}} == ADK.Policy.DefaultPolicy.filter_input(%{text: "hi"}, ctx())
    end

    test "passes output through" do
      events = [ADK.Event.new(%{invocation_id: "test", author: "bot"})]
      assert ^events = ADK.Policy.DefaultPolicy.filter_output(events, ctx())
    end
  end

  describe "policies with no callbacks implemented" do
    defmodule EmptyPolicy do
      @behaviour ADK.Policy
    end

    test "skips modules without callbacks" do
      assert :allow == Policy.check_tool_authorization([EmptyPolicy], %{name: "foo"}, %{}, ctx())
      assert {:cont, %{text: "hi"}} == Policy.run_input_filters([EmptyPolicy], %{text: "hi"}, ctx())
      events = [ADK.Event.new(%{invocation_id: "test", author: "bot"})]
      assert ^events = Policy.run_output_filters([EmptyPolicy], events, ctx())
    end
  end
end
