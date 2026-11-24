#!/usr/bin/env bash
# ==============================================================================
# Deploys the Agents Meet APIs: Gemini Enterprise Agent Platform × Apigee web UI to Cloud Run behind IAP, with a custom domain.
# Idempotent: safe to re-run after code changes. Based on the SDP demo script.
#
#   ./deploy-cloudrun.sh                               # house defaults
#   DOMAIN=none IAP_MEMBERS=user:me@example.com ./deploy-cloudrun.sh
#
# Secrets (created by ../scripts/setup-apigee.sh, never printed, never baked into the image):
#   cymbal-ge-demo-webui-key    -> API_KEY          (identity facade: demo user JWTs)
#   cymbal-ge-demo-partner-key  -> PARTNER_API_KEY  (S7 FinPal partner calls)
# Agent: AGENT_ENGINE_ID env, or read from ../agent/.deployed.json (written by agent/deploy.py).
# ==============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
REGION="${REGION:-asia-southeast1}"
APIGEE_HOST="${APIGEE_HOST:-YOUR_APIGEE_HOST}"
SERVICE="${SERVICE:-cymbal-ge-demo-ui}"
DOMAIN="${DOMAIN:-YOUR_UI_DOMAIN}"               # DOMAIN=none to skip mapping + DNS
DNS_ZONE="${DNS_ZONE:-YOUR_DNS_ZONE}"
IAP_MEMBERS="${IAP_MEMBERS:-domain:google.com}"       # comma list: user:a@x.com,group:g@x.com
WEBUI_SECRET="${WEBUI_SECRET:-cymbal-ge-demo-webui-key}"
PARTNER_SECRET="${PARTNER_SECRET:-cymbal-ge-demo-partner-key}"
AGENT_ENGINE_ID="${AGENT_ENGINE_ID:-}"
INSIGHTS_ENGINE_ID="${INSIGHTS_ENGINE_ID:-}"   # scenario 7 (optional; from ../agent/.deployed-insights.json)

APIGEE_HOST="${APIGEE_HOST#https://}"; APIGEE_HOST="${APIGEE_HOST%/}"
[ "$DOMAIN" = "none" ] && DOMAIN=""
SA_NAME="$(printf '%s' "${SERVICE}" | cut -c1-30 | sed 's/-*$//')"   # SA id: 6-30 chars, no trailing '-'
SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Refuse to deploy a sanitized (placeholder) tree: run ./restore.sh first.
if [ -f "$ROOT/.sanitize.state" ] && grep -q sanitized "$ROOT/.sanitize.state"; then
  echo "❌ Repo is sanitized (YOUR_* placeholders). Run ./restore.sh before deploying." >&2; exit 1
fi
[ -d "$DIR/static" ] || { echo "❌ $DIR/static is missing" >&2; exit 1; }

if [ -z "$AGENT_ENGINE_ID" ] && [ -f "$ROOT/agent/.deployed.json" ]; then
  AGENT_ENGINE_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(str(d.get("name") or d.get("resource_name","")).rsplit("/",1)[-1])' "$ROOT/agent/.deployed.json")"
fi
[ -n "$AGENT_ENGINE_ID" ] || { echo "❌ AGENT_ENGINE_ID unknown: deploy the agent first (agent/deploy.py)" >&2; exit 1; }
if [ -z "$INSIGHTS_ENGINE_ID" ] && [ -f "$ROOT/agent/.deployed-insights.json" ]; then
  INSIGHTS_ENGINE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("engine_id",""))' "$ROOT/agent/.deployed-insights.json")"
fi
[ -n "$INSIGHTS_ENGINE_ID" ] || echo "⚠️  INSIGHTS_ENGINE_ID unknown: scenario 7 will report 'not deployed'"

g() { gcloud --project="$PROJECT_ID" --quiet "$@"; }
PROJECT_NUMBER=$(g projects describe "$PROJECT_ID" --format='value(projectNumber)')

echo "▶ APIs"
g services enable run.googleapis.com iap.googleapis.com secretmanager.googleapis.com \
  cloudbuild.googleapis.com artifactregistry.googleapis.com logging.googleapis.com aiplatform.googleapis.com >/dev/null

