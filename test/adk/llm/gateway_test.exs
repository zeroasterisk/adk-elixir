defmodule ADK.LLM.GatewayTest do
  use ExUnit.Case, async: false

  alias ADK.LLM.Gateway
  alias ADK.LLM.Gateway.{Auth, Config}

  defmodule MockBackend do
    @behaviour ADK.LLM

    @impl true
    def generate(_model, _request) do
      case Process.get(:mock_gateway_response) do
        nil -> {:ok, %{content: %{role: :model, parts: [%{text: "hello"}]}, usage_metadata: nil}}
        resp -> resp
      end
    end
  end

  defmodule FailBackend do
    @behaviour ADK.LLM

    @impl true
    def generate(_model, _request) do
      {:error, :rate_limited}
    end
  end

  defp gateway_config(backends) do
    Config.from_keyword(backends: backends)
  end

  defp default_backend(overrides \\ %{}) do
    Map.merge(
      %{
        id: :mock1,
        backend: MockBackend,
        model: "test-model",
        auth: %Auth{type: :api_key, source: {:static, "key1"}, resolved_token: "key1"},
        priority: 1
      },
      overrides
    )
  end

  setup do
    # Clean up any existing gateway
    pid = Process.whereis(Gateway)

    if pid && Process.alive?(pid) do
      try do
        Supervisor.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end

      :timer.sleep(50)
    end

    # Clean up stats ETS if exists
    try do
      :ets.delete(:adk_llm_gateway_stats)
    catch
      :error, :badarg -> :ok
    end

    # Clean up persistent_term
    try do
      :persistent_term.erase({Gateway, :config})
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  test "Gateway implements ADK.LLM behaviour" do
    behaviours =
      Gateway.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert ADK.LLM in behaviours
  end

  test "generate/2 routes through key pool to backend" do
    config = gateway_config([default_backend()])
    {:ok, _} = Gateway.start_link(config)

    assert {:ok, %{content: %{parts: [%{text: "hello"}]}}} =
             Gateway.generate("test-model", %{messages: []})
  end

  test "multi-key failover on rate limit" do
    backends = [
      default_backend(%{id: :fail1, backend: FailBackend, priority: 1}),
      default_backend(%{id: :mock2, backend: MockBackend, priority: 2})
    ]

    config = gateway_config(backends)
    {:ok, _} = Gateway.start_link(config)

    assert {:ok, %{content: _}} = Gateway.generate("auto", %{messages: []})
  end

  test "all backends failed returns error" do
    backends = [
      default_backend(%{id: :fail1, backend: FailBackend, priority: 1}),
      default_backend(%{id: :fail2, backend: FailBackend, priority: 2})
    ]

    config = gateway_config(backends)
    {:ok, _} = Gateway.start_link(config)

    assert {:error, :all_backends_failed} = Gateway.generate("auto", %{messages: []})
  end

  test "stats are recorded" do
    config = gateway_config([default_backend()])
    {:ok, _} = Gateway.start_link(config)

    Gateway.generate("test-model", %{messages: []})
    stats = Gateway.stats()
    assert Map.has_key?(stats, :mock1)
    assert stats[:mock1].total_requests == 1
  end

  test "health_check reports per-backend status" do
    config = gateway_config([default_backend()])
    {:ok, _} = Gateway.start_link(config)

    health = Gateway.health_check()
    assert Map.has_key?(health, :mock1)
    assert health[:mock1].status == :ok
  end
end
