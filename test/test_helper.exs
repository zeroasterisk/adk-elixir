ExUnit.start(exclude: [:integration, :a2a])

# Ensure the ADK application is started even when running with `--no-start`.
# This starts the supervision tree (SessionRegistry, RunnerSupervisor, etc.)
# so tests that depend on these processes work regardless of how mix test is invoked.
{:ok, _} = Application.ensure_all_started(:adk)
