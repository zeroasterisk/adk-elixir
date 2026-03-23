defmodule ADK.Skill.SupervisorTest do
  use ExUnit.Case, async: true

  alias ADK.Skill.Supervisor, as: SkillSupervisor

  describe "start_link/1 and stop/1" do
    test "starts and stops a supervisor" do
      assert {:ok, sup} = SkillSupervisor.start_link([])
      assert Process.alive?(sup)
      assert :ok = SkillSupervisor.stop(sup)
      refute Process.alive?(sup)
    end

    test "stop is safe on already-dead supervisor" do
      assert {:ok, sup} = SkillSupervisor.start_link([])
      Process.unlink(sup)
      Process.exit(sup, :kill)
      Process.sleep(10)
      assert :ok = SkillSupervisor.stop(sup)
    end
  end
end
