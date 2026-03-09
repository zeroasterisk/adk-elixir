defmodule ADK.Artifact.GCSTest do
  use ExUnit.Case, async: true

  @moduletag :gcs_integration

  # These tests require:
  # - GOOGLE_APPLICATION_CREDENTIALS set
  # - ADK_TEST_GCS_BUCKET set to a real bucket
  # Run with: mix test --only gcs_integration

  alias ADK.Artifact.GCS

  setup do
    bucket = System.get_env("ADK_TEST_GCS_BUCKET")

    if bucket do
      # Use unique prefix to avoid collisions
      session_id = "test-#{System.unique_integer([:positive])}"
      {:ok, bucket: bucket, session_id: session_id}
    else
      :ok
    end
  end

  @tag :gcs_integration
  test "save, load, list, delete round-trip", context do
    if context[:bucket] do
      bucket = context.bucket
      sid = context.session_id
      opts = [bucket: bucket]

      artifact = %{data: "test data", content_type: "text/plain", metadata: %{"key" => "val"}}

      assert {:ok, 0} = GCS.save("app", "user", sid, "test.txt", artifact, opts)
      assert {:ok, loaded} = GCS.load("app", "user", sid, "test.txt", opts)
      assert loaded.data == "test data"

      assert {:ok, files} = GCS.list("app", "user", sid, opts)
      assert "test.txt" in files

      assert :ok = GCS.delete("app", "user", sid, "test.txt", opts)
      assert :not_found = GCS.load("app", "user", sid, "test.txt", opts)
    end
  end
end
