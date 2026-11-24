#!/usr/bin/env bash
# 06 - Apigee extension processor as an Agent Gateway authorization extension
#      (extension-processor-agent-gateway.md, step by step):
#   a. network attachment  cymbal-ge-demo-agw-attach (apigee-vpc-network / apigee-vpc-network, ACCEPT_AUTOMATIC)
#   b. PSC endpoint        cymbal-ge-demo-extproc-psc (+ address cymbal-ge-demo-extproc-psc-ip)
#                          -> Apigee instance service attachment (GET /instances)
#   c. private DNS zone    cymbal-ge-demo-internal  (cymbal-ge-demo.internal.)
#                          A apigee-extproc.cymbal-ge-demo.internal -> PSC IP
#   d. gateway networkConfig via EXPORT -> EDIT -> IMPORT (never a blind overwrite)
#   e. authz extension     cymbal-ge-demo-apigee-authz (apigee-extension-processor: cymbal-ge-demo-extproc)
#   f. CONTENT_AUTHZ policy cymbal-ge-demo-apigee-policy scoped to the Credit Bureau host only
# Prerequisite (owned by apigee/ + scripts/): Apigee env cymbal-ge-demo-extproc
# (apigee-service-extension-enabled=true) attached to the instance, envgroup
# hostname apigee-extproc.cymbal-ge-demo.internal, no-target proxy deployed.
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"

# OPTIONAL VARIANT - not part of the default order. The default S5 puts the
# credit bureau behind a normal Apigee proxy (/cymbal-ge-demo/bureau/mcp), because
# the Apigee org is at its environment limit (no dedicated ext-proc env).
# This script only runs with an explicit --enable-extproc. The variant also needs:
#   agent/deploy.py --direct-bureau   (agent calls the Cloud Run bureau directly)
#   re-run infra/04-uap.sh            (adds the direct-bureau allow rule)
ENABLE=0; for a in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do [[ "$a" == "--enable-extproc" ]] && ENABLE=1; done
if [[ "${ENABLE}" != "1" ]]; then
  note "06 is the OPTIONAL Apigee ext-proc variant and is skipped by default."
  note "Run with --enable-extproc (plus --dry-run to preview) only if an Apigee ext-proc env exists."
  exit 0
fi

CREDIT_BUREAU_DIRECT_URL="$(credit_bureau_url)"
CREDIT_BUREAU_HOST="$(host_of "${CREDIT_BUREAU_DIRECT_URL}")"; export CREDIT_BUREAU_HOST
NA_RESOURCE="projects/${PROJECT_ID}/regions/${REGION}/networkAttachments/${NETWORK_ATTACHMENT}"
NET_RESOURCE="projects/${PROJECT_ID}/global/networks/${VPC_NETWORK}"
banner "06 (optional) Apigee ext-proc connectivity + authz (${APIGEE_EXT})"

# --- direct Cloud Run bureau registry entry (variant only) ---------------------
plan "registry service ${CREDIT_BUREAU_DIRECT_ID}: MCP server ${CREDIT_BUREAU_DIRECT_URL}"
if quiet gcloud agent-registry services describe "${CREDIT_BUREAU_DIRECT_ID}" --location="${REGION}" --project="${PROJECT_ID}"; then
  ok "${CREDIT_BUREAU_DIRECT_ID} exists"
else
  run gcloud agent-registry services create "${CREDIT_BUREAU_DIRECT_ID}" --project="${PROJECT_ID}" --location="${REGION}" \
    --display-name="Cymbal Credit Bureau MCP (direct, ext-proc variant)" \
    --description="Mock third-party bureau called directly; metered by the Apigee extension processor" \
    --mcp-server-spec-type=tool-spec --mcp-server-spec-content="${TEMPLATES_DIR}/toolspec-credit-bureau.json" \
    --interfaces="url=${CREDIT_BUREAU_DIRECT_URL},protocolBinding=JSONRPC"
fi
if [[ "${DRY_RUN}" != "1" ]]; then
  r="$(registry_resource "${CREDIT_BUREAU_DIRECT_ID}")"
  if [[ -n "${r}" ]]; then
    touch "${STATE_DIR}/registry.env"
    grep -v '^export CREDIT_BUREAU_DIRECT_RESOURCE=' "${STATE_DIR}/registry.env" >"${STATE_DIR}/registry.env.tmp" || true
    echo "export CREDIT_BUREAU_DIRECT_RESOURCE=\"${r}\"" >>"${STATE_DIR}/registry.env.tmp"
    mv "${STATE_DIR}/registry.env.tmp" "${STATE_DIR}/registry.env"
    note "re-run infra/04-uap.sh to allow ${r}"
  fi
