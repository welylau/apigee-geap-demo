#!/usr/bin/env bash
# 01 - Model Armor template cymbal-ge-demo-ma (asia-southeast1).
#   prompt-injection & jailbreak filter ON (confidence ${MA_PI_CONFIDENCE}),
#   malicious-URI filter OFF (unsupported in asia-southeast1); template used for BOTH request and response inspection
#   (the authz extension in 05 points request_template_id and
#   response_template_id at this template).
#   Custom block error code/message carry the marker "cymbal-model-armor" so
#   the RM Agent can tell a Model Armor block from an IAP/UAP denial if the
#   gateway surfaces them (unverified - see README).
# Also grants the Service Extensions service agent the roles Model Armor needs
# (delegate-authorization.md: modelarmor.calloutUser + serviceusage
# .serviceUsageConsumer on the gateway project, modelarmor.user on the template
# project - required even when they are the same project).
#
#   ./infra/01-model-armor.sh [--dry-run] [--test]
#   --test : after create, call sanitizeModelResponse with the CUST-666 note.
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"
DO_TEST=0; for a in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do [[ "$a" == "--test" ]] && DO_TEST=1; done

banner "01 Model Armor template ${MA_TEMPLATE} (${REGION})"
plan "template ${MA_TEMPLATE_RESOURCE}: PI+jailbreak=${MA_PI_CONFIDENCE}, malicious URI off (not offered in asia-southeast1), logging on"
plan "IAM: ${DEP_SA} -> roles/modelarmor.calloutUser, roles/serviceusage.serviceUsageConsumer, roles/modelarmor.user"

if quiet gcloud model-armor templates describe "${MA_TEMPLATE}" --location="${REGION}" --project="${PROJECT_ID}"; then
  ok "template exists - leaving it unchanged (delete it via 99-teardown.sh to recreate with new settings)"
else
run gcloud model-armor templates create "${MA_TEMPLATE}" \
  --project="${PROJECT_ID}" --location="${REGION}" \
  --pi-and-jailbreak-filter-settings-enforcement=enabled \
  --pi-and-jailbreak-filter-settings-confidence-level="${MA_PI_CONFIDENCE}" \
  --template-metadata-custom-prompt-safety-error-code=403 \
  --template-metadata-custom-prompt-safety-error-message="cymbal-model-armor: request blocked by Model Armor (${MA_TEMPLATE})" \
  --template-metadata-custom-llm-response-safety-error-code=403 \
  --template-metadata-custom-llm-response-safety-error-message="cymbal-model-armor: response blocked by Model Armor (${MA_TEMPLATE})" \
  --template-metadata-log-sanitize-operations \
  --labels="demo=${PREFIX}"
fi

for role in roles/modelarmor.calloutUser roles/serviceusage.serviceUsageConsumer roles/modelarmor.user; do
  run gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${DEP_SA}" --role="${role}" --condition=None --quiet --format=none
done

if [[ "${DRY_RUN}" != "1" ]]; then
  gcloud model-armor templates describe "${MA_TEMPLATE}" --location="${REGION}" --project="${PROJECT_ID}" \
    --format="yaml(name,filterConfig,templateMetadata)"
fi

if [[ "${DO_TEST}" == "1" ]]; then
  banner "Test: sanitizeModelResponse with the CUST-666 bureau note"
  NOTE="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import server; print(server.INJECTION_NOTE)' "${REPO_DIR}/credit-bureau")"
  BODY="$(NOTE="${NOTE}" python3 -c 'import json,os; print(json.dumps({"modelResponseData":{"text":os.environ["NOTE"]}}))')"
  run curl -s -X POST -H "Authorization: Bearer $(access_token)" -H "Content-Type: application/json" \
    "https://modelarmor.${REGION}.rep.googleapis.com/v1/${MA_TEMPLATE_RESOURCE}:sanitizeModelResponse" -d "${BODY}"
  echo
  note "expect sanitizationResult.filterMatchState = MATCH_FOUND (pi_and_jailbreak)"
fi
ok "done"
