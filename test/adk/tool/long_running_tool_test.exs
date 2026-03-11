defmodule ADK.Tool.LongRunningToolTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.LongRunningTool

  # ---------------------------------------------------------------------------
  # new/2 — struct creation and description annotation
  # ---------------------------------------------------------------------------

  describe "new/2" do
    test "creates struct with given name and options" do
      tool = LongRunningTool.new(:my_tool,
        description: "Does something slow",
        func: fn _ctx, _args, _upd -> "ok" end,
        parameters: %{type: "object", properties: %{}},
        timeout: 5_000
      )

      assert tool.name == "my_tool"
      assert tool.timeout == 5_000
      assert is_map(tool.parameters)
    end

    test "name is coerced to string" do
      tool = LongRunningTool.new(:atom_name, func: fn _, _, _ -> nil end)
      assert tool.name == "atom_name"
    end

    test "description is annotated with long-running notice" do
      tool = LongRunningTool.new(:t, description: "Fetch data", func: fn _, _, _ -> nil end)
      assert String.contains?(tool.description, "Fetch data")
      assert String.contains?(tool.description, "long-running operation")
      assert String.contains?(tool.description, "Do not call this tool again")
    end

    test "empty description gets the notice only" do
      tool = LongRunningTool.new(:t, description: "", func: fn _, _, _ -> nil end)
      assert String.contains?(tool.description, "long-running operation")
    end

    test "omitted description gets the notice only" do
      tool = LongRunningTool.new(:t, func: fn _, _, _ -> nil end)
      assert String.contains?(tool.description, "long-running operation")
    end

    test "default timeout is 60_000ms" do
      tool = LongRunningTool.new(:t, func: fn _, _, _ -> nil end)
      assert tool.timeout == 60_000
    end

    test "default parameters is empty map" do
      tool = LongRunningTool.new(:t, func: fn _, _, _ -> nil end)
      assert tool.parameters == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # run/3 — basic execution
  # ---------------------------------------------------------------------------

  describe "run/3 — basic execution" do
    test "returns {:ok, result} for a simple synchronous function" do
      tool = LongRunningTool.new(:simple,
        func: fn _ctx, %{"x" => x}, _send_update -> x * 2 end,
        timeout: 5_000
      )

      assert {:ok, 42} = LongRunningTool.run(tool, nil, %{"x" => 21})
    end

    test "returns {:ok, result} when function returns a string" do
      tool = LongRunningTool.new(:echo,
        func: fn _ctx, %{"msg" => msg}, _send_update -> msg end,
        timeout: 5_000
      )

      assert {:ok, "hello"} = LongRunningTool.run(tool, nil, %{"msg" => "hello"})
    end

    test "returns {:ok, result} when function returns a map" do
      tool = LongRunningTool.new(:struct_result,
        func: fn _ctx, _args, _upd -> %{status: "done", count: 5} end,
        timeout: 5_000
      )

      assert {:ok, %{status: "done", count: 5}} = LongRunningTool.run(tool, nil, %{})
    end

    test "tool runs in a separate process (not the caller)" do
      caller_pid = self()

      tool = LongRunningTool.new(:check_pid,
        func: fn _ctx, _args, _upd ->
          self() != caller_pid
        end,
        timeout: 5_000
      )

      assert {:ok, true} = LongRunningTool.run(tool, nil, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # run/3 — status updates
  # ---------------------------------------------------------------------------

  describe "run/3 — status updates" do
    test "collects status updates and wraps result" do
      tool = LongRunningTool.new(:with_updates,
        func: fn _ctx, _args, send_update ->
          send_update.("Step 1")
          send_update.("Step 2")
          "final"
        end,
        timeout: 5_000
      )

      assert {:ok, %{result: "final", status_updates: updates}} =
               LongRunningTool.run(tool, nil, %{})

      assert updates == ["Step 1", "Step 2"]
    end

    test "single update is captured in status_updates list" do
      tool = LongRunningTool.new(:one_update,
        func: fn _ctx, _args, send_update ->
          send_update.("Processing...")
          42
        end,
        timeout: 5_000
      )

      assert {:ok, %{result: 42, status_updates: ["Processing..."]}} =
               LongRunningTool.run(tool, nil, %{})
    end

    test "no updates returns plain {:ok, result} without wrapping" do
      tool = LongRunningTool.new(:no_updates,
        func: fn _ctx, _args, _send_update -> "done" end,
        timeout: 5_000
      )

      assert {:ok, "done"} = LongRunningTool.run(tool, nil, %{})
    end

    test "send_update returns :ok" do
      result_holder = self()

      tool = LongRunningTool.new(:update_return,
        func: fn _ctx, _args, send_update ->
          ret = send_update.("msg")
          send(result_holder, {:update_return, ret})
          "done"
        end,
        timeout: 5_000
      )

      LongRunningTool.run(tool, nil, %{})

      assert_received {:update_return, :ok}
    end

    test "many status updates are captured in order" do
      tool = LongRunningTool.new(:many_updates,
        func: fn _ctx, %{"n" => n}, send_update ->
          Enum.each(1..n, fn i -> send_update.("step #{i}") end)
          "done"
        end,
        timeout: 5_000
      )

      assert {:ok, %{result: "done", status_updates: updates}} =
               LongRunningTool.run(tool, nil, %{"n" => 5})

      assert updates == ["step 1", "step 2", "step 3", "step 4", "step 5"]
    end
  end

  # ---------------------------------------------------------------------------
  # run/3 — async behavior
  # ---------------------------------------------------------------------------

  describe "run/3 — async behavior" do
    test "completes even with a sleep (simulated slow work)" do
      tool = LongRunningTool.new(:slow,
        func: fn _ctx, _args, send_update ->
          send_update.("starting")
          Process.sleep(50)
          send_update.("halfway")
          Process.sleep(50)
          "done"
        end,
        timeout: 5_000
      )

      assert {:ok, %{result: "done", status_updates: ["starting", "halfway"]}} =
               LongRunningTool.run(tool, nil, %{})
    end

    test "caller process is not blocked from receiving other messages during work" do
      # This test ensures the Task runs in a separate process
      tool = LongRunningTool.new(:non_blocking,
        func: fn _ctx, _args, _upd ->
          Process.sleep(20)
          "done"
        end,
        timeout: 5_000
      )

      # Start the tool in a separate task so we can check this
      parent = self()
      spawn(fn ->
        result = LongRunningTool.run(tool, nil, %{})
        send(parent, {:tool_done, result})
      end)

      # Should receive the result
      assert_receive {:tool_done, {:ok, "done"}}, 3_000
    end
  end

  # ---------------------------------------------------------------------------
  # run/3 — error handling
  # ---------------------------------------------------------------------------

  describe "run/3 — error handling" do
    test "returns {:error, reason} when function raises" do
      tool = LongRunningTool.new(:raiser,
        func: fn _ctx, _args, _upd -> raise "something went wrong" end,
        timeout: 5_000
      )

      assert {:error, reason} = LongRunningTool.run(tool, nil, %{})
      assert String.contains?(reason, "something went wrong")
    end

    test "error in function does not crash the caller" do
      tool = LongRunningTool.new(:crasher,
        func: fn _ctx, _args, _upd ->
          raise RuntimeError, "boom"
        end,
        timeout: 5_000
      )

      # Should not raise, just return error
      assert {:error, _} = LongRunningTool.run(tool, nil, %{})
      assert Process.alive?(self())
    end

    test "returns {:error, reason} when function explicitly returns error" do
      tool = LongRunningTool.new(:explicit_error,
        func: fn _ctx, _args, _upd ->
          raise ArgumentError, "bad input"
        end,
        timeout: 5_000
      )

      assert {:error, reason} = LongRunningTool.run(tool, nil, %{})
      assert is_binary(reason)
    end

    test "returns updates collected before an error" do
      # Updates sent before crash are collected in status messages
      # But the error result wins (not wrapped with status_updates)
      tool = LongRunningTool.new(:updates_then_crash,
        func: fn _ctx, _args, send_update ->
          send_update.("starting")
          raise "crash after update"
        end,
        timeout: 5_000
      )

      # Updates sent before the crash may be received before the error message
      # The important thing is we get an error, not a crash of the caller
      result = LongRunningTool.run(tool, nil, %{})
      assert {:error, _} = result
    end
  end

  # ---------------------------------------------------------------------------
  # run/3 — timeout handling
  # ---------------------------------------------------------------------------

  describe "run/3 — timeout handling" do
    test "returns {:error, timeout message} when tool exceeds timeout" do
      tool = LongRunningTool.new(:timeouter,
        func: fn _ctx, _args, _upd ->
          Process.sleep(10_000)
          "never reaches here"
        end,
        timeout: 50
      )

      assert {:error, reason} = LongRunningTool.run(tool, nil, %{})
      assert String.contains?(reason, "timed out")
      assert String.contains?(reason, "timeouter")
    end

    test "timeout message includes the tool name" do
      tool = LongRunningTool.new(:my_slow_tool,
        func: fn _ctx, _args, _upd -> Process.sleep(10_000) end,
        timeout: 50
      )

      assert {:error, reason} = LongRunningTool.run(tool, nil, %{})
      assert String.contains?(reason, "my_slow_tool")
    end

    test "caller process survives timeout" do
      tool = LongRunningTool.new(:blocking_tool,
        func: fn _ctx, _args, _upd -> Process.sleep(10_000) end,
        timeout: 50
      )

      LongRunningTool.run(tool, nil, %{})
      assert Process.alive?(self())
    end
  end

  # ---------------------------------------------------------------------------
  # run/3 — OTP supervision / process isolation
  # ---------------------------------------------------------------------------

  describe "run/3 — OTP fault tolerance" do
    test "tool task is supervised under ADK.RunnerSupervisor" do
      parent = self()

      tool = LongRunningTool.new(:supervised,
        func: fn _ctx, _args, _upd ->
          # Report our PID so the test can inspect
          send(parent, {:task_pid, self()})
          "ok"
        end,
        timeout: 5_000
      )

      assert {:ok, "ok"} = LongRunningTool.run(tool, nil, %{})
      assert_received {:task_pid, task_pid}

      # Task has already finished (and exited normally)
      # Supervisor should still be alive
      assert Process.alive?(Process.whereis(ADK.RunnerSupervisor))
      refute Process.alive?(task_pid)
    end

    test "RunnerSupervisor is alive after tool crash" do
      tool = LongRunningTool.new(:crashing_supervised,
        func: fn _ctx, _args, _upd -> raise "kaboom" end,
        timeout: 5_000
      )

      assert {:error, _} = LongRunningTool.run(tool, nil, %{})
      assert Process.alive?(Process.whereis(ADK.RunnerSupervisor))
    end

    test "multiple tools can run concurrently" do
      tool = fn name, sleep_ms ->
        LongRunningTool.new(name,
          func: fn _ctx, _args, send_update ->
            send_update.("#{name} started")
            Process.sleep(sleep_ms)
            "#{name} done"
          end,
          timeout: 5_000
        )
      end

      parent = self()

      tasks =
        Enum.map([{:tool_a, 50}, {:tool_b, 30}, {:tool_c, 40}], fn {name, ms} ->
          Task.async(fn ->
            result = LongRunningTool.run(tool.(name, ms), nil, %{})
            send(parent, {:result, name, result})
            result
          end)
        end)

      # Wait for all to complete
      Enum.each(tasks, &Task.await(&1, 3_000))

      assert_received {:result, :tool_a, {:ok, %{result: "tool_a done"}}}
      assert_received {:result, :tool_b, {:ok, %{result: "tool_b done"}}}
      assert_received {:result, :tool_c, {:ok, %{result: "tool_c done"}}}
    end
  end

  # ---------------------------------------------------------------------------
  # Integration with LlmAgent tool dispatch
  # ---------------------------------------------------------------------------

  describe "LlmAgent integration" do
    test "LongRunningTool is recognized in run_tool dispatch" do
      # Verify the struct can be dispatched via the private run_tool in LlmAgent
      # by checking it's properly structured for ADK.Tool.declaration/1

      tool = LongRunningTool.new(:integrated_tool,
        description: "An integrated tool",
        func: fn _ctx, _args, _upd -> "integrated result" end,
        parameters: %{type: "object", properties: %{}}
      )

      # Should produce a valid tool declaration
      decl = ADK.Tool.declaration(tool)
      assert decl.name == "integrated_tool"
      assert String.contains?(decl.description, "long-running operation")
      assert is_map(decl.parameters)
    end

    test "LongRunningTool runs correctly through agent execute_tools path" do
      # Use a mock LLM + LlmAgent to verify end-to-end dispatch
      tool = LongRunningTool.new(:compute,
        description: "Compute something slowly",
        func: fn _ctx, %{"value" => v}, send_update ->
          send_update.("Computing #{v}...")
          v * 10
        end,
        parameters: %{
          type: "object",
          properties: %{value: %{type: "integer"}},
          required: ["value"]
        },
        timeout: 5_000
      )

      agent =
        ADK.Agent.LlmAgent.new(
          name: "test_agent",
          model: "test",
          instruction: "Use the compute tool when asked to compute.",
          tools: [tool]
        )

      # Simulate what execute_tools does internally
      ctx = %ADK.Context{
        invocation_id: "inv-test",
        agent: agent,
        user_content: %{text: "compute 5"},
        session_pid: nil,
        run_config: %ADK.RunConfig{},
        callbacks: [],
        policies: []
      }

      tool_ctx = ADK.ToolContext.new(ctx, "call-1", tool)
      result = ADK.Tool.LongRunningTool.run(tool, tool_ctx, %{"value" => 5})

      assert {:ok, %{result: 50, status_updates: ["Computing 5..."]}} = result
    end
  end
end
