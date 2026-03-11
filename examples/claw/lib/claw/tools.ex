defmodule Claw.Tools do
  @moduledoc """
  Tool implementations for Claw — ADK Elixir showcase.

  Demonstrates ALL major ADK Elixir tool capabilities:

  1. **Basic tools** — `datetime`, `read_file`, `shell_command`
  2. **Artifacts** — `save_note` (persist text as artifact), `list_notes` (retrieve artifact list)
  3. **Auth/Credentials** — `call_mock_api` (shows credential management flow)
  4. **LongRunningTool** — `research` (sends progress updates during long work)
  """

  alias ADK.Tool.FunctionTool
  alias ADK.Tool.LongRunningTool
  alias ADK.ToolContext

  @doc "All basic tools."
  def basic_tools do
    [datetime(), read_file(), shell_command()]
  end

  @doc "All showcase tools (including artifacts, auth, long-running)."
  def all do
    [datetime(), read_file(), shell_command(), save_note(), list_notes(), call_mock_api(), research()]
  end

  # ---------------------------------------------------------------------------
  # Basic Tools (existing)
  # ---------------------------------------------------------------------------

  @doc "Tool that returns the current date and time."
  def datetime do
    FunctionTool.new(:datetime,
      description: "Get the current date and time in UTC",
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      },
      func: fn _ctx, _args ->
        now = DateTime.utc_now()
        {:ok, "Current UTC time: #{DateTime.to_iso8601(now)}"}
      end
    )
  end

  @doc "Tool that reads a file from disk."
  def read_file do
    FunctionTool.new(:read_file,
      description: "Read the contents of a file. Path is relative to the project root.",
      parameters: %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "File path to read"}
        },
        required: ["path"]
      },
      func: fn _ctx, %{"path" => path} ->
        safe_path = Path.expand(path, File.cwd!())

        if String.starts_with?(safe_path, File.cwd!()) do
          case File.read(safe_path) do
            {:ok, content} ->
              truncated =
                if String.length(content) > 4000 do
                  String.slice(content, 0, 4000) <> "\n... (truncated)"
                else
                  content
                end

              {:ok, truncated}

            {:error, reason} ->
              {:error, "Cannot read file: #{reason}"}
          end
        else
          {:error, "Access denied: path outside project directory"}
        end
      end
    )
  end

  @doc "Tool that runs a sandboxed shell command."
  def shell_command do
    allowed_prefixes = ~w[ls cat head tail wc echo date whoami uname pwd find grep]

    FunctionTool.new(:shell_command,
      description:
        "Run a shell command. Only safe read-only commands are allowed (ls, cat, head, tail, wc, echo, date, grep, find).",
      parameters: %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Shell command to run"}
        },
        required: ["command"]
      },
      func: fn _ctx, %{"command" => command} ->
        base_cmd =
          command
          |> String.trim()
          |> String.split(~r/\s+/, parts: 2)
          |> List.first()

        if base_cmd in allowed_prefixes do
          case System.cmd("sh", ["-c", command], stderr_to_stdout: true) do
            {output, 0} ->
              truncated =
                if String.length(output) > 4000 do
                  String.slice(output, 0, 4000) <> "\n... (truncated)"
                else
                  output
                end

              {:ok, truncated}

            {output, code} ->
              {:error, "Command exited with code #{code}: #{output}"}
          end
        else
          {:error,
           "Command '#{base_cmd}' not allowed. Allowed: #{Enum.join(allowed_prefixes, ", ")}"}
        end
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Artifact Tools
  # ---------------------------------------------------------------------------

  @doc """
  Tool that saves a note as an artifact.

  Demonstrates ADK.Artifact — persistent binary blob storage attached to a
  session. Notes are saved as text artifacts and survive across tool calls.
  """
  def save_note do
    FunctionTool.new(:save_note,
      description: "Save a note or piece of information as an artifact for later retrieval.",
      parameters: %{
        type: "object",
        properties: %{
          title: %{type: "string", description: "Short title for the note (used as filename)"},
          content: %{type: "string", description: "The note content to save"}
        },
        required: ["title", "content"]
      },
      func: fn ctx, %{"title" => title, "content" => content} ->
        filename = sanitize_filename(title) <> ".txt"
        artifact = %{
          data: content,
          content_type: "text/plain",
          metadata: %{
            title: title,
            saved_at: DateTime.to_iso8601(DateTime.utc_now())
          }
        }

        cond do
          is_nil(ctx) ->
            {:ok, "Note '#{title}' acknowledged (no artifact service in test context)."}

          not match?(%ToolContext{}, ctx) ->
            {:ok, "Note '#{title}' acknowledged (minimal context, no artifact service)."}

          true ->
            case ToolContext.save_artifact(ctx, filename, artifact) do
              {:ok, version, _updated_ctx} ->
                {:ok, "Note '#{title}' saved as '#{filename}' (version #{version})."}

              {:error, :no_artifact_service} ->
                {:ok, "Note saved (tip: configure artifact_service on Runner for persistence): #{title}"}

              {:error, reason} ->
                {:error, "Failed to save note: #{inspect(reason)}"}
            end
        end
      end
    )
  end

  @doc """
  Tool that lists all saved notes (artifacts).

  Demonstrates ADK.Artifact retrieval — loading artifact list from the store.
  """
  def list_notes do
    FunctionTool.new(:list_notes,
      description: "List all notes/artifacts that have been saved in this session.",
      parameters: %{
        type: "object",
        properties: %{},
        required: []
      },
      func: fn ctx, _args ->
        cond do
          is_nil(ctx) or not match?(%ToolContext{}, ctx) ->
            {:ok, "No artifact service available in this context."}

          true ->
            case ToolContext.list_artifacts(ctx) do
              {:ok, []} ->
                {:ok, "No notes saved yet. Use save_note to create one."}

              {:ok, filenames} ->
                note_list = Enum.map_join(filenames, "\n", &"  - #{&1}")
                {:ok, "Saved notes:\n#{note_list}"}

              {:error, :no_artifact_service} ->
                {:ok, "No artifact service configured. Notes are not persisted in this session."}

              {:error, reason} ->
                {:error, "Failed to list notes: #{inspect(reason)}"}
            end
        end
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Auth/Credentials Tool
  # ---------------------------------------------------------------------------

  @doc """
  Mock external API tool that demonstrates credential management.

  Shows how ADK handles the "check → request → use" credential lifecycle.
  In a real app, you'd exchange a real API key for authenticated requests.
  """
  def call_mock_api do
    FunctionTool.new(:call_mock_api,
      description: """
      Call a mock external API that requires an API key credential.
      Demonstrates ADK credential management — the tool checks for stored
      credentials, requests auth if missing, and uses the credential.
      """,
      parameters: %{
        type: "object",
        properties: %{
          endpoint: %{
            type: "string",
            description: "Which mock endpoint to call: 'weather', 'news', or 'prices'"
          }
        },
        required: ["endpoint"]
      },
      func: fn ctx, %{"endpoint" => endpoint} ->
        cred_name = "mock_api_key"

        cond do
          is_nil(ctx) or not match?(%ToolContext{}, ctx) ->
            # No context (test/direct call) — simulate with a demo key
            simulate_api_call(endpoint, "demo-direct-key")

          true ->
            # Full context — use credential lifecycle
            case ToolContext.load_credential(ctx, cred_name) do
              {:ok, cred} ->
                simulate_api_call(endpoint, cred.api_key)

              {:error, :not_found} ->
                demo_key = "demo-api-key-#{System.unique_integer([:positive])}"
                cred = ADK.Auth.Credential.api_key(demo_key)
                ToolContext.save_credential(ctx, cred_name, cred)
                simulate_api_call(endpoint, demo_key)

              {:error, :no_credential_store} ->
                simulate_api_call(endpoint, "no-store-demo-key")
            end
        end
      end
    )
  end

  defp simulate_api_call(endpoint, api_key) do
    key_preview = String.slice(api_key || "", 0, 8) <> "..."

    result =
      case endpoint do
        "weather" ->
          "🌤️ Mock Weather API (key: #{key_preview}): Sunny, 22°C, humidity 45%"

        "news" ->
          "📰 Mock News API (key: #{key_preview}): Top story — ADK Elixir v1.0 ships!"

        "prices" ->
          "💰 Mock Prices API (key: #{key_preview}): BTC=$45,000, ETH=$2,500"

        _ ->
          "❓ Unknown endpoint '#{endpoint}'. Try: weather, news, prices"
      end

    {:ok, result}
  end

  # ---------------------------------------------------------------------------
  # Long-Running Tool
  # ---------------------------------------------------------------------------

  @doc """
  Research tool that demonstrates ADK.Tool.LongRunningTool.

  Simulates a multi-step research process with progress updates — the BEAM
  equivalent of Python ADK's `is_long_running = True`. Runs in a supervised
  OTP process with configurable timeout.
  """
  def research do
    LongRunningTool.new(:research,
      description: "Research a topic by searching multiple sources. Takes time but provides thorough results.",
      parameters: %{
        type: "object",
        properties: %{
          topic: %{type: "string", description: "The topic to research"},
          depth: %{
            type: "string",
            description: "Research depth: 'quick' (3 steps) or 'deep' (6 steps)",
            enum: ["quick", "deep"]
          }
        },
        required: ["topic"]
      },
      timeout: 30_000,
      func: fn _ctx, args, send_update ->
        topic = Map.get(args, "topic", "unknown topic")
        depth = Map.get(args, "depth", "quick")
        steps = if depth == "deep", do: 6, else: 3

        send_update.("🔍 Starting research on: #{topic}")
        Process.sleep(300)

        sources = ["Wikipedia", "ArXiv", "GitHub", "HackerNews", "Reddit", "Stack Overflow"]

        results =
          Enum.map(1..steps, fn i ->
            source = Enum.at(sources, i - 1, "Source #{i}")
            send_update.("📚 Searching #{source}... (#{i}/#{steps})")
            Process.sleep(200)
            "#{source}: Found #{:rand.uniform(5)} relevant results about #{topic}"
          end)

        send_update.("✅ Compiling findings...")
        Process.sleep(200)

        summary = """
        Research complete for: #{topic}
        Depth: #{depth} (#{steps} sources checked)

        Findings:
        #{Enum.map_join(results, "\n", &"  - #{&1}")}

        Summary: Based on #{steps} sources, #{topic} is an actively researched area
        with significant recent developments. Key themes include performance,
        developer experience, and production readiness.
        """

        {:ok, String.trim(summary)}
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp sanitize_filename(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\-_]/, "_")
    |> String.slice(0, 50)
  end
end
