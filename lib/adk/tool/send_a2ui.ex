defmodule ADK.Tool.SendA2UI do
  @moduledoc """
  Tool to send A2UI JSON payloads to the client.
  """
  defstruct [:name, :description]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t()
        }

  @doc "Create a new SendA2UI tool."
  @spec new() :: t()
  def new do
    %__MODULE__{
      name: "send_a2ui_json_to_client",
      description: "Sends A2UI JSON to the client to render rich UI for the user."
    }
  end

  @doc "Execute the tool."
  @spec run(ADK.ToolContext.t(), map()) :: ADK.Tool.result()
  def run(_ctx, %{"a2ui_json" => a2ui_json}) do
    payload = case Jason.decode(a2ui_json) do
      {:ok, decoded} -> decoded
      {:error, _} -> a2ui_json
    end

    {:ok, %{"validated_a2ui_json" => payload}}
  end
end
