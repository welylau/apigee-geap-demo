#!/usr/bin/env bash
# 04 - IAM Unified Access Policy (UAP, IAP policy version V2) + project binding.
# The RM Agent's identity may egress ONLY to:
#   1. MCP server cymbal-ge-demo-mcp-banking   (registered)
#   2. MCP server cymbal-ge-demo-credit-bureau (registered)
#   3. Endpoint   cymbal-ge-demo-llm           (registered)
#   4. bigquery.googleapis.com (scenario 8; the data itself is then decided by IAM)
#   5. the essential Agent Platform hosts for asia-southeast1 - exact list from
#      agent-gateway-runtime-deploy.md "Allowlist essential APIs" (unregistered
#      host allowlist form, no wildcards).
# Everything else (e.g. https://webhook.site, scenario S2) hits the gateway's
# default deny. No blanket DENY rule (it would override the allows and block
# telemetry - configure-iam-policies-uap.md caution).
# Principal: the deployed reasoning engine (agent/.deployed.json) if present,
# otherwise every Agent Runtime agent in project YOUR_PROJECT_NUMBER (principal set).
# Re-run after agent/deploy.py to narrow the policy to the single agent.
# Ref: configure-iam-policies-uap.md, agent-gateway-runtime-deploy.md steps 5-6.
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"

banner "04 UAP ${UAP_POLICY} + binding ${UAP_BINDING}"
AGENT_PRINCIPAL="$(agent_principal)"; export AGENT_PRINCIPAL
if [[ -f "${STATE_DIR}/registry.env" ]]; then
  # shellcheck source=/dev/null
  source "${STATE_DIR}/registry.env"
else
  MCP_BANKING_RESOURCE="$(registry_resource "${MCP_BANKING_ID}")"
  CREDIT_BUREAU_RESOURCE="$(registry_resource "${CREDIT_BUREAU_ID}")"
  LLM_ENDPOINT_RESOURCE="$(registry_resource "${LLM_ENDPOINT_ID}")"
fi
if [[ "${DRY_RUN}" == "1" ]]; then
  : "${MCP_BANKING_RESOURCE:=projects/${PROJECT_ID}/locations/${REGION}/mcpServers/PENDING-${MCP_BANKING_ID}}"
  : "${CREDIT_BUREAU_RESOURCE:=projects/${PROJECT_ID}/locations/${REGION}/mcpServers/PENDING-${CREDIT_BUREAU_ID}}"
  : "${LLM_ENDPOINT_RESOURCE:=projects/${PROJECT_ID}/locations/${REGION}/endpoints/PENDING-${LLM_ENDPOINT_ID}}"
fi
for v in MCP_BANKING_RESOURCE CREDIT_BUREAU_RESOURCE LLM_ENDPOINT_RESOURCE; do
  [[ -n "${!v:-}" ]] || die "${v} unknown - run 03-registry.sh first"
done
export MCP_BANKING_RESOURCE CREDIT_BUREAU_RESOURCE LLM_ENDPOINT_RESOURCE
# Registry names come back with the project NUMBER, while the docs' UAP examples use the project ID.
# Match both forms so the rule holds whichever one IAP evaluates (seen live: number-only rules were DENIED).
alt_name() { local r="$1"; if [[ "$r" == "projects/${PROJECT_NUMBER}/"* ]]; then echo "projects/${PROJECT_ID}/${r#projects/${PROJECT_NUMBER}/}"; else echo "projects/${PROJECT_NUMBER}/${r#projects/${PROJECT_ID}/}"; fi; }
MCP_BANKING_RESOURCE_ALT="$(alt_name "${MCP_BANKING_RESOURCE}")"
CREDIT_BUREAU_RESOURCE_ALT="$(alt_name "${CREDIT_BUREAU_RESOURCE}")"
LLM_ENDPOINT_RESOURCE_ALT="$(alt_name "${LLM_ENDPOINT_RESOURCE}")"
export MCP_BANKING_RESOURCE_ALT CREDIT_BUREAU_RESOURCE_ALT LLM_ENDPOINT_RESOURCE_ALT

