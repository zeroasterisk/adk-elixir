defmodule ADK.Plugin.DebugLoggingTest do
  use ExUnit.Case, async: true

  alias ADK.Plugin.DebugLogging

  setup do
    output_path = "test_adk_debug_#{System.unique_integer([:positive])}.yaml"
    
    on_exit(fn ->
      File.rm(output_path)
    end)
    
    {:ok, output_path: output_path}
  end

  defp parse_yaml(content) do
    content
    |> String.split("---\n", trim: true)
    |> Enum.map(&Jason.decode!(&1))
  end

  # -- Initialization --

  describe "Initialization" do
    test "init with defaults" do
      assert {:ok, state} = DebugLogging.init([])
      assert state.output_path == "adk_debug.yaml"
      assert state.include_session_state == true
      assert state.include_system_instruction == true
    end

    test "init with custom config", %{output_path: path} do
      assert {:ok, state} = DebugLogging.init(
        output_path: path,
        include_session_state: false,
        include_system_instruction: false
      )
      assert state.output_path == path
      assert state.include_session_state == false
      assert state.include_system_instruction == false
    end
  end

  # -- Callbacks --

  describe "Callbacks" do
    setup %{output_path: path} do
      {:ok, state} = DebugLogging.init(output_path: path)
      {:ok, session_pid} = ADK.Session.start_link(session_id: "test-session-id", initial_state: %{"key1" => "value1", "key2" => 123})
      agent = ADK.Agent.Custom.new(name: "test-agent", run_fn: fn _, _ -> [] end)
      
      context = %ADK.Context{
        invocation_id: "test-invocation-id",
        agent: agent,
        session_pid: session_pid
      }
      
      {:ok, %{state: state, context: context, path: path}}
    end

    test "before_run initializes state", %{state: state, context: context} do
      assert {:cont, ^context, ^state} = DebugLogging.before_run(context, state)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      assert pdict.invocation_id == "test-invocation-id"
      assert pdict.session_id == "test-session-id"
      assert length(pdict.entries) == 1
      assert hd(pdict.entries)["entry_type"] == "invocation_start"
      assert hd(pdict.entries)["data"]["agent_name"] == "test-agent"
    end

    test "on_event user message logs message", %{state: state, context: context} do
      DebugLogging.before_run(context, state)
      
      event = ADK.Event.new(%{
        author: "user",
        content: %{text: "Hello, world!"}
      })
      
      assert :ok = DebugLogging.on_event(context, event)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      entries = pdict.entries
      assert length(entries) == 2
      user_msg = hd(entries)
      assert user_msg["entry_type"] == "user_message"
      assert user_msg["data"]["content"]["role"] == "user"
      assert hd(user_msg["data"]["content"]["parts"])["text"] == "Hello, world!"
    end

    test "before_model logs request", %{state: state, context: context} do
      DebugLogging.before_run(context, state)
      
      request = %{
        model: "gemini-2.0-flash",
        messages: [%{role: "user", parts: [%{text: "Test prompt"}]}],
        system_instruction: "You are a helpful assistant."
      }
      
      assert {:ok, ^request} = DebugLogging.before_model(context, request)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      req_entry = hd(pdict.entries)
      assert req_entry["entry_type"] == "llm_request"
      assert req_entry["data"]["model"] == "gemini-2.0-flash"
      assert req_entry["data"]["content_count"] == 1
      assert req_entry["data"]["config"]["system_instruction"] == "You are a helpful assistant."
    end

    test "after_model logs response", %{state: state, context: context} do
      DebugLogging.before_run(context, state)
      
      response = {:ok, %{text: "Hello! How can I help?"}}
      assert ^response = DebugLogging.after_model(context, response)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      resp_entry = hd(pdict.entries)
      assert resp_entry["entry_type"] == "llm_response"
      assert resp_entry["data"]["turn_complete"] == true
      assert resp_entry["data"]["content"]["role"] == "model"
      assert hd(resp_entry["data"]["content"]["parts"])["text"] == "Hello! How can I help?"
    end

    test "before_tool logs tool call", %{state: state, context: context} do
      DebugLogging.before_run(context, state)
      
      args = %{"param1" => "value1", "param2" => 42}
      assert {:ok, ^args} = DebugLogging.before_tool(context, "test_tool", args)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      tool_entry = hd(pdict.entries)
      assert tool_entry["entry_type"] == "tool_call"
      assert tool_entry["data"]["tool_name"] == "test_tool"
      assert tool_entry["data"]["args"]["param1"] == "value1"
      assert tool_entry["data"]["args"]["param2"] == 42
    end

    test "after_tool logs tool response", %{state: state, context: context} do
      DebugLogging.before_run(context, state)
      
      result = {:ok, %{"output" => "success", "data" => [1, 2, 3]}}
      assert ^result = DebugLogging.after_tool(context, "test_tool", result)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      tool_entry = hd(pdict.entries)
      assert tool_entry["entry_type"] == "tool_response"
      assert tool_entry["data"]["tool_name"] == "test_tool"
      assert tool_entry["data"]["result"]["output"] == "success"
    end

    test "on_event logs event", %{state: state, context: context} do
      DebugLogging.before_run(context, state)
      
      event = ADK.Event.new(%{author: "test-agent", id: "evt-123"})
      assert :ok = DebugLogging.on_event(context, event)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      evt_entry = hd(pdict.entries)
      assert evt_entry["entry_type"] == "event"
      assert evt_entry["data"]["author"] == "test-agent"
      assert evt_entry["data"]["event_id"] == "evt-123"
    end

    test "on_model_error logs error", %{state: state, context: context} do
      DebugLogging.before_run(context, state)
      
      error = %RuntimeError{message: "Test error message"}
      err_tuple = {:error, error}
      
      assert ^err_tuple = DebugLogging.on_model_error(context, err_tuple)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      err_entry = hd(pdict.entries)
      assert err_entry["entry_type"] == "llm_error"
      assert err_entry["data"]["error_type"] == "RuntimeError"
      assert err_entry["data"]["error_message"] =~ "Test error message"
    end

    test "on_tool_error logs error", %{state: state, context: context} do
      DebugLogging.before_run(context, state)
      
      error = %RuntimeError{message: "Tool execution failed"}
      err_tuple = {:error, error}
      
      assert ^err_tuple = DebugLogging.on_tool_error(context, "test_tool", err_tuple)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      err_entry = hd(pdict.entries)
      assert err_entry["entry_type"] == "tool_error"
      assert err_entry["data"]["tool_name"] == "test_tool"
      assert err_entry["data"]["error_type"] == "RuntimeError"
      assert err_entry["data"]["error_message"] =~ "Tool execution failed"
    end
  end

  # -- File Output --

  describe "File Output" do
    setup %{output_path: path} do
      {:ok, state} = DebugLogging.init(output_path: path)
      {:ok, session_pid} = ADK.Session.start_link(session_id: "test-session-id", initial_state: %{"key1" => "value1"})
      agent = ADK.Agent.Custom.new(name: "test-agent", run_fn: fn _, _ -> [] end)
      
      context = %ADK.Context{
        invocation_id: "test-invocation-id",
        agent: agent,
        session_pid: session_pid
      }
      
      {:ok, %{state: state, context: context, path: path}}
    end

    test "after_run writes to file", %{state: state, context: context, path: path} do
      DebugLogging.before_run(context, state)
      
      event = ADK.Event.new(%{author: "user", content: %{text: "Test message"}})
      DebugLogging.on_event(context, event)
      
      DebugLogging.after_run([], context, state)
      
      assert File.exists?(path)
      
      content = File.read!(path)
      documents = parse_yaml(content)
      
      assert length(documents) == 1
      data = hd(documents)
      assert data["invocation_id"] == "test-invocation-id"
      assert data["session_id"] == "test-session-id"
      assert length(data["entries"]) >= 2
    end

    test "after_run includes session state when enabled", %{state: state, context: context, path: path} do
      DebugLogging.before_run(context, state)
      DebugLogging.after_run([], context, state)
      
      documents = parse_yaml(File.read!(path))
      data = hd(documents)
      
      session_state_entries = Enum.filter(data["entries"], fn e -> e["entry_type"] == "session_state_snapshot" end)
      assert length(session_state_entries) == 1
      assert hd(session_state_entries)["data"]["state"]["key1"] == "value1"
    end

    test "after_run excludes session state when disabled", %{path: path, context: context} do
      {:ok, state} = DebugLogging.init(output_path: path, include_session_state: false)
      
      DebugLogging.before_run(context, state)
      DebugLogging.after_run([], context, state)
      
      documents = parse_yaml(File.read!(path))
      data = hd(documents)
      
      session_state_entries = Enum.filter(data["entries"], fn e -> e["entry_type"] == "session_state_snapshot" end)
      assert Enum.empty?(session_state_entries)
    end

    test "multiple invocations append to file", %{state: state, context: context, path: path} do
      # First invocation
      DebugLogging.before_run(context, state)
      DebugLogging.after_run([], context, state)
      
      # Second invocation
      ctx2 = %{context | invocation_id: "invocation-2"}
      DebugLogging.before_run(ctx2, state)
      DebugLogging.after_run([], ctx2, state)
      
      documents = parse_yaml(File.read!(path))
      assert length(documents) == 2
      assert Enum.at(documents, 0)["invocation_id"] == "test-invocation-id"
      assert Enum.at(documents, 1)["invocation_id"] == "invocation-2"
    end

    test "after_run cleans up state", %{state: state, context: context} do
      DebugLogging.before_run(context, state)
      assert Process.get({{DebugLogging, :state}, "test-invocation-id"}) != nil
      
      DebugLogging.after_run([], context, state)
      assert Process.get({{DebugLogging, :state}, "test-invocation-id"}) == nil
    end
  end

  # -- Configs --

  describe "System Instruction Config" do
    setup %{output_path: path} do
      {:ok, session_pid} = ADK.Session.start_link(session_id: "test-session-id")
      agent = ADK.Agent.Custom.new(name: "test-agent", run_fn: fn _, _ -> [] end)
      
      context = %ADK.Context{
        invocation_id: "test-invocation-id",
        agent: agent,
        session_pid: session_pid
      }
      
      {:ok, %{context: context, path: path}}
    end

    test "system instruction included when enabled", %{context: context, path: path} do
      {:ok, state} = DebugLogging.init(output_path: path, include_system_instruction: true)
      
      DebugLogging.before_run(context, state)
      
      request = %{model: "gemini-2.0-flash", system_instruction: "Full system instruction text"}
      DebugLogging.before_model(context, request)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      req_entry = Enum.find(pdict.entries, fn e -> e["entry_type"] == "llm_request" end)
      
      assert req_entry["data"]["config"]["system_instruction"] == "Full system instruction text"
    end

    test "system instruction length only when disabled", %{context: context, path: path} do
      {:ok, state} = DebugLogging.init(output_path: path, include_system_instruction: false)
      
      DebugLogging.before_run(context, state)
      
      request = %{model: "gemini-2.0-flash", system_instruction: "Full system instruction text"}
      DebugLogging.before_model(context, request)
      
      pdict = Process.get({{DebugLogging, :state}, "test-invocation-id"})
      req_entry = Enum.find(pdict.entries, fn e -> e["entry_type"] == "llm_request" end)
      
      refute Map.has_key?(req_entry["data"]["config"], "system_instruction")
      assert req_entry["data"]["config"]["system_instruction_length"] == 28
    end
  end
end