fi

# --- prerequisites (read-only) ------------------------------------------------
APIGEE_TOKEN="$(gcloud auth application-default print-access-token 2>/dev/null || true)"
SERVICE_ATTACHMENT="$(curl -s -H "Authorization: Bearer ${APIGEE_TOKEN}" \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/instances" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(next((i.get("serviceAttachment","") for i in d.get("instances",[]) if i.get("location")==sys.argv[1]),""))' "${REGION}" 2>/dev/null || true)"
[[ -n "${SERVICE_ATTACHMENT}" ]] || die "could not read the Apigee instance service attachment (ADC token / org access?)"
note "Apigee service attachment: ${SERVICE_ATTACHMENT}"
envgroup_hosts="$(curl -s -H "Authorization: Bearer ${APIGEE_TOKEN}" \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/envgroups" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(" ".join(h for g in d.get("environmentGroups",[]) for h in g.get("hostnames",[])))' 2>/dev/null || true)"
if grep -qw "${EXTPROC_HOST}" <<<"${envgroup_hosts}"; then ok "envgroup hostname ${EXTPROC_HOST} exists"
else warn "no Apigee envgroup has hostname ${EXTPROC_HOST} yet (apigee/scripts owner must create it)"; fi

plan "network attachment ${NA_RESOURCE} (subnet ${SUBNET}, ACCEPT_AUTOMATIC)"
plan "address ${PSC_ADDRESS} + forwarding rule ${PSC_ENDPOINT} -> ${SERVICE_ATTACHMENT}"
plan "private zone ${DNS_ZONE} (${DNS_DOMAIN}.) on ${VPC_NETWORK}; A ${EXTPROC_HOST}. -> PSC IP"
plan "IAM: ${AGW_SA} -> roles/compute.networkViewer, roles/dns.reader (DNS peering validation)"
plan "gateway ${AGW_NAME}: add networkConfig {egress.networkAttachment, dnsPeeringConfig ${DNS_DOMAIN}.}"
plan "authzExtension ${APIGEE_EXT} -> ${EXTPROC_HOST} (proxy ${EXTPROC_PROXY}); authzPolicy ${APIGEE_POLICY} (CONTENT_AUTHZ, host ${CREDIT_BUREAU_HOST})"

# --- a. network attachment ----------------------------------------------------
if quiet gcloud compute network-attachments describe "${NETWORK_ATTACHMENT}" --region="${REGION}" --project="${PROJECT_ID}"; then
  ok "network attachment exists"
else
  run gcloud compute network-attachments create "${NETWORK_ATTACHMENT}" --project="${PROJECT_ID}" \
    --region="${REGION}" --subnets="${SUBNET}" --connection-preference=ACCEPT_AUTOMATIC \
    --description="Agent Gateway ${AGW_NAME} egress into ${VPC_NETWORK} (Apigee ext-proc callout)"
fi

# --- b. PSC endpoint ----------------------------------------------------------
if quiet gcloud compute addresses describe "${PSC_ADDRESS}" --region="${REGION}" --project="${PROJECT_ID}"; then
  ok "address ${PSC_ADDRESS} exists"
else
  run gcloud compute addresses create "${PSC_ADDRESS}" --project="${PROJECT_ID}" \
    --region="${REGION}" --subnet="${SUBNET}" --purpose=GCE_ENDPOINT
fi
if quiet gcloud compute forwarding-rules describe "${PSC_ENDPOINT}" --region="${REGION}" --project="${PROJECT_ID}"; then
  ok "forwarding rule ${PSC_ENDPOINT} exists"
else
  run gcloud compute forwarding-rules create "${PSC_ENDPOINT}" --project="${PROJECT_ID}" \
    --region="${REGION}" --network="${VPC_NETWORK}" --address="${PSC_ADDRESS}" \
    --target-service-attachment="${SERVICE_ATTACHMENT}"
fi
PSC_IP="$(gcloud compute forwarding-rules describe "${PSC_ENDPOINT}" --region="${REGION}" --project="${PROJECT_ID}" \
          --format='value(IPAddress)' 2>/dev/null || true)"
PSC_STATUS="$(gcloud compute forwarding-rules describe "${PSC_ENDPOINT}" --region="${REGION}" --project="${PROJECT_ID}" \
          --format='value(pscConnectionStatus)' 2>/dev/null || true)"
if [[ "${DRY_RUN}" == "1" && -z "${PSC_IP}" ]]; then PSC_IP="<psc-ip>"; fi
note "PSC endpoint IP=${PSC_IP:-?} status=${PSC_STATUS:-?} (must be ACCEPTED)"
[[ "${DRY_RUN}" == "1" || "${PSC_STATUS}" == "ACCEPTED" ]] || warn "PSC status is not ACCEPTED - is ${PROJECT_ID} in the instance consumerAcceptList?"

