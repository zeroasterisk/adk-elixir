defmodule ADK.Telemetry.GoogleCloudTest do
  use ExUnit.Case, async: false
  alias ADK.Telemetry.GoogleCloud

  describe "get_gcp_exporters/1" do
    setup do
      prev = System.get_env("GOOGLE_CLOUD_PROJECT")
      System.delete_env("GOOGLE_CLOUD_PROJECT")

      on_exit(fn ->
        if prev,
          do: System.put_env("GOOGLE_CLOUD_PROJECT", prev),
          else: System.delete_env("GOOGLE_CLOUD_PROJECT")
      end)

      :ok
    end

    test "returns empty lists when project_id is missing and not provided" do
      hooks =
        GoogleCloud.get_gcp_exporters(
          enable_cloud_tracing: true,
          enable_cloud_metrics: true,
          enable_cloud_logging: true
        )

      assert hooks.span_processors == []
      assert hooks.metric_readers == []
      assert hooks.log_record_processors == []
    end

    test "returns configured exporters when project_id is present" do
      hooks =
        GoogleCloud.get_gcp_exporters(
          enable_cloud_tracing: true,
          enable_cloud_metrics: true,
          enable_cloud_logging: true,
          project_id: "test-project-123"
        )

      assert length(hooks.span_processors) == 1
      assert length(hooks.metric_readers) == 1
      assert length(hooks.log_record_processors) == 1

      # Check specific exporter configs
      [{:opentelemetry_exporter, trace_config}] = hooks.span_processors
      assert trace_config.endpoints == ["https://telemetry.googleapis.com/v1/traces"]

      [{:cloud_monitoring_exporter, metrics_config}] = hooks.metric_readers
      assert metrics_config.project_id == "test-project-123"

      [{:cloud_logging_exporter, logs_config}] = hooks.log_record_processors
      assert logs_config.project_id == "test-project-123"
      assert logs_config.default_log_name == "adk-otel"
    end

    test "only returns enabled exporters" do
      hooks =
        GoogleCloud.get_gcp_exporters(
          enable_cloud_tracing: true,
          enable_cloud_metrics: false,
          enable_cloud_logging: false,
          project_id: "test-project-123"
        )

      assert length(hooks.span_processors) == 1
      assert hooks.metric_readers == []
      assert hooks.log_record_processors == []
    end
  end

  describe "get_gcp_resource/1" do
    setup do
      prev = System.get_env("OTEL_RESOURCE_ATTRIBUTES")
      System.delete_env("OTEL_RESOURCE_ATTRIBUTES")

      on_exit(fn ->
        if prev,
          do: System.put_env("OTEL_RESOURCE_ATTRIBUTES", prev),
          else: System.delete_env("OTEL_RESOURCE_ATTRIBUTES")
      end)

      :ok
    end

    test "returns empty map when no project_id provided or in env" do
      assert GoogleCloud.get_gcp_resource() == %{}
    end

    test "uses provided project_id" do
      assert GoogleCloud.get_gcp_resource("arg-project") == %{"gcp.project_id" => "arg-project"}
    end

    test "prefers OTEL_RESOURCE_ATTRIBUTES over provided project_id" do
      System.put_env("OTEL_RESOURCE_ATTRIBUTES", "gcp.project_id=env-project,other.key=val")

      assert GoogleCloud.get_gcp_resource("arg-project") == %{"gcp.project_id" => "env-project"}
    end
  end
end
