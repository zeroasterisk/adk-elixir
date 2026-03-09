defmodule ADK.Artifact.InMemoryTest do
  use ExUnit.Case, async: true

  alias ADK.Artifact.InMemory

  setup do
    {:ok, pid} = InMemory.start_link()
    {:ok, pid: pid}
  end

  test "save and load artifact", %{pid: pid} do
    artifact = %{data: "hello", content_type: "text/plain", metadata: %{}}
    assert {:ok, 0} = InMemory.save("app", "user", "sess", "file.txt", artifact, pid: pid)
    assert {:ok, ^artifact} = InMemory.load("app", "user", "sess", "file.txt", pid: pid)
  end

  test "versioning", %{pid: pid} do
    a1 = %{data: "v0", content_type: "text/plain", metadata: %{}}
    a2 = %{data: "v1", content_type: "text/plain", metadata: %{}}

    assert {:ok, 0} = InMemory.save("app", "u", "s", "f", a1, pid: pid)
    assert {:ok, 1} = InMemory.save("app", "u", "s", "f", a2, pid: pid)

    # Latest
    assert {:ok, ^a2} = InMemory.load("app", "u", "s", "f", pid: pid)
    # Specific version
    assert {:ok, ^a1} = InMemory.load("app", "u", "s", "f", pid: pid, version: 0)
    assert {:ok, ^a2} = InMemory.load("app", "u", "s", "f", pid: pid, version: 1)
  end

  test "list artifacts", %{pid: pid} do
    a = %{data: "", content_type: "text/plain", metadata: %{}}
    InMemory.save("app", "u", "s", "a.txt", a, pid: pid)
    InMemory.save("app", "u", "s", "b.txt", a, pid: pid)
    InMemory.save("app", "u", "other", "c.txt", a, pid: pid)

    assert {:ok, ["a.txt", "b.txt"]} = InMemory.list("app", "u", "s", pid: pid)
  end

  test "delete artifact", %{pid: pid} do
    a = %{data: "x", content_type: "text/plain", metadata: %{}}
    InMemory.save("app", "u", "s", "f", a, pid: pid)
    assert :ok = InMemory.delete("app", "u", "s", "f", pid: pid)
    assert :not_found = InMemory.load("app", "u", "s", "f", pid: pid)
  end

  test "load not found", %{pid: pid} do
    assert :not_found = InMemory.load("app", "u", "s", "nope", pid: pid)
  end
end
