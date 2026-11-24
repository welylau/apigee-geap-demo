#!/usr/bin/env bash
# 02b - Switch the gateway's IAP authorization from DRY_RUN to ENFORCED.
#   ./infra/02b-enforce-iap.sh [--dry-run]            enforce
#   ./infra/02b-enforce-iap.sh --rollback [--dry-run] back to DRY_RUN
# Creates authz extension cymbal-ge-demo-iap-authz-enforced (V2, ENFORCED) and
# re-points the REQUEST_AUTHZ policy at it (pattern from the official egress
# codelab), keeping the dry-run extension for instant rollback.
# PRECONDITION: the UAP from 04 is bound and IAP audit logs show the agent's
# platform calls (sessions, telemetry, LLM) as granted - otherwise every agent
# invocation fails (403/498, see agent-gateway-runtime-deploy.md caution).
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"
ROLLBACK=0; for a in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do [[ "$a" == "--rollback" ]] && ROLLBACK=1; done

if [[ "${ROLLBACK}" == "1" ]]; then
  export IAP_EXT_ACTIVE="${IAP_EXT_DRYRUN}"; mode="DRY_RUN (rollback)"
else
  export IAP_EXT_ACTIVE="${IAP_EXT_ENFORCED}"; mode="ENFORCED"
fi
banner "02b IAP authorization -> ${mode}"
plan "authzPolicy ${IAP_POLICY} -> extension ${IAP_EXT_ACTIVE}"

quiet gcloud iam policy-bindings describe "${UAP_BINDING}" --location=global --project="${PROJECT_ID}" \
  || warn "UAP binding ${UAP_BINDING} not found - enforcing now would block ALL agent egress (run 04 first)"

R="${STATE_DIR}/rendered"
if [[ "${ROLLBACK}" != "1" ]]; then
  render "${TEMPLATES_DIR}/iap-authz-extension-enforced.yaml" "${R}/iap-authz-extension-enforced.yaml"
  if quiet gcloud service-extensions authz-extensions describe "${IAP_EXT_ENFORCED}" --location="${REGION}" --project="${PROJECT_ID}"; then
    ok "authz extension ${IAP_EXT_ENFORCED} exists"
  else
    plan "authzExtension ${IAP_EXT_ENFORCED} (V2, ENFORCED, failOpen=false)"
    run gcloud service-extensions authz-extensions import "${IAP_EXT_ENFORCED}" \
      --source="${R}/iap-authz-extension-enforced.yaml" --location="${REGION}" --project="${PROJECT_ID}" --quiet
  fi
fi

if [[ "${DRY_RUN}" != "1" && "${ASSUME_YES}" != "1" ]]; then
  confirm "Re-point ${IAP_POLICY} to ${IAP_EXT_ACTIVE} (${mode})?" || die "aborted"
fi
render "${TEMPLATES_DIR}/iap-authz-policy.yaml" "${R}/iap-authz-policy.yaml"
run gcloud network-security authz-policies import "${IAP_POLICY}" \
  --source="${R}/iap-authz-policy.yaml" --location="${REGION}" --project="${PROJECT_ID}" --quiet
ok "IAP authorization is now ${mode}"
note "Verify: gcloud logging read 'protoPayload.serviceName=\"iap.googleapis.com\" AND protoPayload.metadata.iapPolicyVersion=\"v2\"' --project=${PROJECT_ID} --limit=20"
