defmodule ADK.LLM.Gateway.AuthTest do
  use ExUnit.Case, async: true

  alias ADK.LLM.Gateway.Auth

  describe "resolve/1" do
    test "resolves {:env, var} when var exists" do
      System.put_env("TEST_AUTH_KEY", "my-secret")
      auth = %Auth{type: :api_key, source: {:env, "TEST_AUTH_KEY"}}
      assert {:ok, %Auth{resolved_token: "my-secret"}} = Auth.resolve(auth)
      System.delete_env("TEST_AUTH_KEY")
    end

    test "returns error for {:env, var} when var is missing" do
      auth = %Auth{type: :api_key, source: {:env, "NONEXISTENT_VAR_12345"}}
      assert {:error, msg} = Auth.resolve(auth)
      assert msg =~ "not set"
    end

    test "resolves {:static, value}" do
      auth = %Auth{type: :bearer, source: {:static, "static-token"}}
      assert {:ok, %Auth{resolved_token: "static-token"}} = Auth.resolve(auth)
    end

    test "resolves {:file, path} when file exists" do
      path = Path.join(System.tmp_dir!(), "auth_test_#{System.unique_integer([:positive])}")
      File.write!(path, "file-token\n")
      auth = %Auth{type: :service_account, source: {:file, path}}
      assert {:ok, %Auth{resolved_token: "file-token"}} = Auth.resolve(auth)
      File.rm!(path)
    end

    test "returns error for {:file, path} when missing" do
      auth = %Auth{type: :service_account, source: {:file, "/nonexistent/path"}}
      assert {:error, msg} = Auth.resolve(auth)
      assert msg =~ "cannot read file"
    end

    test "returns error for {:adc, []}" do
      auth = %Auth{type: :adc, source: {:adc, []}}
      assert {:error, :not_implemented} = Auth.resolve(auth)
    end
  end

  describe "resolved?/1" do
    test "returns true with valid token" do
      assert Auth.resolved?(%Auth{resolved_token: "token"})
    end

    test "returns false with nil token" do
      refute Auth.resolved?(%Auth{resolved_token: nil})
    end

    test "returns false with expired token" do
      expired = DateTime.add(DateTime.utc_now(), -3600, :second)
      refute Auth.resolved?(%Auth{resolved_token: "token", expires_at: expired})
    end

    test "returns true with future expiration" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert Auth.resolved?(%Auth{resolved_token: "token", expires_at: future})
    end
  end

  describe "to_headers/1" do
    test "returns api_key header" do
      auth = %Auth{type: :api_key, resolved_token: "key123"}
      assert [{"x-goog-api-key", "key123"}] = Auth.to_headers(auth)
    end

    test "returns bearer header for other types" do
      auth = %Auth{type: :bearer, resolved_token: "bearer123"}
      assert [{"Authorization", "Bearer bearer123"}] = Auth.to_headers(auth)
    end

    test "returns empty list when no token" do
      assert [] = Auth.to_headers(%Auth{type: :api_key, resolved_token: nil})
    end
  end
end
