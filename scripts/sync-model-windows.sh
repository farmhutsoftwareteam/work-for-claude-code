#!/usr/bin/env bash
# Regenerate Sources/V2/Chrome/model-windows.json from Anthropic's Models API.
#
# Context windows are the provider's spec, not ours to invent — this pulls the
# authoritative max_input_tokens for every available model and commits the
# result as a snapshot the app reads keylessly. Run it occasionally (when
# Anthropic ships/updates models); a key is needed only to RUN it, never to
# ship or use the app.
#
# Usage:  ANTHROPIC_API_KEY=sk-ant-... ./scripts/sync-model-windows.sh
# Needs:  curl, jq

set -euo pipefail

OUT="$(cd "$(dirname "$0")/.." && pwd)/Sources/V2/Chrome/model-windows.json"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "error: set ANTHROPIC_API_KEY to run the sync." >&2
  exit 1
fi
command -v jq >/dev/null || { echo "error: jq not installed (brew install jq)." >&2; exit 1; }

echo "Fetching https://api.anthropic.com/v1/models …"
resp="$(curl -sS --fail \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  "https://api.anthropic.com/v1/models?limit=1000")"

today="$(date +%Y-%m-%d)"

# Build { id: max_input_tokens } for every model that reports a positive window.
windows="$(echo "$resp" | jq '[.data[] | select(.max_input_tokens > 0) | {key: .id, value: .max_input_tokens}] | from_entries')"

jq -n \
  --arg syncedAt "$today" \
  --argjson windows "$windows" \
  '{
    "_comment": "Anthropic model context windows (max_input_tokens). Snapshot of GET /v1/models. Regenerate with scripts/sync-model-windows.sh — do not hand-edit beyond seeding a new id. Unlisted models fall back to a tokens-only meter (no fabricated %).",
    syncedAt: $syncedAt,
    source: "https://api.anthropic.com/v1/models",
    windows: $windows
  }' > "$OUT"

count="$(echo "$windows" | jq 'length')"
echo "Wrote $count models → $OUT (synced $today)"
