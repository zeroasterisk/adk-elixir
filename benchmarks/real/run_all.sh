#!/usr/bin/env bash
# Run both Elixir and Python ADK benchmarks
# Usage: bash benchmarks/real/run_all.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "╔══════════════════════════════════════════╗"
echo "║  ADK Benchmarks — Elixir vs Python       ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Elixir ──────────────────────────────────────
echo "━━━ Running Elixir benchmarks ━━━"
echo ""
cd "$PROJECT_ROOT"
mix run benchmarks/real/elixir_bench.exs
echo ""

# ── Python ──────────────────────────────────────
echo "━━━ Running Python benchmarks ━━━"
echo ""
cd "$SCRIPT_DIR"

if [ ! -d ".venv" ]; then
    echo "Creating Python venv..."
    python3 -m venv .venv
    source .venv/bin/activate
    pip install -q google-adk
else
    source .venv/bin/activate
fi

python python_bench.py
echo ""

echo "━━━ Done ━━━"
echo "Results:"
echo "  Elixir: $PROJECT_ROOT/benchmarks/real/elixir_results.json"
echo "  Python: $SCRIPT_DIR/python_results.json"
