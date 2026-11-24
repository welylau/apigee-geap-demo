#!/usr/bin/env bash
# 00 - Enable the APIs used by the Agent Gateway side of the demo (idempotent).
# Ref: set-up-agent-gateway.md "Required APIs" (+ optional DNS / Model Armor /
# observability), configure-iam-policies-uap.md "Before you begin".
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"

APIS=(
  compute.googleapis.com networksecurity.googleapis.com networkservices.googleapis.com
  iam.googleapis.com iap.googleapis.com agentregistry.googleapis.com
  aiplatform.googleapis.com modelarmor.googleapis.com dns.googleapis.com
  run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com
  secretmanager.googleapis.com logging.googleapis.com monitoring.googleapis.com
  telemetry.googleapis.com cloudtrace.googleapis.com
)
banner "00 Enable APIs in ${PROJECT_ID}"
enabled="$(gcloud services list --enabled --project="${PROJECT_ID}" --format='value(config.name)' 2>/dev/null || true)"
todo=()
for a in "${APIS[@]}"; do
  if grep -qx "$a" <<<"${enabled}"; then ok "$a already enabled"; else plan "enable $a"; todo+=("$a"); fi
done
if [[ ${#todo[@]} -gt 0 ]]; then
  run gcloud services enable "${todo[@]}" --project="${PROJECT_ID}"
fi
ok "done"
