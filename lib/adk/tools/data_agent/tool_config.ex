defmodule ADK.Tool.DataAgent.ToolConfig do
  @moduledoc "Configuration for Data Agent tools."

  defstruct max_query_result_rows: 50

  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end
end
