if Code.ensure_loaded?(A2A.AgentCard) and function_exported?(A2A.AgentCard, :new, 1) do
defmodule ADK.A2A.RemoteAgentTool do
  @moduledoc """
  Wraps a remote A2A agent as an ADK tool.

  When called, sends a task to the remote agent and returns the result text.

  ## Examples

      tool = ADK.A2A.RemoteAgentTool.new(
        name: "researcher",
        url: "http://researcher:4000/a2a",
        description: "Research any topic"
      )
  """

  defstruct [:name, :description, :url, :parameters]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          url: String.t(),
          parameters: map()
        }

  @doc "Create a new remote agent tool."
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      url: Keyword.fetch!(opts, :url),
      description: Keyword.get(opts, :description, "Remote A2A agent"),
      parameters: Keyword.get(opts, :parameters, %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string", "description" => "Message to send to the agent"}
        },
        "required" => ["message"]
      })
    }
  end

  @doc "Execute the remote agent tool — sends a task and returns the result."
  @spec run(t(), ADK.ToolContext.t(), map()) :: ADK.Tool.result()
  def run(%__MODULE__{url: url}, _ctx, %{"message" => message}) do
    case ADK.A2A.Client.send_task(url, message) do
      {:ok, %{"status" => %{"state" => "TASK_STATE_COMPLETED"}, "artifacts" => artifacts}} ->
        text = extract_text_from_artifacts(artifacts)
        {:ok, text}

      {:ok, %{"status" => %{"state" => "TASK_STATE_FAILED"} = status}} ->
        {:error, status["message"] || "Task failed"}

      {:ok, result} ->
        # Check if it's already a terminal state but not completed
        state = get_in(result, ["status", "state"])
        if state in ["TASK_STATE_FAILED", "TASK_STATE_CANCELED", "TASK_STATE_REJECTED"] do
          {:error, "Task ended with state: #{state}"}
        else
          {:ok, inspect(result)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(%__MODULE__{} = tool, ctx, %{} = args) do
    # Try string keys
    case Map.get(args, "message") || Map.get(args, :message) do
      nil -> {:error, "missing 'message' parameter"}
      msg -> run(tool, ctx, %{"message" => msg})
    end
  end

  defp extract_text_from_artifacts(artifacts) when is_list(artifacts) do
    artifacts
    |> Enum.flat_map(fn
      %{"parts" => parts} -> parts
      _ -> []
    end)
    |> Enum.map(fn
      %{"text" => t} -> t
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp extract_text_from_artifacts(_), do: ""
end
else
  defmodule ADK.A2A.RemoteAgentTool do
    @moduledoc "Requires {:a2a, \"~> 0.2\"} optional dependency. Install it to enable A2A protocol support."
  end
end
