defmodule ADK.Artifact.InMemoryTest do
  @moduledoc """
  Tests for ADK.Artifact.InMemory.

  Parity with Python ADK's `tests/unittests/artifacts/test_artifact_service.py`.
  Covers: load_empty, save_load_delete, list_keys, list_versions (via version
  loading), user: prefix handling, filename-with-slashes, out-of-range version,
  and multi-file listing.
  """
  use ExUnit.Case, async: true

  alias ADK.Artifact.InMemory

  setup do
    {:ok, pid} = InMemory.start_link()
    {:ok, pid: pid}
  end

  # -- Python parity: test_load_empty ------------------------------------------

  test "load returns :not_found when nothing exists", %{pid: pid} do
    assert :not_found =
             InMemory.load("test_app", "test_user", "session_id", "filename", pid: pid)
  end

  # -- Python parity: test_save_load_delete ------------------------------------

  test "save, load, and delete round-trip", %{pid: pid} do
    artifact = %{data: "test_data", content_type: "text/plain", metadata: %{}}

    assert {:ok, 0} =
             InMemory.save("app0", "user0", "123", "file456", artifact, pid: pid)

    assert {:ok, ^artifact} =
             InMemory.load("app0", "user0", "123", "file456", pid: pid)

    # Load a version that doesn't exist
    assert :not_found =
             InMemory.load("app0", "user0", "123", "file456", pid: pid, version: 3)

    # Delete and confirm gone
    assert :ok = InMemory.delete("app0", "user0", "123", "file456", pid: pid)

    assert :not_found =
             InMemory.load("app0", "user0", "123", "file456", pid: pid)
  end

  # -- Python parity: test_list_keys -------------------------------------------

  test "list returns all filenames for a session (5 files)", %{pid: pid} do
    artifact = %{data: "test_data", content_type: "text/plain", metadata: %{}}
    filenames = for i <- 0..4, do: "filename#{i}"

    for f <- filenames do
      {:ok, _} = InMemory.save("app0", "user0", "123", f, artifact, pid: pid)
    end

    assert {:ok, ^filenames} = InMemory.list("app0", "user0", "123", pid: pid)
  end

  # -- Python parity: test_list_versions (via versioned loading) ---------------

  test "multiple versions are saved incrementally and loadable", %{pid: pid} do
    versions =
      for i <- 0..3 do
        %{data: <<i::16>>, content_type: "text/plain", metadata: %{}}
      end

    for {v, i} <- Enum.with_index(versions) do
      assert {:ok, ^i} =
               InMemory.save("app0", "user0", "123", "with/slash/filename", v, pid: pid)
    end

    # Each version is individually loadable
    for {v, i} <- Enum.with_index(versions) do
      assert {:ok, ^v} =
               InMemory.load("app0", "user0", "123", "with/slash/filename",
                 pid: pid,
                 version: i
               )
    end

    # Latest is the last one saved
    last = List.last(versions)

    assert {:ok, ^last} =
             InMemory.load("app0", "user0", "123", "with/slash/filename", pid: pid)
  end

  # -- Python parity: test_list_keys_preserves_user_prefix ---------------------

  test "list preserves user: prefix in returned filenames", %{pid: pid} do
    artifact = %{data: "test_data", content_type: "text/plain", metadata: %{}}

    # User-scoped (cross-session) artifacts
    {:ok, _} =
      InMemory.save("app0", "user0", "123", "user:document.pdf", artifact, pid: pid)

    {:ok, _} =
      InMemory.save("app0", "user0", "123", "user:image.png", artifact, pid: pid)

    # Session-scoped artifact
    {:ok, _} =
      InMemory.save("app0", "user0", "123", "session_file.txt", artifact, pid: pid)

    {:ok, keys} = InMemory.list("app0", "user0", "123", pid: pid)
    expected = Enum.sort(["user:document.pdf", "user:image.png", "session_file.txt"])
    assert Enum.sort(keys) == expected
  end

  # -- Python parity: test_get_artifact_version_out_of_index -------------------

  test "load with out-of-range version returns :not_found", %{pid: pid} do
    artifact = %{data: "test_data", content_type: "text/plain", metadata: %{}}
    {:ok, 0} = InMemory.save("app0", "user0", "123", "filename", artifact, pid: pid)

    assert :not_found =
             InMemory.load("app0", "user0", "123", "filename", pid: pid, version: 3)
  end

  # -- Python parity: test_save_load_delete (user: prefix variant) -------------

  test "save and load with user: prefix filename", %{pid: pid} do
    artifact = %{data: "user-scoped", content_type: "application/pdf", metadata: %{}}

    assert {:ok, 0} =
             InMemory.save("app0", "user0", "123", "user:report.pdf", artifact, pid: pid)

    assert {:ok, ^artifact} =
             InMemory.load("app0", "user0", "123", "user:report.pdf", pid: pid)

    # Second version
    artifact2 = %{data: "v2", content_type: "application/pdf", metadata: %{}}

    assert {:ok, 1} =
             InMemory.save("app0", "user0", "123", "user:report.pdf", artifact2, pid: pid)

    assert {:ok, ^artifact2} =
             InMemory.load("app0", "user0", "123", "user:report.pdf", pid: pid)

    assert {:ok, ^artifact} =
             InMemory.load("app0", "user0", "123", "user:report.pdf", pid: pid, version: 0)
  end

  # -- Python parity: filenames with slashes -----------------------------------

  test "filenames with slashes work correctly", %{pid: pid} do
    artifact = %{data: "nested", content_type: "text/plain", metadata: %{}}

    assert {:ok, 0} =
             InMemory.save("app", "u", "s", "path/to/file.txt", artifact, pid: pid)

    assert {:ok, ^artifact} =
             InMemory.load("app", "u", "s", "path/to/file.txt", pid: pid)

    {:ok, keys} = InMemory.list("app", "u", "s", pid: pid)
    assert keys == ["path/to/file.txt"]
  end

  # -- Isolation: different sessions don't leak --------------------------------

  test "artifacts are isolated between sessions", %{pid: pid} do
    a1 = %{data: "session1", content_type: "text/plain", metadata: %{}}
    a2 = %{data: "session2", content_type: "text/plain", metadata: %{}}

    {:ok, _} = InMemory.save("app", "u", "s1", "f.txt", a1, pid: pid)
    {:ok, _} = InMemory.save("app", "u", "s2", "f.txt", a2, pid: pid)

    assert {:ok, ^a1} = InMemory.load("app", "u", "s1", "f.txt", pid: pid)
    assert {:ok, ^a2} = InMemory.load("app", "u", "s2", "f.txt", pid: pid)

    {:ok, keys1} = InMemory.list("app", "u", "s1", pid: pid)
    {:ok, keys2} = InMemory.list("app", "u", "s2", pid: pid)
    assert keys1 == ["f.txt"]
    assert keys2 == ["f.txt"]
  end

  # -- Isolation: different apps don't leak ------------------------------------

  test "artifacts are isolated between apps", %{pid: pid} do
    a = %{data: "data", content_type: "text/plain", metadata: %{}}
    {:ok, _} = InMemory.save("app1", "u", "s", "f.txt", a, pid: pid)

    assert :not_found = InMemory.load("app2", "u", "s", "f.txt", pid: pid)
    assert {:ok, []} = InMemory.list("app2", "u", "s", pid: pid)
  end

  # -- Delete is idempotent ----------------------------------------------------

  test "deleting a non-existent artifact returns :ok", %{pid: pid} do
    assert :ok = InMemory.delete("app", "u", "s", "nope", pid: pid)
  end

  # -- Binary data round-trip --------------------------------------------------

  test "binary data round-trips correctly", %{pid: pid} do
    binary = :crypto.strong_rand_bytes(256)
    artifact = %{data: binary, content_type: "application/octet-stream", metadata: %{}}

    {:ok, 0} = InMemory.save("app", "u", "s", "bin.dat", artifact, pid: pid)
    assert {:ok, ^artifact} = InMemory.load("app", "u", "s", "bin.dat", pid: pid)
  end
end
