defmodule ADK.Tool.BashToolTest do
  use ExUnit.Case, async: true

  alias ADK.Tool.BashTool

  describe "new/1" do
    test "creates a function tool with default options" do
      tool = BashTool.new()
      assert tool.name == "execute_bash"
      assert String.contains?(tool.description, "Allowed: any command")
      assert %{type: "object", properties: %{command: _}} = tool.parameters
    end

    test "creates a tool with allowed prefixes" do
      tool = BashTool.new(allowed_prefixes: ["ls", "cat"])
      assert String.contains?(tool.description, "Allowed: commands matching prefixes: ls, cat")
    end
  end

  describe "execution validation" do
    setup do
      # To test validation without blocking on IO.gets or ADK.Tool.Approval,
      # we can only easily test rejected prefixes right now.
      # Testing actual execution would require mocking the confirmation or running Approval.
      :ok
    end

    test "rejects empty commands" do
      tool = BashTool.new()
      assert {:error, "Command is required."} = ADK.Tool.FunctionTool.run(tool, %ADK.ToolContext{}, %{"command" => ""})
      assert {:error, "Command is required."} = ADK.Tool.FunctionTool.run(tool, %ADK.ToolContext{}, %{"command" => "   "})
    end

    test "rejects commands not matching prefixes" do
      tool = BashTool.new(allowed_prefixes: ["ls"])
      assert {:error, "Command blocked. Permitted prefixes are: ls"} =
               ADK.Tool.FunctionTool.run(tool, %ADK.ToolContext{}, %{"command" => "rm -rf /"})
    end
  end

  describe "execution with Approval server" do
    setup do
      start_supervised!({ADK.Tool.Approval, name: ADK.Tool.Approval})
      :ok
    end

    test "executes command when approved" do
      tool = BashTool.new(workspace: System.tmp_dir!())
      
      # Run in a background process since it blocks waiting for approval
      task = Task.async(fn -> 
        ADK.Tool.FunctionTool.run(tool, %ADK.ToolContext{}, %{"command" => "echo hello"})
      end)
      
      # Wait a tiny bit for the request to register
      Process.sleep(10)
      
      # Approve it
      [req] = ADK.Tool.Approval.list_pending()
      ADK.Tool.Approval.approve(ADK.Tool.Approval, req.id)
      
      # Verify result
      assert {:ok, %{stdout: "hello\n", returncode: 0}} = Task.await(task)
    end
    
    test "returns error when denied" do
      tool = BashTool.new(workspace: System.tmp_dir!())
      
      task = Task.async(fn -> 
        ADK.Tool.FunctionTool.run(tool, %ADK.ToolContext{}, %{"command" => "echo bad"})
      end)
      
      Process.sleep(10)
      [req] = ADK.Tool.Approval.list_pending()
      ADK.Tool.Approval.deny(ADK.Tool.Approval, req.id, "not allowed")
      
      assert {:error, "This tool call is rejected. Reason: not allowed"} = Task.await(task)
    end
  end
end
