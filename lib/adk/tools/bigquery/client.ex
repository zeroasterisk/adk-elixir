defmodule ADK.Tool.BigQuery.Client do
  @moduledoc """
  A client for BigQuery in ADK Elixir.
  Provides configuration and default user agents for BigQuery and Dataplex clients.
  """

  @doc """
  Get the default base user agent.
  """
  def user_agent_base, do: "google-adk/#{version()}"

  @doc """
  Get the default BigQuery user agent.
  """
  def bq_user_agent, do: "adk-bigquery-tool #{user_agent_base()}"

  @doc """
  Get the default Dataplex user agent.
  """
  def dp_user_agent, do: "adk-dataplex-tool #{user_agent_base()}"

  defstruct [
    :project,
    :credentials,
    :location,
    :user_agent
  ]

  @doc """
  Get a BigQuery client struct with proper user agents.
  """
  def get_bigquery_client(opts \\ []) do
    project = Keyword.get(opts, :project)
    # Default to GCP application default credentials strategy if none provided
    # For now, just nil or the passed credentials
    credentials = Keyword.get(opts, :credentials)

    # In a full port, if project is nil, it fetches from auth/env. We'll simulate that logic
    project = project || System.get_env("GOOGLE_CLOUD_PROJECT")

    location = Keyword.get(opts, :location)
    custom_user_agent = Keyword.get(opts, :user_agent)

    user_agents = [bq_user_agent()] |> append_user_agents(custom_user_agent)

    %__MODULE__{
      project: project,
      credentials: credentials,
      location: location,
      user_agent: Enum.join(user_agents, " ")
    }
  end

  @doc """
  Get a Dataplex Catalog client struct with proper user agents.
  """
  def get_dataplex_catalog_client(opts \\ []) do
    credentials = Keyword.get(opts, :credentials)
    custom_user_agent = Keyword.get(opts, :user_agent)

    user_agents = [dp_user_agent()] |> append_user_agents(custom_user_agent)

    %__MODULE__{
      credentials: credentials,
      user_agent: Enum.join(user_agents, " ")
    }
  end

  defp append_user_agents(agents, nil), do: agents
  defp append_user_agents(agents, custom) when is_binary(custom), do: agents ++ [custom]

  defp append_user_agents(agents, custom) when is_list(custom) do
    agents ++ Enum.reject(custom, &is_nil/1)
  end

  defp version do
    case :application.get_key(:adk, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "0.1.0"
    end
  end
end
