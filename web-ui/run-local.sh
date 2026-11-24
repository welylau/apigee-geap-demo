#!/usr/bin/env bash
# ==============================================================================
# Runs the Agents Meet APIs: Gemini Enterprise Agent Platform × Apigee web UI locally.
#   DEMO_MOCK=1 ./run-local.sh     # scripted traces, no cloud resources needed
#   ./run-local.sh                 # real RM Agent + Apigee (keys pulled from Secret Manager)
#
# Real mode needs ADC for YOUR_PROJECT_ID (aiplatform.user + secretAccessor on the two secrets).
# Keys are read into this process only; they are never written to disk or printed.
# ==============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

if [ -f "$DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$DIR/.env"
  set +a
fi

PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
export PROJECT_ID REGION="${REGION:-asia-southeast1}" APIGEE_HOST="${APIGEE_HOST:-YOUR_APIGEE_HOST}"

if [ "${DEMO_MOCK:-0}" != "1" ]; then
  secret() { gcloud secrets versions access latest --secret="$1" --project="$PROJECT_ID" 2>/dev/null || true; }
  [ -n "${API_KEY:-}" ] || API_KEY="$(secret cymbal-ge-demo-webui-key)"
  [ -n "${PARTNER_API_KEY:-}" ] || PARTNER_API_KEY="$(secret cymbal-ge-demo-partner-key)"
  if [ -z "${AGENT_ENGINE_ID:-}" ] && [ -f "$ROOT/agent/.deployed.json" ]; then
    AGENT_ENGINE_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(str(d.get("name") or d.get("resource_name","")).rsplit("/",1)[-1])' "$ROOT/agent/.deployed.json")"
  fi
  if [ -z "${INSIGHTS_ENGINE_ID:-}" ] && [ -f "$ROOT/agent/.deployed-insights.json" ]; then
    INSIGHTS_ENGINE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("engine_id",""))' "$ROOT/agent/.deployed-insights.json")"
  fi
  export API_KEY PARTNER_API_KEY AGENT_ENGINE_ID="${AGENT_ENGINE_ID:-}" INSIGHTS_ENGINE_ID="${INSIGHTS_ENGINE_ID:-}"
fi

if [ -z "${PORT:-}" ]; then
  if lsof -i :8080 >/dev/null 2>&1; then PORT=8081; else PORT=8080; fi
fi
# Local-only by default. Set HOST=0.0.0.0 explicitly to expose on the network.
HOST="${HOST:-127.0.0.1}"
export PORT HOST

echo "=================================================================="
echo "▶ Agents Meet APIs: Gemini Enterprise Agent Platform × Apigee UI: http://localhost:${PORT}  (bound to ${HOST})"
[ "${DEMO_MOCK:-0}" = "1" ] && echo "  DEMO_MOCK=1: scripted traces, no cloud calls"
echo "=================================================================="
exec python3 "$DIR/server.py"
