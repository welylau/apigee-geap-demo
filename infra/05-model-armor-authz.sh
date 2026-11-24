#!/usr/bin/env bash
# 05 - Model Armor authorization extension + CONTENT_AUTHZ policy, scoped to
#      MCP traffic only: YOUR_APIGEE_HOST /cymbal-ge-demo/mcp/* (banking)
#      and /cymbal-ge-demo/bureau/* (credit bureau via Apigee). S3: the poisoned
#      CUST-666 response flows Cloud Run -> Apigee -> Agent Gateway, where Model
#      Armor blocks it before the agent sees it.
#
# Multiple CONTENT_AUTHZ policies on one gateway: SUPPORTED on egress gateways
# (max FOUR authorization policies per Agent-to-Anywhere gateway regardless of
# profile; ingress gateways allow only one CONTENT_AUTHZ). Default demo uses
# two; the optional ext-proc variant (06 --enable-extproc) adds a third:
#   REQUEST_AUTHZ  cymbal-ge-demo-iap-policy     (IAP / UAP)        - 02
#   CONTENT_AUTHZ  cymbal-ge-demo-ma-policy      (Model Armor)      - 05
#   CONTENT_AUTHZ  cymbal-ge-demo-apigee-policy  (Apigee ext-proc)  - 06 (optional)
# Ordering: REQUEST_AUTHZ policies run first, then CONTENT_AUTHZ. Among
# policies with the SAME profile the execution order is NOT guaranteed
# (delegate-authorization.md "Policy evaluation on egress" + "Limitations").
# In the default flow the S5 quota is enforced by the Apigee bureau proxy
# itself (behind the gateway), not by a gateway callout.
# Ref: delegate-authorization.md "Delegate authorization to Model Armor".
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"

banner "05 Model Armor authz (${MA_EXT}, ${MA_POLICY})"
plan "authzExtension ${MA_EXT}: modelarmor.${REGION}.rep.googleapis.com, request+response template ${MA_TEMPLATE}"
plan "authzPolicy ${MA_POLICY}: CONTENT_AUTHZ on ${AGW_NAME}, only ${APIGEE_HOST} paths /${PREFIX}/mcp/* and /${PREFIX}/bureau/*"

quiet gcloud model-armor templates describe "${MA_TEMPLATE}" --location="${REGION}" --project="${PROJECT_ID}" \
  || { [[ "${DRY_RUN}" == "1" ]] && warn "template ${MA_TEMPLATE} missing (run 01)" || die "template ${MA_TEMPLATE} missing - run 01 first"; }

R="${STATE_DIR}/rendered"
render "${TEMPLATES_DIR}/ma-authz-extension.yaml" "${R}/ma-authz-extension.yaml"
render "${TEMPLATES_DIR}/ma-authz-policy.yaml" "${R}/ma-authz-policy.yaml"

if quiet gcloud service-extensions authz-extensions describe "${MA_EXT}" --location="${REGION}" --project="${PROJECT_ID}"; then
  ok "authz extension ${MA_EXT} exists"
else
  run gcloud service-extensions authz-extensions import "${MA_EXT}" \
    --source="${R}/ma-authz-extension.yaml" --location="${REGION}" --project="${PROJECT_ID}" --quiet
fi
# Policy import is an upsert - safe to re-run (e.g. after the Cloud Run host changes).
run gcloud network-security authz-policies import "${MA_POLICY}" \
  --source="${R}/ma-authz-policy.yaml" --location="${REGION}" --project="${PROJECT_ID}" --quiet

count="$(gcloud network-security authz-policies list --location="${REGION}" --project="${PROJECT_ID}" \
          --filter="target.resources:${AGW_NAME}" --format='value(name)' 2>/dev/null | grep -c . || true)"
note "authz policies targeting ${AGW_NAME}: ${count} (limit 4)"
ok "done"
