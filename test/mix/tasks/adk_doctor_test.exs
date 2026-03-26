defmodule Mix.Tasks.Adk.DoctorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  describe "run/1 human output" do
    test "produces output with expected sections" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Adk.Doctor.run([])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "ADK Doctor"
      assert output =~ "=========="
      assert output =~ "Environment"
      assert output =~ "API Keys"
      assert output =~ "Dependencies"
      assert output =~ "Summary:"
    end

    test "shows Elixir version check" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Adk.Doctor.run([])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "Elixir #{System.version()}"
    end

    test "shows OTP version check" do
      otp = :erlang.system_info(:otp_release) |> List.to_string()

      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Adk.Doctor.run([])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert output =~ "OTP #{otp}"
    end
  end

  describe "run/1 --json output" do
    test "produces valid JSON" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Adk.Doctor.run(["--json"])
          rescue
            Mix.Error -> :ok
          end
        end)

      assert {:ok, data} = Jason.decode(output)
      assert is_list(data["checks"])
      assert is_map(data["summary"])
      assert is_boolean(data["ok"])
    end

    test "JSON includes expected check groups" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Adk.Doctor.run(["--json"])
          rescue
            Mix.Error -> :ok
          end
        end)

      {:ok, data} = Jason.decode(output)
      groups = data["checks"] |> Enum.map(& &1["group"]) |> Enum.uniq() |> Enum.sort()
      assert "api_keys" in groups
      assert "environment" in groups
      assert "dependencies" in groups
    end

    test "JSON summary counts are non-negative integers" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Adk.Doctor.run(["--json"])
          rescue
            Mix.Error -> :ok
          end
        end)

      {:ok, data} = Jason.decode(output)
      summary = data["summary"]
      assert is_integer(summary["passed"]) and summary["passed"] >= 0
      assert is_integer(summary["failed"]) and summary["failed"] >= 0
      assert is_integer(summary["warnings"]) and summary["warnings"] >= 0
      assert is_integer(summary["optional_skipped"]) and summary["optional_skipped"] >= 0
    end
  end

  describe "run_checks/1" do
    test "returns a list of check results" do
      results = Mix.Tasks.Adk.Doctor.run_checks()
      assert is_list(results)
      assert length(results) == 8

      Enum.each(results, fn check ->
        assert Map.has_key?(check, :group)
        assert Map.has_key?(check, :name)
        assert Map.has_key?(check, :status)
        assert Map.has_key?(check, :message)
        assert check.status in [:pass, :fail, :warn, :optional]
      end)
    end

    test "elixir version passes on current system" do
      [elixir_check | _] = Mix.Tasks.Adk.Doctor.run_checks()
      assert elixir_check.name == "Elixir version"
      # Current Elixir should be >= 1.15
      assert elixir_check.status in [:pass, :warn]
    end

    test "OTP version passes on current system" do
      results = Mix.Tasks.Adk.Doctor.run_checks()
      otp_check = Enum.find(results, &(&1.name == "OTP version"))
      assert otp_check.status in [:pass, :warn]
    end

    test "GEMINI_API_KEY check reflects env" do
      results = Mix.Tasks.Adk.Doctor.run_checks()
      gemini_check = Enum.find(results, &(&1.name == "GEMINI_API_KEY"))

      case System.get_env("GEMINI_API_KEY") do
        nil -> assert gemini_check.status == :fail
        _val -> assert gemini_check.status == :pass
      end
    end

    test "GOOGLE_API_KEY is optional" do
      results = Mix.Tasks.Adk.Doctor.run_checks()
      google_check = Enum.find(results, &(&1.name == "GOOGLE_API_KEY"))
      assert google_check.status in [:pass, :optional]
    end

    test "does not leak API key values in messages" do
      results = Mix.Tasks.Adk.Doctor.run_checks()

      Enum.each(results, fn check ->
        if check.group == :api_keys and check.status == :pass do
          # Should only say "is set", never show the actual value
          refute check.message =~ ~r/[a-zA-Z0-9]{20,}/
          assert check.message =~ "is set"
        end
      end)
    end
  end

  describe "status icons" do
    test "human output contains expected icons" do
      output =
        capture_io(fn ->
          try do
            Mix.Tasks.Adk.Doctor.run([])
          rescue
            Mix.Error -> :ok
          end
        end)

      # Should contain at least one status icon
      assert output =~ "✓" or output =~ "✗" or output =~ "○" or output =~ "!"
    end
  end
end
