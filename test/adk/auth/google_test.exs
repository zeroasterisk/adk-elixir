defmodule ADK.Auth.GoogleTest do
  use ExUnit.Case, async: true

  alias ADK.Auth.Google.DefaultClient

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  @private_key """
  -----BEGIN PRIVATE KEY-----
  MIICeAIBADANBgkqhkiG9w0BAQEFAASCAmIwggJeAgEAAoGBAOoD9xeegWlPJm/+
  NBy60JkpSwhv29zP0HwvVL6ChL7U3Ac1HM3ZGDtGpV9YXavpIoF1TX4Cs7tRra/y
  wMIp8uP1juwApkXl9Z3DA9HzRqwbl4xb8ixVYnTeyZJe5eqpTit/cH3vf5RZbihR
  9v8h5skh5WK9oH0tSD2zP/fAP1UjAgMBAAECgYEAwqp7wI0dT/IEooMO7JtG7THZ
  dfI/Lgc9giCJWVUPggNl6ST4ihA+xQh2hsLmYRw1lQV0ag9rXbaLSmMgkCP/JKUo
  RiIjoQfWVitQDk8Fr2ZpZraBuuwu2FXdHL9mU8RvISV42dDgpc9idDyLlOb7FPqu
  mJS31IcQXUIQyv+mXekCQQD1U45daY8oaY0dSUKX3SUYNIbtvl3KxZ6EVlLpAD4N
  Cy1BklIsQh1NlDldOtIbJQaRIiIyOg6ZTBOUBpB2K61/AkEA9DJtpyxgW/sqzynM
  1+IkK9ZTWRjx5XtZaMeUzwXUh8ZEBdtIHMSJNtEElbPhizJiRSmfp/jXMidROMOs
  2cGyXQJBAOGQvBuDjU9ZDZjZ3VMI0Kyaz10VZeOlJIUFYiI+SM9xcWETCl8LQyor
  mTrxdHHk707Olaac3wNwgaffCUC+FD0CQQCSB4IJQYFSIA4GmpGT2/kTefSXyFIH
  kE70WL2FW5AvrYHKGsqx4VnIvQ/H0i0jR3r6rxx5n1ZY+KgakPFRuwJFAkAXTTPJ
  rZ1yG53gCI49jAHkwD6IkzmsAObnESWIsnbB0QHK5eKlU5mKPTXaJMnwrLtU+D9a
  Fp4VmAZBYqTjpNMQ
  -----END PRIVATE KEY-----
  """

  test "from_service_account_info successfully exchanges token", %{bypass: bypass} do
    key_info = %{
      "type" => "service_account",
      "project_id" => "test-project",
      "private_key" => @private_key,
      "client_email" => "test@test.iam.gserviceaccount.com",
      "token_uri" => "http://localhost:#{bypass.port}/token"
    }

    scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
      assert params["assertion"] != nil

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{
        "access_token" => "mock-access-token",
        "token_type" => "Bearer",
        "expires_in" => 3600
      }))
    end)

    assert {:ok, %{token: "mock-access-token"}} = DefaultClient.from_service_account_info(key_info, scopes)
  end

  test "from_service_account_info handles error response", %{bypass: bypass} do
    key_info = %{
      "type" => "service_account",
      "project_id" => "test-project",
      "private_key" => @private_key,
      "client_email" => "test@test.iam.gserviceaccount.com",
      "token_uri" => "http://localhost:#{bypass.port}/token"
    }

    scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(400, Jason.encode!(%{
        "error" => "invalid_grant",
        "error_description" => "Invalid JWT"
      }))
    end)

    assert {:error, {:token_error, 400, _}} = DefaultClient.from_service_account_info(key_info, scopes)
  end
end
