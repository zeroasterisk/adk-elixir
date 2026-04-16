defmodule ADK.Memory.Store.VertexAITest do
  use ExUnit.Case, async: false

  alias ADK.Memory.Store.VertexAI
  alias ADK.Memory.Entry

  # -------------------------------------------------------------------------
  # Setup: configure the module to use Req.Test plug for HTTP mocking
  # -------------------------------------------------------------------------

  setup do
    Application.put_env(:adk, :vertex_memory_test_plug, true)
    Application.put_env(:adk, :vertex_project_id, "test-project")
    Application.put_env(:adk, :vertex_location, "us-central1")
    Application.put_env(:adk, :vertex_reasoning_engine_id, "engine-123")
    # Use API key auth so we skip the credential file / metadata logic
    Application.put_env(:adk, :vertex_api_key, "test-api-key")

    on_exit(fn ->
      Application.delete_env(:adk, :vertex_memory_test_plug)
      Application.delete_env(:adk, :vertex_project_id)
      Application.delete_env(:adk, :vertex_location)
      Application.delete_env(:adk, :vertex_reasoning_engine_id)
      Application.delete_env(:adk, :vertex_api_key)
    end)

    :ok
  end

  defp stub(status, body) do
    Req.Test.stub(ADK.Memory.Store.VertexAI, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(body)
    end)
  end

  defp stub_fn(handler) do
    Req.Test.stub(ADK.Memory.Store.VertexAI, handler)
  end

  # -------------------------------------------------------------------------
  # search/4
  # -------------------------------------------------------------------------

  describe "search/4" do
    test "returns entries from similarity search results" do
      stub(200, %{
        "memories" => [
          %{
            "memory" => %{
              "name" =>
                "projects/test-project/locations/us-central1/reasoningEngines/engine-123/memories/mem001",
              "fact" => "User prefers dark mode",
              "scope" => %{"agent_name" => "myapp", "user_id" => "user1"},
              "createTime" => "2025-01-01T00:00:00Z"
            },
            "distance" => 0.12
          },
          %{
            "memory" => %{
              "name" =>
                "projects/test-project/locations/us-central1/reasoningEngines/engine-123/memories/mem002",
              "fact" => "User lives in Berlin",
              "scope" => %{"agent_name" => "myapp", "user_id" => "user1"},
              "createTime" => "2025-01-02T00:00:00Z"
            },
            "distance" => 0.45
          }
        ]
      })

      assert {:ok, entries} = VertexAI.search("myapp", "user1", "dark mode")

      assert length(entries) == 2
      [first | _] = entries
      assert first.content == "User prefers dark mode"
      assert first.id =~ "mem001"
      assert first.metadata["vertex_name"] =~ "mem001"
    end

    test "returns empty list when no memories found" do
      stub(200, %{"memories" => []})

      assert {:ok, []} = VertexAI.search("myapp", "user1", "zzz not found")
    end

    test "returns empty list when response has no memories key" do
      stub(200, %{})

      assert {:ok, []} = VertexAI.search("myapp", "user1", "anything")
    end

    test "returns error on 500 response" do
      stub(500, %{"error" => %{"message" => "Internal error"}})

      assert {:error, {:api_error, 500, _}} = VertexAI.search("myapp", "user1", "query")
    end

    test "returns error on 401 unauthorized" do
      stub(401, %{"error" => %{"message" => "Request had invalid authentication credentials"}})

      assert {:error, {:api_error, 401, _}} = VertexAI.search("myapp", "user1", "query")
    end

    test "sends correct scope in request body" do
      stub_fn(fn conn ->
        {:ok, body_bytes, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body_bytes)

        assert decoded["scope"] == %{"agent_name" => "myapp", "user_id" => "user42"}
        assert decoded["similaritySearchParams"]["searchQuery"] == "coffee preferences"
        assert decoded["similaritySearchParams"]["topK"] == 10

        Req.Test.json(conn, %{"memories" => []})
      end)

      VertexAI.search("myapp", "user42", "coffee preferences")
    end

    test "respects top_k option" do
      stub_fn(fn conn ->
        {:ok, body_bytes, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body_bytes)

        assert decoded["similaritySearchParams"]["topK"] == 5

        Req.Test.json(conn, %{"memories" => []})
      end)

      VertexAI.search("myapp", "user1", "query", top_k: 5)
    end

    test "sends request to correct URL" do
      stub_fn(fn conn ->
        assert conn.request_path =~ "/memories:retrieve"
        Req.Test.json(conn, %{"memories" => []})
      end)

      VertexAI.search("myapp", "user1", "query")
    end

    test "maps createTime to entry timestamp" do
      stub(200, %{
        "memories" => [
          %{
            "memory" => %{
              "name" => "projects/test-project/.../memories/mem001",
              "fact" => "User prefers tea",
              "createTime" => "2025-06-15T12:30:00Z"
            },
            "distance" => 0.1
          }
        ]
      })

      assert {:ok, [entry]} = VertexAI.search("myapp", "user1", "tea")
      assert entry.timestamp.year == 2025
      assert entry.timestamp.month == 6
      assert entry.timestamp.day == 15
    end
  end

  # -------------------------------------------------------------------------
  # add/3
  # -------------------------------------------------------------------------

  describe "add/3" do
    test "creates a memory for each entry" do
      {:ok, _} = Agent.start_link(fn -> 0 end, name: :add_counter)

      stub_fn(fn conn ->
        {:ok, body_bytes, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body_bytes)

        Agent.update(:add_counter, &(&1 + 1))

        # Verify request includes fact and scope
        assert is_binary(decoded["fact"])
        assert is_map(decoded["scope"])

        Req.Test.json(conn, %{
          "name" => "projects/test-project/.../memories/new-mem-#{Agent.get(:add_counter, & &1)}",
          "fact" => decoded["fact"],
          "scope" => decoded["scope"],
          "createTime" => "2025-01-01T00:00:00Z"
        })
      end)

      entries = [
        Entry.new(content: "User prefers dark mode"),
        Entry.new(content: "User speaks German")
      ]

      assert :ok = VertexAI.add("myapp", "user1", entries)

      count = Agent.get(:add_counter, & &1)
      Agent.stop(:add_counter)
      assert count == 2
    end

    test "sends correct scope in add request" do
      stub_fn(fn conn ->
        {:ok, body_bytes, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body_bytes)

        assert decoded["scope"] == %{"agent_name" => "shopping_app", "user_id" => "bob"}
        assert decoded["fact"] == "Bob likes hiking gear"

        Req.Test.json(conn, %{
          "name" => "projects/test-project/.../memories/mem-new",
          "fact" => decoded["fact"],
          "scope" => decoded["scope"],
          "createTime" => "2025-01-01T00:00:00Z"
        })
      end)

      entry = Entry.new(content: "Bob likes hiking gear")
      assert :ok = VertexAI.add("shopping_app", "bob", [entry])
    end

    test "returns error for empty entry list" do
      # Parity with python: must have at least one entry
      assert {:error, :empty_entries} = VertexAI.add("myapp", "user1", [])
    end

    test "returns error if entry content is empty or whitespace" do
      entries = [Entry.new(content: "   ")]
      assert {:error, :empty_content} = VertexAI.add("myapp", "user1", entries)

      entries = [Entry.new(content: "")]
      assert {:error, :empty_content} = VertexAI.add("myapp", "user1", entries)
    end

    test "returns error if entry content is not text" do
      entries = [Entry.new(content: %{image: "binary_data"})]
      assert {:error, :invalid_content_type} = VertexAI.add("myapp", "user1", entries)
    end

    test "returns error if any create request fails" do
      stub(500, %{"error" => "server error"})

      entries = [Entry.new(content: "some fact")]
      assert {:error, {:api_error, 500, _}} = VertexAI.add("myapp", "user1", entries)
    end
  end

  # -------------------------------------------------------------------------
  # add_session/4
  # -------------------------------------------------------------------------

  describe "add_session/4" do
    test "generates memories from session events" do
      stub_fn(fn conn ->
        {:ok, body_bytes, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body_bytes)

        assert is_map(decoded["directMemoriesSource"])
        direct = decoded["directMemoriesSource"]["directMemories"]
        assert length(direct) == 2
        facts = Enum.map(direct, & &1["fact"])
        assert "Hello there" in facts
        assert "User asked about weather" in facts

        Req.Test.json(conn, %{"done" => true})
      end)

      events = [
        %ADK.Event{
          id: "e1",
          author: "user",
          invocation_id: "inv1",
          timestamp: DateTime.utc_now(),
          content: %{text: "Hello there"}
        },
        %ADK.Event{
          id: "e2",
          author: "agent",
          invocation_id: "inv1",
          timestamp: DateTime.utc_now(),
          content: %{text: "User asked about weather"}
        },
        # Non-text event — should be filtered out
        %ADK.Event{
          id: "e3",
          author: "tool",
          invocation_id: "inv1",
          timestamp: DateTime.utc_now(),
          content: %{function_call: %{name: "search"}}
        }
      ]

      assert :ok = VertexAI.add_session("myapp", "user1", "session-abc", events)
    end

    test "returns ok without making requests when no text events" do
      # No Req.Test stub set — would raise if a request were made
      events = [
        %ADK.Event{
          id: "e1",
          author: "tool",
          invocation_id: "inv1",
          timestamp: DateTime.utc_now(),
          content: %{function_call: %{name: "get_weather"}}
        }
      ]

      assert :ok = VertexAI.add_session("myapp", "user1", "session-xyz", events)
    end

    test "sends generate request to correct URL" do
      stub_fn(fn conn ->
        assert conn.request_path =~ "/memories:generate"
        Req.Test.json(conn, %{"done" => true})
      end)

      events = [
        %ADK.Event{
          id: "e1",
          author: "user",
          invocation_id: "i",
          timestamp: DateTime.utc_now(),
          content: %{text: "Test message"}
        }
      ]

      VertexAI.add_session("myapp", "user1", "session-1", events)
    end

    test "returns error if generate request fails" do
      stub(403, %{"error" => "permission denied"})

      events = [
        %ADK.Event{
          id: "e1",
          author: "user",
          invocation_id: "i",
          timestamp: DateTime.utc_now(),
          content: %{text: "Some text"}
        }
      ]

      assert {:error, {:api_error, 403, _}} =
               VertexAI.add_session("myapp", "user1", "session-1", events)
    end
  end

  # -------------------------------------------------------------------------
  # delete/3
  # -------------------------------------------------------------------------

  describe "delete/3" do
    test "deletes a memory by full resource name" do
      full_name =
        "projects/test-project/locations/us-central1/reasoningEngines/engine-123/memories/mem-to-delete"

      stub_fn(fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path =~ "mem-to-delete"
        Req.Test.json(conn, %{})
      end)

      assert :ok = VertexAI.delete("myapp", "user1", full_name)
    end

    test "deletes a memory by short ID" do
      stub_fn(fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path =~ "short-id-123"
        Req.Test.json(conn, %{})
      end)

      assert :ok = VertexAI.delete("myapp", "user1", "short-id-123")
    end

    test "returns ok if memory already deleted (404)" do
      stub(404, %{"error" => "not found"})

      assert :ok = VertexAI.delete("myapp", "user1", "non-existent")
    end

    test "returns error on server failure" do
      stub(500, %{"error" => "server error"})

      full_name =
        "projects/test-project/locations/us-central1/reasoningEngines/engine-123/memories/bad"

      assert {:error, {:api_error, 500, _}} = VertexAI.delete("myapp", "user1", full_name)
    end
  end

  # -------------------------------------------------------------------------
  # clear/2
  # -------------------------------------------------------------------------

  describe "clear/2" do
    test "lists and deletes all memories for a user scope" do
      {:ok, _} = Agent.start_link(fn -> [] end, name: :deleted_mems)

      stub_fn(fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{
              "memories" => [
                %{
                  "name" =>
                    "projects/test-project/locations/us-central1/reasoningEngines/engine-123/memories/mem-a"
                },
                %{
                  "name" =>
                    "projects/test-project/locations/us-central1/reasoningEngines/engine-123/memories/mem-b"
                }
              ]
            })

          "DELETE" ->
            Agent.update(:deleted_mems, fn acc -> [conn.request_path | acc] end)
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = VertexAI.clear("myapp", "user1")

      paths = Agent.get(:deleted_mems, & &1)
      Agent.stop(:deleted_mems)

      assert length(paths) == 2
      assert Enum.any?(paths, &String.contains?(&1, "mem-a"))
      assert Enum.any?(paths, &String.contains?(&1, "mem-b"))
    end

    test "returns ok when no memories exist to clear" do
      stub(200, %{"memories" => []})

      assert :ok = VertexAI.clear("myapp", "user1")
    end

    test "returns ok when response has no memories key" do
      stub(200, %{})

      assert :ok = VertexAI.clear("myapp", "user1")
    end

    test "returns error if list request fails" do
      stub(503, %{"error" => "service unavailable"})

      assert {:error, {:api_error, 503, _}} = VertexAI.clear("myapp", "user1")
    end
  end

  # -------------------------------------------------------------------------
  # Auth header construction
  # -------------------------------------------------------------------------

  describe "auth" do
    test "sends Bearer token in Authorization header when api_key is set" do
      stub_fn(fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert ["Bearer test-api-key"] = auth
        Req.Test.json(conn, %{"memories" => []})
      end)

      VertexAI.search("myapp", "user1", "test")
    end
  end

  # -------------------------------------------------------------------------
  # URL construction
  # -------------------------------------------------------------------------

  describe "URL construction" do
    test "uses configured project, location, and engine ID in request URL" do
      stub_fn(fn conn ->
        path = conn.request_path

        assert path =~ "test-project"
        assert path =~ "us-central1"
        assert path =~ "engine-123"
        assert path =~ "/memories"

        Req.Test.json(conn, %{"memories" => []})
      end)

      VertexAI.search("myapp", "user1", "query")
    end

    test "uses default location us-central1 when not configured" do
      Application.delete_env(:adk, :vertex_location)
      # Also clear environment variable to ensure fallback to @default_location
      old_env = System.get_env("GOOGLE_CLOUD_LOCATION")

      try do
        System.delete_env("GOOGLE_CLOUD_LOCATION")

        stub_fn(fn conn ->
          assert conn.host =~ "us-central1"
          Req.Test.json(conn, %{"memories" => []})
        end)

        VertexAI.search("myapp", "user1", "query")
      after
        if old_env, do: System.put_env("GOOGLE_CLOUD_LOCATION", old_env)
        Application.put_env(:adk, :vertex_location, "us-central1")
      end
    end
  end

  # -------------------------------------------------------------------------
  # Response mapping
  # -------------------------------------------------------------------------

  describe "response mapping" do
    test "maps Vertex AI memory format to ADK Entry struct" do
      stub(200, %{
        "memories" => [
          %{
            "memory" => %{
              "name" => "projects/p/locations/l/reasoningEngines/r/memories/xyz",
              "fact" => "User is a software engineer",
              "scope" => %{"agent_name" => "myapp", "user_id" => "user1"},
              "createTime" => "2025-03-11T10:00:00Z"
            },
            "distance" => 0.23
          }
        ]
      })

      assert {:ok, [entry]} = VertexAI.search("myapp", "user1", "profession")

      # ID is the full resource name
      assert entry.id =~ "/memories/xyz"
      # Content comes from fact
      assert entry.content == "User is a software engineer"
      # Timestamp is parsed from createTime
      assert %DateTime{} = entry.timestamp
      assert entry.timestamp.year == 2025
      # Metadata includes vertex_name and scope
      assert entry.metadata["vertex_name"] =~ "/memories/xyz"
      assert entry.metadata["scope"]["user_id"] == "user1"
    end

    test "handles missing createTime gracefully" do
      stub(200, %{
        "memories" => [
          %{
            "memory" => %{
              "name" => "projects/p/.../memories/no-time",
              "fact" => "No timestamp"
              # no createTime
            },
            "distance" => 0.5
          }
        ]
      })

      assert {:ok, [entry]} = VertexAI.search("myapp", "user1", "time")
      assert %DateTime{} = entry.timestamp
    end

    test "handles flat memory format (no memory wrapper)" do
      stub(200, %{
        "memories" => [
          %{
            "name" => "projects/p/.../memories/flat-mem",
            "fact" => "Flat format fact",
            "distance" => 0.3
          }
        ]
      })

      assert {:ok, [entry]} = VertexAI.search("myapp", "user1", "flat")
      assert entry.content == "Flat format fact"
    end
  end
end