echo "▶ Runtime service account: $SA"
g iam service-accounts describe "$SA" >/dev/null 2>&1 || \
  g iam service-accounts create "$SA_NAME" --display-name="Agents Meet APIs UI (Cloud Run)"
# Query the RM Agent on Agent Runtime (sessions + streamQuery).
g projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA" \
  --role=roles/aiplatform.user --condition=None >/dev/null

echo "▶ Secrets: $WEBUI_SECRET, $PARTNER_SECRET (must already exist)"
for s in "$WEBUI_SECRET" "$PARTNER_SECRET"; do
  g secrets versions describe latest --secret="$s" >/dev/null 2>&1 || {
    echo "❌ secret $s has no version: run ../scripts/setup-apigee.sh first" >&2; exit 1; }
  g secrets add-iam-policy-binding "$s" --member="serviceAccount:$SA" \
    --role=roles/secretmanager.secretAccessor >/dev/null
done

echo "▶ Build context (only server.py, static/, Dockerfile: .env never leaves the machine)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
cp "$DIR/Dockerfile" "$DIR/server.py" "$DIR/.dockerignore" "$BUILD/"
cp -R "$DIR/static" "$BUILD/static"

echo "▶ Cloud Run deploy (source build) with IAP"
# max-instances=1: the demo audit store (audit_logs.json) lives in the instance.
# timeout=300: one agent run can take ~1-2 min (several tool + model calls).
g run deploy "$SERVICE" --source="$BUILD" --region="$REGION" \
  --service-account="$SA" --no-allow-unauthenticated --iap \
  --set-secrets="API_KEY=${WEBUI_SECRET}:latest,PARTNER_API_KEY=${PARTNER_SECRET}:latest" \
  --set-env-vars="PROJECT_ID=${PROJECT_ID},REGION=${REGION},APIGEE_HOST=${APIGEE_HOST},AGENT_ENGINE_ID=${AGENT_ENGINE_ID},INSIGHTS_ENGINE_ID=${INSIGHTS_ENGINE_ID},PROJECT_NUMBER=${PROJECT_NUMBER}" \
  --min-instances=1 --max-instances=1 --cpu=1 --memory=512Mi --timeout=300 \
  --labels=app=cymbal-ge-demo,managed-by=deploy-cloudrun

echo "▶ IAP: service agent may invoke the service; IAP_MEMBERS may pass IAP"
g beta services identity create --service=iap.googleapis.com >/dev/null 2>&1 || true
g run services add-iam-policy-binding "$SERVICE" --region="$REGION" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com" \
  --role=roles/run.invoker >/dev/null
IFS=',' read -r -a members <<< "$IAP_MEMBERS"
for m in "${members[@]}"; do
  m="$(printf '%s' "$m" | tr -d '[:space:]')"
  [ -n "$m" ] || continue
  g iap web add-iam-policy-binding --resource-type=cloud-run --service="$SERVICE" --region="$REGION" \
    --member="$m" --role=roles/iap.httpsResourceAccessor --condition=None >/dev/null
  echo "  granted $m"
done

if [ -n "$DOMAIN" ]; then
  echo "▶ Domain mapping + DNS: $DOMAIN"
  g beta run domain-mappings describe --domain="$DOMAIN" --region="$REGION" >/dev/null 2>&1 || \
    g beta run domain-mappings create --service="$SERVICE" --domain="$DOMAIN" --region="$REGION"
  FQDN="${DOMAIN}."
  EXISTING=$(g dns record-sets list --zone="$DNS_ZONE" --name="$FQDN" --type=CNAME --format='value(rrdatas[0])' 2>/dev/null || true)
  if [ -z "$EXISTING" ]; then
    g dns record-sets create "$FQDN" --zone="$DNS_ZONE" --type=CNAME --ttl=300 --rrdatas=ghs.googlehosted.com.
  elif [ "$EXISTING" != "ghs.googlehosted.com." ]; then
    echo "  ⚠️  $FQDN already has CNAME $EXISTING, not changing it"
  fi
fi

URL=$(g run services describe "$SERVICE" --region="$REGION" --format='value(status.url)')
echo "✅ $SERVICE deployed: $URL${DOMAIN:+  |  https://$DOMAIN (certificate can take 15-60 min)}"
echo "   Verify: curl -s -o /dev/null -w '%{http_code}\n' $URL/healthz   # expect 302/401/403 (IAP), never 200"
