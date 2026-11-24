#!/usr/bin/env bash
# Deploy the mock Credit Bureau MCP server to Cloud Run (asia-southeast1).
#
#   ./credit-bureau/deploy.sh [--dry-run]
#
# Creates/updates Cloud Run service cymbal-ge-demo-credit-bureau:
#   - public (--allow-unauthenticated): it simulates a public third-party API
#   - max 1 instance, min 0 (cost guard), 1 vCPU / 256Mi
#   - source build via Cloud Build (uses the Dockerfile in this folder)
# Idempotent: re-running deploys a new revision of the same service.
# Prints the Cloud Run MCP URL = target backend of the Apigee bureau proxy
# (https://YOUR_APIGEE_HOST/cymbal-ge-demo/bureau/mcp). Public because Apigee
# calls it over the internet; it simulates a public third-party API.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../infra/env.sh
source "${HERE}/../infra/env.sh"
# shellcheck source=../infra/lib.sh
source "${HERE}/../infra/lib.sh"
parse_common_flags "$@"

banner "Credit Bureau -> Cloud Run service ${CREDIT_BUREAU_SERVICE} (${REGION})"
plan "Cloud Run service ${CREDIT_BUREAU_SERVICE}: public, max-instances=1, min-instances=1, 1 vCPU/256Mi"
plan "Build: Cloud Build from ${HERE} (Dockerfile, stdlib Python, non-root)"

if gcloud run services describe "${CREDIT_BUREAU_SERVICE}" --region="${REGION}" \
     --project="${PROJECT_ID}" --format="value(status.url)" >/dev/null 2>&1; then
  note "service exists -> a new revision will be deployed"
else
  note "service does not exist -> it will be created"
fi

run gcloud run deploy "${CREDIT_BUREAU_SERVICE}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --source="${HERE}" \
  --allow-unauthenticated \
  --ingress=all \
  --max-instances=1 \
  --min-instances=1 \
  --cpu=1 \
  --memory=256Mi \
  --concurrency=40 \
  --timeout=30 \
  --port=8080 \
  --labels="demo=${PREFIX},component=credit-bureau" \
  --quiet

if [[ "${DRY_RUN}" == "1" ]]; then
  note "dry-run: the MCP URL will be https://<service-url>/mcp"
  exit 0
fi

URL="$(credit_bureau_url)"
ok "Credit Bureau Cloud Run MCP endpoint: ${URL}"
note "This is the TARGET of the Apigee proxy /cymbal-ge-demo/bureau/mcp (give it to the apigee/ owner)."
note "The agent never calls it directly; Agent Registry registers the Apigee URL (infra/03)."
note "Smoke test: curl -s -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}' ${URL}"
