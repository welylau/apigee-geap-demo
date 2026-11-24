#!/usr/bin/env bash
# 03 - Agent Registry registrations in the gateway's regional registry
#      (//agentregistry.googleapis.com/projects/YOUR_PROJECT_ID/locations/asia-southeast1):
#   MCP server cymbal-ge-demo-mcp-banking   https://YOUR_APIGEE_HOST/cymbal-ge-demo/mcp/banking
#   MCP server cymbal-ge-demo-credit-bureau https://YOUR_APIGEE_HOST/cymbal-ge-demo/bureau/mcp
#              (Apigee proxy in front of the Cloud Run mock bureau - the agent never calls Cloud Run directly)
#   Endpoint   cymbal-ge-demo-llm           https://YOUR_APIGEE_HOST/cymbal-ge-demo/llm
# The apihub-synced entry 'mcp-proxy-dev' already lives in this registry and is
# never modified or deleted by these scripts.
# Writes the generated registryResource names to infra/.state/registry.env
# (04 uses them in UAP CEL conditions - they differ from the service ids).
# Ref: register-mcp-servers.md, register-endpoints.md, agent-gateway-runtime-deploy.md step 5.
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"

CB_URL="${CREDIT_BUREAU_URL}"
banner "03 Agent Registry (${REGION})"
plan "service ${MCP_BANKING_ID}: MCP server ${MCP_BANKING_URL} (toolspec: 5 banking tools)"
plan "service ${CREDIT_BUREAU_ID}: MCP server ${CB_URL} (toolspec: get_credit_report)"
plan "service ${LLM_ENDPOINT_ID}: endpoint ${LLM_ENDPOINT_URL} (no-spec)"
note "untouched: ${PROTECTED_REGISTRY_ENTRIES}"

register() {  # register <id> <display> <description> <kind:mcp|endpoint> <url> [toolspec]
  local id="$1" display="$2" desc="$3" kind="$4" url="$5" spec="${6:-}"
  case " ${PROTECTED_REGISTRY_ENTRIES} " in *" ${id} "*) die "refusing to touch protected entry ${id}";; esac
  if quiet gcloud agent-registry services describe "${id}" --location="${REGION}" --project="${PROJECT_ID}"; then
    local cur
    cur="$(gcloud agent-registry services describe "${id}" --location="${REGION}" --project="${PROJECT_ID}" \
           --format='value(interfaces[0].url)' 2>/dev/null || true)"
    if [[ "${cur}" == "${url}" ]]; then ok "${id} exists (${cur})"; return 0; fi
    warn "${id} exists with URL ${cur} != ${url}; delete it with 99-teardown.sh and re-run"
    return 0
  fi
  if [[ "${kind}" == "mcp" ]]; then
    run gcloud agent-registry services create "${id}" --project="${PROJECT_ID}" --location="${REGION}" \
      --display-name="${display}" --description="${desc}" \
      --mcp-server-spec-type=tool-spec --mcp-server-spec-content="${spec}" \
      --interfaces="url=${url},protocolBinding=JSONRPC"
  else
    run gcloud agent-registry services create "${id}" --project="${PROJECT_ID}" --location="${REGION}" \
      --display-name="${display}" --description="${desc}" \
      --endpoint-spec-type=no-spec \
      --interfaces="url=${url},protocolBinding=http-json"
  fi
}

register "${MCP_BANKING_ID}" "Cymbal Core Banking MCP (Apigee)" \
  "Apigee MCP proxy over core banking (accounts, payments)" mcp "${MCP_BANKING_URL}" \
  "${TEMPLATES_DIR}/toolspec-mcp-banking.json"
register "${CREDIT_BUREAU_ID}" "Cymbal Credit Bureau MCP (via Apigee)" \
  "Apigee proxy in front of the mock third-party credit bureau (quota 3 tools/call per 2 min)" mcp "${CB_URL}" \
  "${TEMPLATES_DIR}/toolspec-credit-bureau.json"
register "${LLM_ENDPOINT_ID}" "Cymbal LLM gateway (Apigee)" \
  "Apigee LLM gateway in front of Vertex Gemini (model alias cymbal-auto)" endpoint "${LLM_ENDPOINT_URL}"

if [[ "${DRY_RUN}" == "1" ]]; then
  note "dry-run: registry.env not written"
  exit 0
fi
MCP_BANKING_RESOURCE="$(registry_resource "${MCP_BANKING_ID}")"
CREDIT_BUREAU_RESOURCE="$(registry_resource "${CREDIT_BUREAU_ID}")"
LLM_ENDPOINT_RESOURCE="$(registry_resource "${LLM_ENDPOINT_ID}")"
for v in MCP_BANKING_RESOURCE CREDIT_BUREAU_RESOURCE LLM_ENDPOINT_RESOURCE; do
  [[ -n "${!v}" ]] || die "could not resolve registryResource for ${v} (still provisioning? re-run in a minute)"
done
KEEP="$(grep '^export CREDIT_BUREAU_DIRECT_RESOURCE=' "${STATE_DIR}/registry.env" 2>/dev/null || true)"
cat >"${STATE_DIR}/registry.env" <<EOF
export MCP_BANKING_RESOURCE="${MCP_BANKING_RESOURCE}"
export CREDIT_BUREAU_RESOURCE="${CREDIT_BUREAU_RESOURCE}"
export LLM_ENDPOINT_RESOURCE="${LLM_ENDPOINT_RESOURCE}"
export CREDIT_BUREAU_URL="${CB_URL}"
EOF
[[ -n "${KEEP}" ]] && echo "${KEEP}" >>"${STATE_DIR}/registry.env"
ok "wrote ${STATE_DIR#"${REPO_DIR}/"}/registry.env"
cat "${STATE_DIR}/registry.env"
gcloud agent-registry mcp-servers list --location="${REGION}" --project="${PROJECT_ID}" \
  --format="table(displayName,name.basename(),interfaces[0].url)" || true
gcloud agent-registry endpoints list --location="${REGION}" --project="${PROJECT_ID}" \
  --format="table(displayName,name.basename(),interfaces[0].url)" || true
