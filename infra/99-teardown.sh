#!/usr/bin/env bash
# 99 - Teardown, reverse order, y/N per step (use --yes to skip prompts,
#      --dry-run to only print). Never touches the apihub-synced registry entry
#      'mcp-proxy-dev', the Apigee instance, the VPC/subnet, or anything that is
#      not prefixed cymbal-ge-demo-.
# The agent itself is deleted only with --include-agent (it is normally
# removed via the console / agent tooling by the lead).
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"
INCLUDE_AGENT=0; for a in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do [[ "$a" == "--include-agent" ]] && INCLUDE_AGENT=1; done

banner "99 Teardown (${PREFIX}-*) in ${PROJECT_ID}/${REGION}"
step() {  # step "<description>" <exists-check...> -- <delete cmd...>
  local desc="$1"; shift
  local check=() del=()
  while [[ "$1" != "--" ]]; do check+=("$1"); shift; done; shift
  del=("$@")
  if ! quiet "${check[@]}"; then note "skip (not found): ${desc}"; return 0; fi
  if confirm "Delete ${desc}?"; then run "${del[@]}"; else note "kept: ${desc}"; fi
}
L=(--location="${REGION}" --project="${PROJECT_ID}")

# 06 - Apigee ext-proc (optional variant; skipped automatically if never created)
step "authz policy ${APIGEE_POLICY}" gcloud network-security authz-policies describe "${APIGEE_POLICY}" "${L[@]}" -- \
  gcloud network-security authz-policies delete "${APIGEE_POLICY}" "${L[@]}" --quiet
step "authz extension ${APIGEE_EXT}" gcloud service-extensions authz-extensions describe "${APIGEE_EXT}" "${L[@]}" -- \
  gcloud service-extensions authz-extensions delete "${APIGEE_EXT}" "${L[@]}" --quiet
# 05 - Model Armor authz
step "authz policy ${MA_POLICY}" gcloud network-security authz-policies describe "${MA_POLICY}" "${L[@]}" -- \
  gcloud network-security authz-policies delete "${MA_POLICY}" "${L[@]}" --quiet
step "authz extension ${MA_EXT}" gcloud service-extensions authz-extensions describe "${MA_EXT}" "${L[@]}" -- \
  gcloud service-extensions authz-extensions delete "${MA_EXT}" "${L[@]}" --quiet
# 04 - UAP
step "UAP binding ${UAP_BINDING}" gcloud iam policy-bindings describe "${UAP_BINDING}" --location=global --project="${PROJECT_ID}" -- \
  gcloud iam policy-bindings delete "${UAP_BINDING}" --location=global --project="${PROJECT_ID}" --quiet
step "UAP ${UAP_POLICY}" gcloud iam access-policies describe "${UAP_POLICY}" --location=global --project="${PROJECT_ID}" -- \
  gcloud iam access-policies delete "${UAP_POLICY}" --location=global --project="${PROJECT_ID}" --quiet
# 08 - BigQuery demo data (scenario 8). Deleting the datasets also drops their table IAM grants.
for ds in cymbal_kyc cymbal_hr; do
  step "BigQuery dataset ${ds} (scenario 8 demo data)" bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:${ds}" -- \
    bq --project_id="${PROJECT_ID}" rm -r -f --dataset "${PROJECT_ID}:${ds}"
