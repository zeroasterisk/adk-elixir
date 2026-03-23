defmodule ADK.LLM.Gateway.ConfigTest do
  use ExUnit.Case, async: true

  alias ADK.LLM.Gateway.{Auth, Config}

  defp valid_backend do
    %{
      id: :test_backend,
      backend: ADK.LLM.Mock,
      model: "test-model",
      auth: %Auth{type: :api_key, source: {:static, "key"}},
      priority: 1
    }
  end

  test "valid config passes validation" do
    config = %Config{backends: [valid_backend()]}
    assert %Config{} = Config.validate!(config)
  end

  test "missing id raises" do
    backend = Map.delete(valid_backend(), :id)
    config = %Config{backends: [backend]}
    assert_raise ArgumentError, ~r/missing required key: id/, fn -> Config.validate!(config) end
  end

  test "duplicate ids raise" do
    b = valid_backend()
    config = %Config{backends: [b, b]}
    assert_raise ArgumentError, ~r/duplicate/, fn -> Config.validate!(config) end
  end

  test "missing auth raises" do
    backend = Map.delete(valid_backend(), :auth)
    config = %Config{backends: [backend]}
    assert_raise ArgumentError, ~r/missing required key: auth/, fn -> Config.validate!(config) end
  end

  test "invalid backend module raises" do
    backend = %{valid_backend() | backend: NonExistentModule12345}
    config = %Config{backends: [backend]}
    assert_raise ArgumentError, ~r/not available/, fn -> Config.validate!(config) end
  end

  test "from_keyword parses correctly" do
    kw = [
      backends: [
        %{id: :gemini, backend: ADK.LLM.Mock, model: "gemini-flash", auth: %Auth{type: :api_key, source: {:static, "k"}}}
      ]
    ]
    config = Config.from_keyword(kw)
    assert length(config.backends) == 1
    assert hd(config.backends).id == :gemini
    assert hd(config.backends).priority == 1
  end

  test "empty backends raises" do
    config = %Config{backends: []}
    assert_raise ArgumentError, ~r/at least one backend/, fn -> Config.validate!(config) end
  end
end
