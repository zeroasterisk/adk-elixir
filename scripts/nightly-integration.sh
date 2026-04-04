#!/usr/bin/env bash
# Nightly integration test runner for ADK Elixir.
#
# Runs all tests tagged :integration against real LLM APIs.
# Requires at least one auth method:
#   - GEMINI_API_KEY (Gemini API key)
#   - GOOGLE_APPLICATION_CREDENTIALS (service account JSON for bearer token)
#   - ANTHROPIC_API_KEY (Anthropic integration tests)
#
# Usage:
#   GEMINI_API_KEY=xxx ./scripts/nightly-integration.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — test failures
#   2 — no auth configured

set -euo pipefail

echo "=== ADK Elixir Nightly Integration Tests ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Check for at least one auth method
if [[ -z "${GEMINI_API_KEY:-}" && -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  echo "ERROR: No Gemini auth configured."
  echo "Set GEMINI_API_KEY or GOOGLE_APPLICATION_CREDENTIALS."
  exit 2
fi

if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  echo "Auth: GEMINI_API_KEY set"
fi
if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  echo "Auth: GOOGLE_APPLICATION_CREDENTIALS set"
fi
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "Auth: ANTHROPIC_API_KEY set"
fi
echo ""

# Ensure deps are fetched and compiled
mix deps.get --only test
mix compile --warnings-as-errors

echo ""
echo "=== Running integration tests ==="
echo ""

# Run only integration-tagged tests
mix test --only integration --trace

echo ""
echo "=== Nightly integration tests complete ==="
