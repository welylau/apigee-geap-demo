# shellcheck shell=bash
# Fixed environment for the geap-apigee-demo infra scripts (Agent Gateway side).
# Sourced by every infra/NN-*.sh script and by credit-bureau/deploy.sh.
# Values come from docs/DESIGN.md ("Fixed environment"). Do not put secrets here.

# --- project / org --------------------------------------------------------
export PROJECT_ID="YOUR_PROJECT_ID"
export PROJECT_NUMBER="YOUR_PROJECT_NUMBER"
export ORG_ID="YOUR_ORG_ID"
export REGION="asia-southeast1"
export PREFIX="cymbal-ge-demo"

# --- gcloud / ADC isolation (never use ~/.config/gcloud-argolis) -----------
: "${CLOUDSDK_CONFIG:=${HOME}/.config/gcloud}"
if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "${HOME}/.config/gcloud/adc-${PROJECT_ID}.json" ]]; then
  GOOGLE_APPLICATION_CREDENTIALS="${HOME}/.config/gcloud/adc-${PROJECT_ID}.json"
fi
export CLOUDSDK_CONFIG GOOGLE_APPLICATION_CREDENTIALS
export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"
case "${CLOUDSDK_CONFIG}" in
  *gcloud-argolis*) echo "Refusing to run with CLOUDSDK_CONFIG=${CLOUDSDK_CONFIG}" >&2; exit 2 ;;
esac
# Model Armor gcloud commands need the regional endpoint (env override, so the
# user's gcloud config is not modified).
export CLOUDSDK_API_ENDPOINT_OVERRIDES_MODELARMOR="${CLOUDSDK_API_ENDPOINT_OVERRIDES_MODELARMOR:-https://modelarmor.${REGION}.rep.googleapis.com/}"  # set the .rep.mtls. form when gcloud uses certificate-based access

# --- Agent Gateway ----------------------------------------------------------
export AGW_NAME="${PREFIX}-agw"
export AGW_RESOURCE="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${AGW_NAME}"
export REGISTRY_PATH="//agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/${REGION}"
# Agent Gateway service agents (created by the platform on first use).
export DEP_SA="service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com"            # Service Extensions (Model Armor callouts)
export AGW_SA="service-${PROJECT_NUMBER}@gcp-sa-agentgateway.iam.gserviceaccount.com"   # validates DNS peering / network attachment
export AIPLATFORM_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com"  # fetches secret env vars at agent deploy

# IAP (identity / UAP) authorization: REQUEST_AUTHZ
export IAP_EXT_DRYRUN="${PREFIX}-iap-authz-dryrun"
export IAP_EXT_ENFORCED="${PREFIX}-iap-authz-enforced"
export IAP_POLICY="${PREFIX}-iap-policy"

# Model Armor: template + CONTENT_AUTHZ extension/policy
export MA_TEMPLATE="${PREFIX}-ma"
export MA_TEMPLATE_RESOURCE="projects/${PROJECT_ID}/locations/${REGION}/templates/${MA_TEMPLATE}"
# Model Armor confidence threshold for prompt-injection/jailbreak.
# HIGH = only high-likelihood content is flagged (as requested). If S3 does not
# trigger, lower it to MEDIUM_AND_ABOVE or LOW_AND_ABOVE (more sensitive).
export MA_PI_CONFIDENCE="${MA_PI_CONFIDENCE:-HIGH}"
export MA_EXT="${PREFIX}-ma-authz"
export MA_POLICY="${PREFIX}-ma-policy"

# Apigee extension processor: CONTENT_AUTHZ extension/policy over PSC
export APIGEE_EXT="${PREFIX}-apigee-authz"
export APIGEE_POLICY="${PREFIX}-apigee-policy"
export EXTPROC_PROXY="${PREFIX}-extproc"                  # no-target proxy name (built under apigee/)
export EXTPROC_ENV="${PREFIX}-extproc"                    # Apigee env (built by apigee/scripts owner)
export DNS_DOMAIN="${PREFIX}.internal"                    # no trailing dot
export EXTPROC_HOST="apigee-extproc.${DNS_DOMAIN}"        # == envgroup hostname == DNS A record == extension authority/service
export DNS_ZONE="${PREFIX}-internal"
export VPC_NETWORK="apigee-vpc-network"
export SUBNET="apigee-vpc-network"
export NETWORK_ATTACHMENT="${PREFIX}-agw-attach"
export PSC_ADDRESS="${PREFIX}-extproc-psc-ip"
export PSC_ENDPOINT="${PREFIX}-extproc-psc"

# --- Agent Registry entries --------------------------------------------------
export APIGEE_HOST="YOUR_APIGEE_HOST"
export MCP_BANKING_ID="${PREFIX}-mcp-banking"
export MCP_BANKING_URL="https://${APIGEE_HOST}/${PREFIX}/mcp/banking"
export LLM_ENDPOINT_ID="${PREFIX}-llm"
export LLM_ENDPOINT_URL="https://${APIGEE_HOST}/${PREFIX}/llm"
# Credit bureau: the agent calls it THROUGH an Apigee proxy (S5 quota in Apigee).
# The Cloud Run service is the Apigee proxy target; the agent never calls it directly.
export CREDIT_BUREAU_ID="${PREFIX}-credit-bureau"
export CREDIT_BUREAU_URL="https://${APIGEE_HOST}/${PREFIX}/bureau/mcp"
export CREDIT_BUREAU_SERVICE="${PREFIX}-credit-bureau"   # Cloud Run service (Apigee target backend)
# Optional ext-proc variant only (infra/06 --enable-extproc): direct Cloud Run registry entry.
export CREDIT_BUREAU_DIRECT_ID="${PREFIX}-credit-bureau-direct"
export PROTECTED_REGISTRY_ENTRIES="mcp-proxy-dev"         # apihub-synced, never touch

# --- UAP (IAM v3 access policy) -------------------------------------------
export TRUST_DOMAIN="agents.global.org-${ORG_ID}.system.id.goog"
export AGENT_PRINCIPAL_SET="principalSet://${TRUST_DOMAIN}/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"
export UAP_POLICY="${PREFIX}-agent-egress"
export UAP_BINDING="${PREFIX}-agent-egress-binding"

# --- Agent Runtime -----------------------------------------------------------
export AGENT_DISPLAY_NAME="${PREFIX}-rm-agent"
export AGENT_SECRET="${PREFIX}-agent-key"                 # x-api-key of the internal-agent Apigee app
export INSIGHTS_SECRET="${PREFIX}-insights-key"           # x-api-key of the Insights Agent Apigee app (scenario 7)
# Basic roles every gateway-bound AGENT_IDENTITY runtime needs to start (granted
# by 02c to AGENT_PRINCIPAL_SET). Without roles/browser the SDK cannot resolve the
# project at startup; without logging.logWriter the container writes no logs.
# See troubleshoot-agent-gateway.md "Errors during Agent Runtime startup".
export AGENT_IDENTITY_ROLES="roles/browser roles/serviceusage.serviceUsageConsumer roles/logging.logWriter roles/monitoring.metricWriter roles/agentregistry.viewer"

# --- local state (gitignored) ---------------------------------------------
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export INFRA_DIR
export REPO_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
export STATE_DIR="${INFRA_DIR}/.state"
export TEMPLATES_DIR="${INFRA_DIR}/templates"
