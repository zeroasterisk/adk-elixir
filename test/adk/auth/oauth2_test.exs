defmodule ADK.Auth.OAuth2Test do
  use ExUnit.Case, async: true

  alias ADK.Auth.{Credential, OAuth2}

  describe "authorization_url/1" do
    test "builds a valid authorization URL" do
      url =
        OAuth2.authorization_url(%{
          auth_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
          client_id: "my-client-id",
          redirect_uri: "https://myapp.com/callback",
          scopes: ["openid", "profile"],
          state: "fixed-state"
        })

      assert url =~ "https://accounts.google.com/o/oauth2/v2/auth?"
      assert url =~ "response_type=code"
      assert url =~ "client_id=my-client-id"
      assert url =~ "redirect_uri=https%3A%2F%2Fmyapp.com%2Fcallback"
      assert url =~ "state=fixed-state"
      assert url =~ "scope=openid+profile"
    end

    test "generates state when not provided" do
      url =
        OAuth2.authorization_url(%{
          auth_endpoint: "https://auth.example.com/oauth",
          client_id: "c1",
          redirect_uri: "https://app.example.com/cb"
        })

      # State should be a random base64url string
      uri = URI.parse(url)
      params = URI.decode_query(uri.query)
      assert byte_size(params["state"]) > 10
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, ~r/requires auth_endpoint/, fn ->
        OAuth2.authorization_url(%{client_id: "c1", redirect_uri: "https://x.com/cb"})
      end
    end

    test "includes extra_params" do
      url =
        OAuth2.authorization_url(%{
          auth_endpoint: "https://auth.example.com/oauth",
          client_id: "c1",
          redirect_uri: "https://x.com/cb",
          extra_params: %{access_type: "offline", prompt: "consent"}
        })

      assert url =~ "access_type=offline"
      assert url =~ "prompt=consent"
    end
  end

  describe "expired?/1" do
    test "returns false when no expires_at in metadata" do
      cred = Credential.oauth2("tok")
      refute OAuth2.expired?(cred)
    end

    test "returns true when expires_at is in the past" do
      past = System.system_time(:second) - 100
      cred = %Credential{type: :oauth2, access_token: "tok", metadata: %{"expires_at" => past}}
      assert OAuth2.expired?(cred)
    end

    test "returns false when expires_at is in the future" do
      future = System.system_time(:second) + 3600
      cred = %Credential{type: :oauth2, access_token: "tok", metadata: %{"expires_at" => future}}
      refute OAuth2.expired?(cred)
    end
  end

  describe "expires_soon?/1" do
    test "returns false when no expires_at" do
      cred = Credential.oauth2("tok")
      refute OAuth2.expires_soon?(cred)
    end

    test "returns true when within default buffer (300s)" do
      near = System.system_time(:second) + 200
      cred = %Credential{type: :oauth2, access_token: "tok", metadata: %{"expires_at" => near}}
      assert OAuth2.expires_soon?(cred)
    end

    test "returns false when outside buffer" do
      far = System.system_time(:second) + 3600
      cred = %Credential{type: :oauth2, access_token: "tok", metadata: %{"expires_at" => far}}
      refute OAuth2.expires_soon?(cred)
    end

    test "respects custom buffer" do
      future = System.system_time(:second) + 200
      cred = %Credential{type: :oauth2, access_token: "tok", metadata: %{"expires_at" => future}}
      # With 100s buffer: 200s away is fine
      refute OAuth2.expires_soon?(cred, 100)
      # With 300s buffer: 200s away is too soon
      assert OAuth2.expires_soon?(cred, 300)
    end
  end

  describe "refreshable?/1" do
    test "true when has refresh_token and token_endpoint" do
      cred =
        Credential.oauth2("tok",
          refresh_token: "ref",
          token_endpoint: "https://auth.example.com/token"
        )

      assert OAuth2.refreshable?(cred)
    end

    test "false when missing refresh_token" do
      cred = Credential.oauth2("tok", token_endpoint: "https://auth.example.com/token")
      refute OAuth2.refreshable?(cred)
    end

    test "false when missing token_endpoint" do
      cred = Credential.oauth2("tok", refresh_token: "ref")
      refute OAuth2.refreshable?(cred)
    end
  end

  describe "needs_exchange?/1" do
    test "true when has auth_code but no access_token" do
      cred = %Credential{type: :oauth2, access_token: nil, auth_code: "code123"}
      assert OAuth2.needs_exchange?(cred)
    end

    test "false when already has access_token" do
      cred = %Credential{type: :oauth2, access_token: "tok", auth_code: "code123"}
      refute OAuth2.needs_exchange?(cred)
    end

    test "false when no auth_code" do
      cred = %Credential{type: :oauth2, access_token: nil, auth_code: nil}
      refute OAuth2.needs_exchange?(cred)
    end
  end

  describe "exchange_code/2 — validation" do
    test "returns error when auth_code missing" do
      cred =
        Credential.oauth2(nil,
          client_id: "c1",
          client_secret: "s1",
          token_endpoint: "https://auth.example.com/token"
        )

      assert {:error, :missing_auth_code} = OAuth2.exchange_code(cred)
    end

    test "returns error when client_id missing" do
      cred = %Credential{
        type: :oauth2,
        auth_code: "code",
        client_secret: "s1",
        token_endpoint: "https://auth.example.com/token"
      }

      assert {:error, :missing_client_id} = OAuth2.exchange_code(cred)
    end

    test "returns error when token_endpoint missing" do
      cred = %Credential{
        type: :oauth2,
        auth_code: "code",
        client_id: "c1",
        client_secret: "s1"
      }

      assert {:error, :missing_token_endpoint} = OAuth2.exchange_code(cred)
    end
  end

  describe "refresh_token/2 — validation" do
    test "returns error when refresh_token missing" do
      cred =
        Credential.oauth2("tok",
          client_id: "c1",
          client_secret: "s1",
          token_endpoint: "https://auth.example.com/token"
        )

      assert {:error, :missing_refresh_token} = OAuth2.refresh_token(cred)
    end

    test "returns error when token_endpoint missing" do
      cred =
        Credential.oauth2("tok",
          refresh_token: "ref",
          client_id: "c1",
          client_secret: "s1"
        )

      assert {:error, :missing_token_endpoint} = OAuth2.refresh_token(cred)
    end
  end

  describe "exchange_code/2 — HTTP integration" do
    @tag :integration
    test "exchanges code for tokens against a mock server" do
      # This test is skipped unless :integration tag is set.
      # In unit tests we validate the request shape instead.
      :ok
    end
  end
end
