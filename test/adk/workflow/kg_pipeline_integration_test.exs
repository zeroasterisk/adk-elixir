defmodule ADK.Workflow.KgPipelineIntegrationTest do
  @moduledoc """
  End-to-end integration test proving ADK.Workflow works for a
  Knowledge-Graph-style pipeline: ingest → extract → QA → store.
  """
  use ExUnit.Case, async: false

  alias ADK.Workflow
  alias ADK.Workflow.{Step, Checkpoint.EtsStore}

  @tag :integration

  # ── Helpers ──

  defp make_ctx(extra \\ %{}) do
    %ADK.Context{
      invocation_id: "kg-integration-#{System.unique_integer([:positive])}",
      temp_state: extra
    }
  end

  defp event(author, text, meta \\ %{}) do
    ADK.Event.new(
      author: author,
      content: %{"parts" => [%{"text" => text}]},
      custom_metadata: meta
    )
  end

  # Builds the KG pipeline workflow.
  # `extract_response` controls what the mock extractor returns.
  # `qa_pass_on` controls which attempt (1-indexed) QA passes on.
  defp build_pipeline(opts \\ []) do
    extract_response =
      Keyword.get(
        opts,
        :extract_response,
        ~s|{"entities": ["Elixir", "OTP"], "relationships": [["Elixir", "runs_on", "OTP"]]}|
      )

    qa_pass_on = Keyword.get(opts, :qa_pass_on, 1)
    store_agent = Keyword.get(opts, :store_agent)

    # Shared counter for QA attempts (to support conditional retry)
    qa_counter = :atomics.new(1, [])

    ingest_step =
      Step.new(:ingest, fn ctx ->
        text = ctx.temp_state[:input_text] || "Elixir runs on the OTP platform."
        [event("ingest", text)]
      end)

    extract_step =
      Step.new_with_opts(
        :extract,
        fn _ctx ->
          # Mock LLM extraction — returns canned JSON
          [event("extract", extract_response)]
        end,
        retry_times: 2,
        backoff: 1
      )

    qa_step =
      Step.new(:qa, fn _ctx ->
        attempt = :atomics.add_get(qa_counter, 1, 1)

        if attempt >= qa_pass_on do
          [event("qa", "QA passed", %{route: "pass"})]
        else
          [event("qa", "QA failed: low quality", %{route: "fail"})]
        end
      end)

    store_step =
      store_agent ||
        Step.new(:store, fn _ctx ->
          [event("store", "Stored 2 entities, 1 relationship")]
        end)

    # Graph:
    #   START → ingest → extract → qa →(pass)→ store → END
    #                                  →(fail)→ extract (retry)
    #
    # Because the executor is DAG-based (no cycles allowed), we model
    # the QA-fail retry via Step's built-in retry_times on extract,
    # and QA conditional routing: pass→store, fail→extract_retry→qa_retry→store
    #
    # Simpler: use a linear pipeline and let QA's "fail" trigger a retry
    # of the whole extract+QA via retry_times on a combined step.
    #
    # Actually, DAGs can't have cycles. So we model retry differently:
    # We use a single "extract_and_qa" step with retry that internally
    # does extract+QA, or we use separate nodes with conditional edges
    # pointing to a second extract node.
    #
    # Let's use the cleanest approach: separate extract and QA nodes,
    # and for the retry case, QA failure causes a workflow-level error
    # that triggers Step retry on extract_and_qa.

    # Approach: combine extract+QA into one step with retry for the retry test,
    # but keep them separate for the happy path test.

    # Actually, let's keep it simple and use two different graph shapes:
    # For happy path: ingest → extract → qa → store (linear, qa always passes)
    # For retry: ingest → extract_qa → store (extract_qa retries internally)

    # But the task asks for conditional routing. Let's do:
    # ingest → extract → qa --pass--> store → END
    #                       --fail--> re_extract → re_qa → store → END
    # This is a DAG (no cycles).

    re_extract_step =
      Step.new(:re_extract, fn _ctx ->
        [event("re_extract", extract_response)]
      end)

    re_qa_step =
      Step.new(:re_qa, fn _ctx ->
        [event("re_qa", "QA passed on retry")]
      end)

    # Separate store nodes to avoid join-node blocking
    store_retry_step =
      Step.new(:store_retry, fn _ctx ->
        [event("store_retry", "Stored 2 entities, 1 relationship (after retry)")]
      end)

    nodes = %{
      ingest: ingest_step,
      extract: extract_step,
      qa: qa_step,
      store: store_step,
      re_extract: re_extract_step,
      re_qa: re_qa_step,
      store_retry: store_retry_step
    }

    # Graph: two distinct paths to END (no join on store)
    #   START → ingest → extract → qa --pass--> store → END
    #                                  --fail--> re_extract → re_qa → store_retry → END
    edges = [
      {:START, :ingest, :extract, :qa},
      {:qa, %{"pass" => :store, "fail" => :re_extract}},
      {:store, :END},
      {:re_extract, :re_qa, :store_retry, :END}
    ]

    {Workflow.new(name: "kg_pipeline", edges: edges, nodes: nodes), qa_counter}
  end

  # ── Tests ──

  @tag :integration
  test "full pipeline: ingest → extract → QA(pass) → store" do
    {workflow, _counter} = build_pipeline(qa_pass_on: 1)

    assert :ok = Workflow.validate(workflow)

    ctx = make_ctx(%{input_text: "Elixir is a functional language on BEAM."})
    events = Workflow.run(workflow, ctx)

    authors = Enum.map(events, & &1.author)
    texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)

    # Pipeline executed in order
    assert "ingest" in authors
    assert "extract" in authors
    assert "qa" in authors
    assert "store" in authors

    # QA passed, so re_extract/re_qa should NOT appear
    refute "re_extract" in authors
    refute "re_qa" in authors

    # Store output present
    assert Enum.any?(texts, &String.contains?(&1, "Stored"))
  end

  @tag :integration
  test "pipeline with QA failure triggers retry path" do
    # QA passes on attempt 2, so first attempt routes to re_extract
    {workflow, _counter} = build_pipeline(qa_pass_on: 2)

    assert :ok = Workflow.validate(workflow)

    ctx = make_ctx()
    events = Workflow.run(workflow, ctx)

    authors = Enum.map(events, & &1.author)
    texts = Enum.map(events, &ADK.Event.text/1) |> Enum.reject(&is_nil/1)

    # First QA failed → routed to re_extract → re_qa → store_retry
    assert "ingest" in authors
    assert "extract" in authors
    assert "qa" in authors
    assert "re_extract" in authors
    assert "re_qa" in authors
    assert "store_retry" in authors

    # QA failure message present
    assert Enum.any?(texts, &String.contains?(&1, "QA failed"))
    # Store still completed (via retry path)
    assert Enum.any?(texts, &String.contains?(&1, "Stored"))
  end

  @tag :integration
  test "checkpoint and resume mid-pipeline" do
    EtsStore.init()

    workflow_id = "checkpoint-test-#{System.unique_integer([:positive])}"

    # Manually checkpoint ingest and extract as completed
    EtsStore.save(workflow_id, :ingest, :completed, "Elixir runs on OTP.")
    EtsStore.save(workflow_id, :extract, :completed, ~s|{"entities": ["Elixir", "OTP"]}|)

    # Verify checkpoints saved
    completed = EtsStore.completed_nodes(workflow_id)
    assert :ingest in completed
    assert :extract in completed

    # Build pipeline where QA passes immediately
    {workflow, _counter} = build_pipeline(qa_pass_on: 1)

    # Resume from checkpoint — ingest and extract should be skipped
    ctx = make_ctx()
    events = Workflow.run(workflow, ctx, resume_id: workflow_id)

    authors = Enum.map(events, & &1.author)

    # ingest and extract were already completed, so they should be skipped
    # qa, store should execute
    assert "qa" in authors
    assert "store" in authors

    # Verify final checkpoints include all nodes
    all_completed = EtsStore.completed_nodes(workflow_id)
    assert :ingest in all_completed
    assert :extract in all_completed
    assert :qa in all_completed
    assert :store in all_completed
  end
end