# --- c. private DNS -----------------------------------------------------------
if quiet gcloud dns managed-zones describe "${DNS_ZONE}" --project="${PROJECT_ID}"; then
  ok "zone ${DNS_ZONE} exists"
else
  run gcloud dns managed-zones create "${DNS_ZONE}" --project="${PROJECT_ID}" \
    --dns-name="${DNS_DOMAIN}." --visibility=private --networks="${VPC_NETWORK}" \
    --description="Apigee extension processor callout host (${PREFIX})"
fi
if quiet gcloud dns record-sets describe "${EXTPROC_HOST}." --type=A --zone="${DNS_ZONE}" --project="${PROJECT_ID}"; then
  ok "A record ${EXTPROC_HOST} exists"
else
  run gcloud dns record-sets create "${EXTPROC_HOST}." --project="${PROJECT_ID}" \
    --type=A --ttl=300 --rrdatas="${PSC_IP}" --zone="${DNS_ZONE}"
fi

# Agent Gateway service agent validates DNS peering + attachment subnet.
for role in roles/compute.networkViewer roles/dns.reader; do
  run gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${AGW_SA}" --role="${role}" --condition=None --quiet --format=none
done

# --- d. gateway networkConfig: export -> edit -> import ------------------------
EXPORT="${STATE_DIR}/agent-gateway.export.yaml"
EDITED="${STATE_DIR}/agent-gateway.edited.yaml"
if [[ "${DRY_RUN}" == "1" ]] && ! quiet gcloud network-services agent-gateways describe "${AGW_NAME}" --location="${REGION}" --project="${PROJECT_ID}"; then
  note "dry-run: gateway not found; would export it, append networkConfig, re-import"
else
  gcloud network-services agent-gateways export "${AGW_NAME}" --location="${REGION}" \
    --project="${PROJECT_ID}" --destination="${EXPORT}"
  cp "${EXPORT}" "${STATE_DIR}/agent-gateway.backup.$(date +%Y%m%d%H%M%S).yaml"
  if grep -q '^networkConfig:' "${EXPORT}"; then
    if grep -q "${NETWORK_ATTACHMENT}" "${EXPORT}" && grep -q "${DNS_DOMAIN}\." "${EXPORT}"; then
      ok "gateway already has the expected networkConfig"
    else
      die "gateway has a DIFFERENT networkConfig (networkAttachment is immutable). Inspect ${EXPORT}; not changing it."
    fi
  else
    grep -q '^googleManaged:' "${EXPORT}" && grep -q '^registries:' "${EXPORT}" \
      || die "export lacks googleManaged/registries - refusing to import a partial resource"
    cp "${EXPORT}" "${EDITED}"
    cat >>"${EDITED}" <<EOF
networkConfig:
  egress:
    networkAttachment: ${NA_RESOURCE}
  dnsPeeringConfig:
    domains: [ ${DNS_DOMAIN}. ]
    targetProject: ${PROJECT_ID}
    targetNetwork: ${NET_RESOURCE}
EOF
    note "diff (export -> edited):"
    diff "${EXPORT}" "${EDITED}" || true
    run gcloud network-services agent-gateways import "${AGW_NAME}" --location="${REGION}" \
      --project="${PROJECT_ID}" --source="${EDITED}" --quiet
  fi
fi

# --- e/f. authz extension + CONTENT_AUTHZ policy -------------------------------
R="${STATE_DIR}/rendered"
render "${TEMPLATES_DIR}/apigee-authz-extension.yaml" "${R}/apigee-authz-extension.yaml"
render "${TEMPLATES_DIR}/apigee-authz-policy.yaml" "${R}/apigee-authz-policy.yaml"
if quiet gcloud service-extensions authz-extensions describe "${APIGEE_EXT}" --location="${REGION}" --project="${PROJECT_ID}"; then
  ok "authz extension ${APIGEE_EXT} exists"
else
  run gcloud service-extensions authz-extensions import "${APIGEE_EXT}" \
    --source="${R}/apigee-authz-extension.yaml" --location="${REGION}" --project="${PROJECT_ID}" --quiet
fi
run gcloud beta network-security authz-policies import "${APIGEE_POLICY}" \
  --source="${R}/apigee-authz-policy.yaml" --location="${REGION}" --project="${PROJECT_ID}" --quiet
ok "done - verify with an Apigee debug session on ${EXTPROC_PROXY} in env ${EXTPROC_ENV} while running S5"