plan "principal: ${AGENT_PRINCIPAL}"
plan "allow -> ${MCP_BANKING_RESOURCE}"
plan "allow -> ${CREDIT_BUREAU_RESOURCE}"
plan "allow -> ${LLM_ENDPOINT_RESOURCE}"
plan "allow -> 20 essential platform hosts (unregistered allowlist, ${REGION})"
plan "binding ${UAP_BINDING}: //cloudresourcemanager.googleapis.com/projects/${PROJECT_ID}"

RULES="${STATE_DIR}/rendered/uap-agent-egress.json"
render "${TEMPLATES_DIR}/uap-agent-egress.json" "${RULES}"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${RULES}" || die "rendered UAP is not valid JSON"
if [[ -n "${CREDIT_BUREAU_DIRECT_RESOURCE:-}" ]]; then
  # Optional ext-proc variant (06 --enable-extproc): also allow the direct Cloud Run bureau entry.
  plan "allow -> ${CREDIT_BUREAU_DIRECT_RESOURCE} (optional ext-proc variant)"
  python3 -c '
import json, sys
rules = json.load(open(sys.argv[1]))
rule = dict(rules[1])
rule["description"] = "RM Agent -> Credit Bureau MCP DIRECT (optional ext-proc variant)"
rule["conditions"] = {"iap.googleapis.com": {"expression": "destination.is_registered == true && destination.agent_registry.mcp_server.name == %r" % sys.argv[2]}}
rules.insert(2, rule)
json.dump(rules, open(sys.argv[1], "w"), indent=1)
' "${RULES}" "${CREDIT_BUREAU_DIRECT_RESOURCE}"
fi

# Scenario 7: the Insights Agent is a SECOND Agent Identity. It gets the LLM gateway + platform hosts
# only - no banking MCP, no bureau, no BigQuery - so its get_account_balance call hits the default deny.
INSIGHTS_PRINCIPAL="$(insights_principal)"
if [[ -n "${INSIGHTS_PRINCIPAL}" ]]; then
  plan "Insights Agent ${INSIGHTS_PRINCIPAL}: LLM endpoint + essential hosts only"
  python3 -c '
import copy, json, sys
path, who = sys.argv[1], sys.argv[2]
rules = json.load(open(path))
extra = []
for r in rules:
    d = r["description"]
    if "LLM gateway" in d or "essential Agent Platform hosts" in d:
        c = copy.deepcopy(r)
        c["principals"] = [who]
        c["description"] = d.replace("RM Agent", "Insights Agent")
        extra.append(c)
json.dump(rules + extra, open(path, "w"), indent=1)
' "${RULES}" "${INSIGHTS_PRINCIPAL}"
else
  note "Insights Agent not deployed (agent/.deployed-insights.json): no rules for it"
fi

if quiet gcloud iam access-policies describe "${UAP_POLICY}" --project="${PROJECT_ID}" --location=global; then
  note "policy exists -> updating rules"
  run gcloud iam access-policies update "${UAP_POLICY}" --project="${PROJECT_ID}" --location=global \
    --details-rules="${RULES}" --display-name="Cymbal RM Agent egress allowlist"
else
  run gcloud iam access-policies create "${UAP_POLICY}" --project="${PROJECT_ID}" --location=global \
    --details-rules="${RULES}" --display-name="Cymbal RM Agent egress allowlist"
fi

if quiet gcloud iam policy-bindings describe "${UAP_BINDING}" --project="${PROJECT_ID}" --location=global; then
  ok "binding ${UAP_BINDING} exists"
else
  run gcloud iam policy-bindings create "${UAP_BINDING}" --project="${PROJECT_ID}" --location=global \
    --policy-kind=ACCESS \
    --policy="projects/${PROJECT_ID}/locations/global/accessPolicies/${UAP_POLICY}" \
    --target-resource="//cloudresourcemanager.googleapis.com/projects/${PROJECT_ID}"
fi
note "If the binding fails with FAILED_PRECONDITION, see 07-org-policy-check.sh (iam.managed.disableAccessPolicyBindings)"
ok "done"
