defmodule ADK.Policy.DefaultPolicy do
  @moduledoc """
  A permissive default policy that allows everything and passes content through unchanged.
  """

  @behaviour ADK.Policy

  @impl true
  def authorize_tool(_tool, _args, _ctx), do: :allow

  @impl true
  def filter_input(content, _ctx), do: {:cont, content}

  @impl true
  def filter_output(events, _ctx), do: events
end
