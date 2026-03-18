defmodule ADK.LLM.RouterTest do
  use ExUnit.Case, async: true

  alias ADK.LLM.Router

  # ---- helpers ----

  defp start_router(_ctx) do
    name = :"router_test_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Router.start_link(name: name)
    %{router: name}
  end

  defp ok_fn, do: fn -> {:ok, %{content: %{role: :model, parts: [%{text: "hi"}]}, usage_metadata: nil}} end
  defp rate_limited_fn, do: fn -> {:error, :rate_limited} end
  defp server_error_fn, do: fn -> {:error, {:api_error, 500, "boom"}} end
  defp auth_error_fn, do: fn -> {:error, :unauthorized} end

  # ---- state tracking ----

  describe "backend_states/1" do
    setup :start_router

    test "starts empty", %{router: router} do
      assert %{} == Router.backend_states(router)
    end

    test "records rate limit with increasing backoff", %{router: router} do
      Router.record_rate_limited(router, :b1)
      Process.sleep(5)
      states = Router.backend_states(router)
      assert states[:b1].rl_count == 1

      Router.record_rate_limited(router, :b1)
      Process.sleep(5)
      states2 = Router.backend_states(router)
      # backoff should have doubled
      assert states2[:b1].rl_backoff_ms > states[:b1].rl_backoff_ms
    end

    test "clears availability on success", %{router: router} do
      Router.record_rate_limited(router, :b2)
      Process.sleep(5)
      Router.record_success(router, :b2)
      Process.sleep(5)
      assert Router.backend_available?(router, :b2)
    end

    test "marks unavailable during transient penalty", %{router: router} do
      # transient_error sets available_at = now + 10_000
      Router.record_transient_error(router, :b3)
      Process.sleep(5)
      refute Router.backend_available?(router, :b3)
    end

    test "reset clears all state", %{router: router} do
      Router.record_rate_limited(router, :b4)
      Router.reset(router)
      assert %{} == Router.backend_states(router)
    end
  end

  # ---- generate/3 failover ----

  # We test generate/3 by injecting backend modules via application env
  # and overriding :backends opt.  Since we can't call real APIs in tests,
  # we use fakes wired through a process-dictionary dispatch table.

  defmodule FakeBackendA do
    @behaviour ADK.LLM
    @impl true
    def generate(_model, _request) do
      ADK.LLM.RouterTest.dispatch_response(:fake_a)
    end
  end

  defmodule FakeBackendB do
    @behaviour ADK.LLM
    @impl true
    def generate(_model, _request) do
      ADK.LLM.RouterTest.dispatch_response(:fake_b)
    end
  end

  @doc false
  def dispatch_response(key) do
    case Process.get({:fake_response, key}) do
      nil -> {:error, :not_configured}
      fun -> fun.()
    end
  end

  defp set_response(key, fun), do: Process.put({:fake_response, key}, fun)

  # Build a minimal backends config for generate/3 tests
  defp backends_config do
    [
      %{id: :fake_a, backend: FakeBackendA, model: "model-a", priority: 1},
      %{id: :fake_b, backend: FakeBackendB, model: "model-b", priority: 2}
    ]
  end

  # Patch app env, call generate/3 with inline opts, restore
  defp generate_with(opts, request \\ %{messages: []}) do
    # Force backends via opts (bypasses app env)
    full_opts = Keyword.put_new(opts, :backends_override, nil)
    _ = full_opts

    # We call the Router.generate with injected :backends via opts handled below.
    # Since Router.generate picks up configured_backends() from app env,
    # we temporarily set it.
    backends = Keyword.get(opts, :use_backends, backends_config())
    opts_clean = Keyword.drop(opts, [:use_backends])

    Application.put_env(:adk, :llm_router, backends: backends)

    try do
      Router.generate("auto", request, opts_clean)
    after
      Application.delete_env(:adk, :llm_router)
    end
  end

  describe "generate/3 — happy path" do
    setup :start_router

    test "returns result from first available backend", %{router: router} do
      set_response(:fake_a, ok_fn())
      assert {:ok, _} = generate_with([server: router])
    end
  end

  describe "generate/3 — failover" do
    setup :start_router

    test "fails over from rate-limited backend to next", %{router: router} do
      set_response(:fake_a, rate_limited_fn())
      set_response(:fake_b, ok_fn())

      assert {:ok, _} = generate_with([server: router])

      # fake_a should now be backed off
      refute Router.backend_available?(router, :fake_a)
    end

    test "fails over from server error to next backend", %{router: router} do
      set_response(:fake_a, server_error_fn())
      set_response(:fake_b, ok_fn())

      assert {:ok, _} = generate_with([server: router])
    end

    test "returns error when all backends exhausted", %{router: router} do
      set_response(:fake_a, rate_limited_fn())
      set_response(:fake_b, rate_limited_fn())

      assert {:error, :all_backends_failed} = generate_with([server: router])
    end

    test "does not fail over on non-transient auth error", %{router: router} do
      # auth errors (401) return immediately — do not try next backend
      set_response(:fake_a, auth_error_fn())
      set_response(:fake_b, ok_fn())

      assert {:error, :unauthorized} = generate_with([server: router])
    end
  end

  describe "generate/3 — backed-off backend skipped" do
    setup :start_router

    test "skips already-backed-off backend", %{router: router} do
      # Pre-mark fake_a as unavailable
      Router.record_rate_limited(router, :fake_a)
      Process.sleep(5)

      set_response(:fake_b, ok_fn())

      assert {:ok, _} = generate_with([server: router])
    end
  end

  describe "generate/3 — fallback_error config" do
    setup :start_router

    test "respects custom fallback_error option", %{router: router} do
      set_response(:fake_a, rate_limited_fn())
      set_response(:fake_b, rate_limited_fn())

      assert {:error, :my_custom_error} =
               generate_with([server: router, fallback_error: :my_custom_error])
    end
  end

  describe "compute_delay/3 integration" do
    test "delay increases exponentially" do
      d0 = ADK.LLM.Retry.compute_delay(0, 100, 10_000)
      d2 = ADK.LLM.Retry.compute_delay(2, 100, 10_000)
      # On average d2 should be larger; with full jitter we just check range
      assert d0 >= 0 and d0 <= 100
      assert d2 >= 0 and d2 <= 400
    end
  end
end
