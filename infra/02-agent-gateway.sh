#!/usr/bin/env bash
# 02 - Agent Gateway cymbal-ge-demo-agw (AGENT_TO_ANYWHERE, regional registry)
#      + IAP authorization extension (iapPolicyVersion V2, DRY_RUN)
#      + REQUEST_AUTHZ authorization policy that attaches it to the gateway.
# Starts in AUDIT-ONLY (DRY_RUN): IAP logs would-be denials but blocks nothing,
# so the agent can be deployed and the essential hosts verified first.
# Switch to enforcement with 02b-enforce-iap.sh.
# Without ANY authz policy an egress gateway is default-deny, so the policy is
# created right after the gateway.
# Ref: set-up-agent-gateway.md (gcloud, egress), delegate-authorization.md.
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"
export IAP_EXT_ACTIVE="${IAP_EXT_DRYRUN}"

banner "02 Agent Gateway ${AGW_NAME} + IAP (DRY_RUN)"
plan "agentGateway ${AGW_RESOURCE} (protocols MCP, AGENT_TO_ANYWHERE, registry ${REGISTRY_PATH})"
plan "authzExtension ${IAP_EXT_DRYRUN} (iap.googleapis.com, V2, DRY_RUN, failOpen=false)"
plan "authzPolicy ${IAP_POLICY} (REQUEST_AUTHZ, CUSTOM -> ${IAP_EXT_DRYRUN})"

R="${STATE_DIR}/rendered"
render "${TEMPLATES_DIR}/agent-gateway.yaml" "${R}/agent-gateway.yaml"
render "${TEMPLATES_DIR}/iap-authz-extension-dryrun.yaml" "${R}/iap-authz-extension-dryrun.yaml"
render "${TEMPLATES_DIR}/iap-authz-policy.yaml" "${R}/iap-authz-policy.yaml"

# --- gateway: create only (an import REPLACES the resource; 06 edits it via export->edit->import)
if quiet gcloud network-services agent-gateways describe "${AGW_NAME}" --location="${REGION}" --project="${PROJECT_ID}"; then
  ok "gateway ${AGW_NAME} exists - not re-importing (would overwrite networkConfig)"
else
  run gcloud network-services agent-gateways import "${AGW_NAME}" \
    --source="${R}/agent-gateway.yaml" --location="${REGION}" --project="${PROJECT_ID}" --quiet
fi

# --- IAP extension (dry-run)
if quiet gcloud service-extensions authz-extensions describe "${IAP_EXT_DRYRUN}" --location="${REGION}" --project="${PROJECT_ID}"; then
  ok "authz extension ${IAP_EXT_DRYRUN} exists"
else
  run gcloud service-extensions authz-extensions import "${IAP_EXT_DRYRUN}" \
    --source="${R}/iap-authz-extension-dryrun.yaml" --location="${REGION}" --project="${PROJECT_ID}" --quiet
fi

# --- REQUEST_AUTHZ policy (do not touch if it exists: it may already point at the enforced extension)
if quiet gcloud network-security authz-policies describe "${IAP_POLICY}" --location="${REGION}" --project="${PROJECT_ID}"; then
  current="$(gcloud network-security authz-policies describe "${IAP_POLICY}" --location="${REGION}" \
              --project="${PROJECT_ID}" --format='value(customProvider.authzExtension.resources)' 2>/dev/null || true)"
  ok "authz policy ${IAP_POLICY} exists (extension: ${current##*/})"
else
  run gcloud network-security authz-policies import "${IAP_POLICY}" \
    --source="${R}/iap-authz-policy.yaml" --location="${REGION}" --project="${PROJECT_ID}" --quiet
fi

if [[ "${DRY_RUN}" != "1" ]]; then
  gcloud network-services agent-gateways describe "${AGW_NAME}" --location="${REGION}" --project="${PROJECT_ID}" \
    --format="yaml(name,googleManaged,registries,networkConfig)" || true
fi
ok "done - gateway is in DRY_RUN; run 02b-enforce-iap.sh after the UAP (04) is verified in logs"