done
RM_PRINCIPAL="$(agent_principal)"
if [[ "${RM_PRINCIPAL}" == principal://* ]] && project_has_binding "${RM_PRINCIPAL}" roles/bigquery.jobUser \
   && confirm "Remove roles/bigquery.jobUser from the RM Agent principal?"; then
  run gcloud projects remove-iam-policy-binding "${PROJECT_ID}" --member="${RM_PRINCIPAL}" \
    --role=roles/bigquery.jobUser --condition=None --quiet --format=none
fi
# Agents (must be unbound/deleted before the gateway can be deleted)
if [[ "${INCLUDE_AGENT}" == "1" ]]; then
  ENGINE="$(agent_engine_id)"
  if [[ -n "${ENGINE}" ]] && confirm "Delete reasoning engine ${ENGINE} (${AGENT_DISPLAY_NAME})?"; then
    run curl -s -X DELETE -H "Authorization: Bearer $(access_token)" \
      "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${ENGINE}?force=true"
    echo
  fi
  INS_FILE="${REPO_DIR}/agent/.deployed-insights.json"
  INS_ENGINE="$( [[ -f "${INS_FILE}" ]] && python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("engine_id",""))' "${INS_FILE}" || true)"
  if [[ -n "${INS_ENGINE}" ]] && confirm "Delete reasoning engine ${INS_ENGINE} (Insights Agent, scenario 7)?"; then
    run curl -s -X DELETE -H "Authorization: Bearer $(access_token)" \
      "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${INS_ENGINE}?force=true"
    echo
  fi
else
  note "agent not deleted (pass --include-agent); a gateway with bound agents may refuse deletion"
fi
# 03 - registry (only our three ids)
for id in "${LLM_ENDPOINT_ID}" "${CREDIT_BUREAU_DIRECT_ID}" "${CREDIT_BUREAU_ID}" "${MCP_BANKING_ID}"; do
  case " ${PROTECTED_REGISTRY_ENTRIES} " in *" ${id} "*) die "protected: ${id}";; esac
  step "registry service ${id}" gcloud agent-registry services describe "${id}" "${L[@]}" -- \
    gcloud agent-registry services delete "${id}" "${L[@]}" --quiet
done
# 02 - IAP policy/extensions + gateway
step "authz policy ${IAP_POLICY}" gcloud network-security authz-policies describe "${IAP_POLICY}" "${L[@]}" -- \
  gcloud network-security authz-policies delete "${IAP_POLICY}" "${L[@]}" --quiet
for ext in "${IAP_EXT_ENFORCED}" "${IAP_EXT_DRYRUN}"; do
  step "authz extension ${ext}" gcloud service-extensions authz-extensions describe "${ext}" "${L[@]}" -- \
    gcloud service-extensions authz-extensions delete "${ext}" "${L[@]}" --quiet
done
step "agent gateway ${AGW_NAME}" gcloud network-services agent-gateways describe "${AGW_NAME}" "${L[@]}" -- \
  gcloud network-services agent-gateways delete "${AGW_NAME}" "${L[@]}" --quiet
# 06 - network pieces (after the gateway releases the attachment)
step "DNS A ${EXTPROC_HOST}" gcloud dns record-sets describe "${EXTPROC_HOST}." --type=A --zone="${DNS_ZONE}" --project="${PROJECT_ID}" -- \
  gcloud dns record-sets delete "${EXTPROC_HOST}." --type=A --zone="${DNS_ZONE}" --project="${PROJECT_ID}" --quiet
step "DNS zone ${DNS_ZONE}" gcloud dns managed-zones describe "${DNS_ZONE}" --project="${PROJECT_ID}" -- \
  gcloud dns managed-zones delete "${DNS_ZONE}" --project="${PROJECT_ID}" --quiet
step "PSC endpoint ${PSC_ENDPOINT}" gcloud compute forwarding-rules describe "${PSC_ENDPOINT}" --region="${REGION}" --project="${PROJECT_ID}" -- \
  gcloud compute forwarding-rules delete "${PSC_ENDPOINT}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
step "address ${PSC_ADDRESS}" gcloud compute addresses describe "${PSC_ADDRESS}" --region="${REGION}" --project="${PROJECT_ID}" -- \
  gcloud compute addresses delete "${PSC_ADDRESS}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
step "network attachment ${NETWORK_ATTACHMENT}" gcloud compute network-attachments describe "${NETWORK_ATTACHMENT}" --region="${REGION}" --project="${PROJECT_ID}" -- \
  gcloud compute network-attachments delete "${NETWORK_ATTACHMENT}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
# 01 - Model Armor template
step "Model Armor template ${MA_TEMPLATE}" gcloud model-armor templates describe "${MA_TEMPLATE}" "${L[@]}" -- \
  gcloud model-armor templates delete "${MA_TEMPLATE}" "${L[@]}" --quiet
# credit bureau
step "Cloud Run service ${CREDIT_BUREAU_SERVICE}" gcloud run services describe "${CREDIT_BUREAU_SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" -- \
  gcloud run services delete "${CREDIT_BUREAU_SERVICE}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
# 02c - agent identity basic roles: remove ONLY the exact unconditional
# (AGENT_PRINCIPAL_SET, role) bindings from AGENT_IDENTITY_ROLES, y/N each.
# NOTE: the member is "all agents in this project", so other agents in
# YOUR_PROJECT_ID may rely on these too - answer N if unsure.
for role in ${AGENT_IDENTITY_ROLES}; do
  if ! project_has_binding "${AGENT_PRINCIPAL_SET}" "${role}"; then
    note "skip (not found): ${role} on agent principal set"; continue
  fi
  if confirm "Remove ${role} from the project agent principal set (affects ALL agents in ${PROJECT_ID})?"; then
    run gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
      --member="${AGENT_PRINCIPAL_SET}" --role="${role}" --condition=None --quiet --format=none
  else
    note "kept: ${role} on agent principal set"
  fi
done
# 02c - secret-scoped accessor for the agent principal set (exact binding only).
# The service-agent accessor on the secret is left in place (shared, harmless).
if quiet gcloud secrets describe "${AGENT_SECRET}" --project="${PROJECT_ID}" \
   && secret_has_binding "${AGENT_SECRET}" "${AGENT_PRINCIPAL_SET}" "roles/secretmanager.secretAccessor"; then
  if confirm "Remove roles/secretmanager.secretAccessor on secret ${AGENT_SECRET} from the agent principal set?"; then
    run gcloud secrets remove-iam-policy-binding "${AGENT_SECRET}" --project="${PROJECT_ID}" \
      --member="${AGENT_PRINCIPAL_SET}" --role="roles/secretmanager.secretAccessor" --condition=None --quiet --format=none
  else
    note "kept: secretAccessor on ${AGENT_SECRET} for agent principal set"
  fi
else
  note "skip (not found): secretAccessor on ${AGENT_SECRET} for agent principal set"
fi
note "IAM role grants to service agents (gcp-sa-dep, gcp-sa-agentgateway) are left in place (harmless, shared)."
rm -f "${STATE_DIR}/registry.env"
ok "teardown finished"
