defmodule ADK.Telemetry.GoogleCloud do
  @moduledoc """
  Google Cloud OpenTelemetry integration for ADK Elixir.
  Parity with adk-python's google.adk.telemetry.google_cloud.
  """

  @doc """
  Returns a configuration for GCP OTel exporters to be used in the app.
  Unlike Python, Elixir OTel is typically configured via application environment.
  This function returns a map of configurations that can be used or merged.

  ## Options
    * `:enable_cloud_tracing` - whether to enable tracing to Cloud Trace (default: false)
    * `:enable_cloud_metrics` - whether to enable reporting metrics to Cloud Monitoring (default: false)
    * `:enable_cloud_logging` - whether to enable sending logs to Cloud Logging (default: false)
    * `:project_id` - optional custom project_id. `GOOGLE_CLOUD_PROJECT` env used when omitted.
  """
  def get_gcp_exporters(opts \\ []) do
    enable_cloud_tracing = Keyword.get(opts, :enable_cloud_tracing, false)
    enable_cloud_metrics = Keyword.get(opts, :enable_cloud_metrics, false)
    enable_cloud_logging = Keyword.get(opts, :enable_cloud_logging, false)
    project_id = Keyword.get(opts, :project_id, ADK.Config.google_cloud_project())

    if is_nil(project_id) do
      # Like Python: return empty hooks if project_id is unknown
      %{
        span_processors: [],
        metric_readers: [],
        log_record_processors: []
      }
    else
      %{
        span_processors: if(enable_cloud_tracing, do: [gcp_span_exporter(project_id)], else: []),
        metric_readers:
          if(enable_cloud_metrics, do: [gcp_metrics_exporter(project_id)], else: []),
        log_record_processors:
          if(enable_cloud_logging, do: [gcp_logs_exporter(project_id)], else: [])
      }
    end
  end

  defp gcp_span_exporter(_project_id) do
    # Represents OTLPSpanExporter pointing to telemetry.googleapis.com
    {:opentelemetry_exporter, %{endpoints: ["https://telemetry.googleapis.com/v1/traces"]}}
  end

  defp gcp_metrics_exporter(project_id) do
    # Represents CloudMonitoringMetricsExporter
    {:cloud_monitoring_exporter, %{project_id: project_id, export_interval_ms: 5000}}
  end

  defp gcp_logs_exporter(project_id) do
    # Represents CloudLoggingExporter
    log_name = ADK.Config.google_cloud_default_log_name() || "adk-otel"
    {:cloud_logging_exporter, %{project_id: project_id, default_log_name: log_name}}
  end

  @doc """
  Returns OTEL resource attributes, prioritizing project_id argument,
  then environment variables like OTEL_RESOURCE_ATTRIBUTES.
  """
  def get_gcp_resource(project_id \\ nil) do
    # Simulates merging resources
    env_project_id = parse_env_resource_attributes() |> Map.get("gcp.project_id")

    final_project_id =
      cond do
        !is_nil(env_project_id) -> env_project_id
        !is_nil(project_id) -> project_id
        true -> nil
      end

    if is_nil(final_project_id) do
      %{}
    else
      %{"gcp.project_id" => final_project_id}
    end
  end

  defp parse_env_resource_attributes do
    env_str = ADK.Config.otel_resource_attributes() || ""

    env_str
    |> String.split(",", trim: true)
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.reduce(%{}, fn
      [k, v], acc -> Map.put(acc, String.trim(k), String.trim(v))
      _, acc -> acc
    end)
  end
end
