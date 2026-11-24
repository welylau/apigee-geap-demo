#!/usr/bin/env bash
# ==============================================================================
# scripts/teardown-apigee.sh - remove everything scripts/setup-apigee.sh created, in reverse order.
# Asks y/N before EVERY destructive step (reads the answer from the terminal). Irreversible.
#
#   1. Secret Manager: cymbal-ge-demo-webui-key / -agent-key / -partner-key / -insights-key
#   2. Apps -webui-app / -agent-app / -finpal-app / -insights-app, then developer cymbal-ge-demo@example.com
#   3. API products cymbal-ge-demo-webui / -internal-agent / -partner / -insights
#   4. Undeploy + delete cymbal-ge-demo-token / -mcp-banking / -llm / -credit-bureau (YOUR_APIGEE_ENV)
#   5. Remove roles/run.invoker of the Apigee runtime SA on Cloud Run cymbal-ge-demo-credit-bureau
#   6. KVM cymbal-ge-demo-kvm (YOUR_APIGEE_ENV)
#   Only with --with-extproc (matches setup-apigee.sh --with-extproc):
#   X1. Undeploy + delete cymbal-ge-demo-extproc; X2. envgroup attachment + envgroup cymbal-ge-demo-extproc-grp;
#   X3. instance attachment + environment cymbal-ge-demo-extproc
#
# Usage: ./scripts/teardown-apigee.sh [--dry-run] [--with-extproc]
# Auth: ADC (see setup-apigee.sh). Every call branches on the HTTP code: 200 = done, 404 = already gone.
# ==============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
APIGEE_ORG="${APIGEE_ORG:-$PROJECT_ID}"
APIGEE_ENV="${APIGEE_ENV:-YOUR_APIGEE_ENV}"
APIGEE_INSTANCE="${APIGEE_INSTANCE:-asia-southeast1}"
EXTPROC_ENV="${EXTPROC_ENV:-cymbal-ge-demo-extproc}"
EXTPROC_ENVGROUP="${EXTPROC_ENVGROUP:-cymbal-ge-demo-extproc-grp}"
KVM="cymbal-ge-demo-kvm"
PROXIES=(cymbal-ge-demo-token cymbal-ge-demo-mcp-banking cymbal-ge-demo-llm cymbal-ge-demo-credit-bureau)
REGION="${REGION:-asia-southeast1}"
RUNTIME_SA="${RUNTIME_SA:-sa-apigee-aiservices@${PROJECT_ID}.iam.gserviceaccount.com}"
CREDIT_BUREAU_SERVICE="${CREDIT_BUREAU_SERVICE:-cymbal-ge-demo-credit-bureau}"
EXTPROC_PROXY="cymbal-ge-demo-extproc"
PRODUCTS=(cymbal-ge-demo-webui cymbal-ge-demo-internal-agent cymbal-ge-demo-partner cymbal-ge-demo-insights)
DEV_EMAIL="cymbal-ge-demo@example.com"
APPS=(cymbal-ge-demo-webui-app cymbal-ge-demo-agent-app cymbal-ge-demo-finpal-app cymbal-ge-demo-insights-app)
SECRETS=(cymbal-ge-demo-webui-key cymbal-ge-demo-agent-key cymbal-ge-demo-partner-key cymbal-ge-demo-insights-key)
API="https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}"
API_ROOT="https://apigee.googleapis.com/v1"

DRY_RUN=0; WITH_EXTPROC=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --with-extproc) WITH_EXTPROC=1 ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
for bin in curl python3 gcloud; do command -v "$bin" >/dev/null || { echo "❌ $bin not found" >&2; exit 1; }; done
umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TOKEN="$(gcloud auth application-default print-access-token)" || { echo "❌ ADC token unavailable" >&2; exit 1; }
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$TMP/auth"; unset TOKEN

echo "⚠️  Teardown of the cymbal-ge-demo Apigee resources in org $APIGEE_ORG (project $PROJECT_ID)."
[ "$DRY_RUN" = 1 ] && echo "🧪 DRY RUN: nothing will be deleted"

confirm() { # confirm "question" -> 0 if y
  [ "$DRY_RUN" = 1 ] && { echo "   [dry-run] would ask: $1"; return 0; }
  local a; read -r -p "❓ $1 [y/N] " a < /dev/tty || a=""
  [[ "$a" =~ ^[Yy]$ ]]
}
api() { # api METHOD URL_OR_PATH -> HTTP code, body in $TMP/body
  local method="$1" url="$2" code
  [[ "$url" == https://* ]] || url="${API}${url}"
  if [ "$DRY_RUN" = 1 ] && [ "$method" != GET ]; then echo "   [dry-run] $method $url" >&2; echo DRY; return 0; fi
  code="$(curl -sS -o "$TMP/body" -w '%{http_code}' -X "$method" -H @"$TMP/auth" "$url" 2>/dev/null)" || true
  echo "${code:-000}"
}
report() { # report CODE LABEL
  case "$1" in
    200|201|202|204) echo "   🗑  $2 deleted" ;;
    DRY) ;;
    404) echo "   ✔ $2 already gone" ;;
    *) echo "   ❌ $2: HTTP $1 $(head -c 300 "$TMP/body" 2>/dev/null)" >&2 ;;
  esac
}
wait_op() {
  [ "$DRY_RUN" = 1 ] && return 0
  local name start
  name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$TMP/body" 2>/dev/null || true)"
  [[ "$name" == */operations/* ]] || return 0
  start=$(date +%s)
  while :; do
    api GET "${API_ROOT}/${name}" >/dev/null
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("done") else 1)' "$TMP/body" 2>/dev/null && return 0
    [ $(( $(date +%s) - start )) -lt 1500 ] || { echo "   ⚠️  timeout waiting for $name" >&2; return 0; }
    sleep 10
  done
}
undeploy_delete() { # PROXY ENV
  local p="$1" env="$2" code revs r
  code=$(api GET "/environments/${env}/apis/${p}/deployments")
  revs=""
  [ "$code" = 200 ] && revs="$(python3 -c 'import json,sys; print(" ".join(d["revision"] for d in json.load(open(sys.argv[1])).get("deployments",[])))' "$TMP/body")"
  for r in $revs; do
    code=$(api DELETE "/environments/${env}/apis/${p}/revisions/${r}/deployments"); report "$code" "$p r$r deployment in $env"
  done
  code=$(api DELETE "/apis/${p}"); report "$code" "proxy $p"
}

# 1. secrets
if confirm "Delete Secret Manager secrets ${SECRETS[*]}?"; then
  for s in "${SECRETS[@]}"; do
    if [ "$DRY_RUN" = 1 ]; then echo "   [dry-run] gcloud secrets delete $s"; continue; fi
    if gcloud secrets describe "$s" --project "$PROJECT_ID" >/dev/null 2>&1; then
      gcloud secrets delete "$s" --project "$PROJECT_ID" --quiet >/dev/null && echo "   🗑  secret $s deleted"
    else echo "   ✔ secret $s already gone"; fi
  done
fi
# 2. apps + developer
if confirm "Delete apps ${APPS[*]} and developer $DEV_EMAIL?"; then
  for a in "${APPS[@]}"; do code=$(api DELETE "/developers/${DEV_EMAIL}/apps/${a}"); report "$code" "app $a"; done
  code=$(api DELETE "/developers/${DEV_EMAIL}"); report "$code" "developer $DEV_EMAIL"
fi
# 3. products
if confirm "Delete API products ${PRODUCTS[*]}?"; then
  for p in "${PRODUCTS[@]}"; do code=$(api DELETE "/apiproducts/${p}"); report "$code" "product $p"; done
fi
# 4. proxies in YOUR_APIGEE_ENV
if confirm "Undeploy and delete proxies ${PROXIES[*]} from $APIGEE_ENV?"; then
  for p in "${PROXIES[@]}"; do undeploy_delete "$p" "$APIGEE_ENV"; done
fi
# 5. Cloud Run invoker binding for the Apigee runtime SA
if confirm "Remove roles/run.invoker of $RUNTIME_SA on Cloud Run $CREDIT_BUREAU_SERVICE?"; then
  if [ "$DRY_RUN" = 1 ]; then
    echo "   [dry-run] gcloud run services remove-iam-policy-binding $CREDIT_BUREAU_SERVICE --region $REGION --member serviceAccount:$RUNTIME_SA --role roles/run.invoker"
  elif gcloud run services remove-iam-policy-binding "$CREDIT_BUREAU_SERVICE" --region "$REGION" --project "$PROJECT_ID" \
       --member "serviceAccount:$RUNTIME_SA" --role roles/run.invoker --quiet >/dev/null 2>&1; then
    echo "   🗑  run.invoker binding removed"
  else
    echo "   ✔ binding (or service) already gone"
  fi
fi
# 6. KVM
if confirm "Delete KVM $KVM (holds the demo JWT secret) from $APIGEE_ENV?"; then
  code=$(api DELETE "/environments/${APIGEE_ENV}/keyvaluemaps/${KVM}"); report "$code" "KVM $KVM"
fi
if [ "$WITH_EXTPROC" = 1 ]; then
  # X1. ext-proc proxy
  if confirm "Undeploy and delete proxy $EXTPROC_PROXY from $EXTPROC_ENV?"; then
    undeploy_delete "$EXTPROC_PROXY" "$EXTPROC_ENV"
  fi
  # X2. envgroup
  if confirm "Detach $EXTPROC_ENV from envgroup $EXTPROC_ENVGROUP and delete the envgroup?"; then
    code=$(api GET "/envgroups/${EXTPROC_ENVGROUP}/attachments")
    if [ "$code" = 200 ]; then
      for id in $(python3 -c 'import json,sys; print(" ".join(a["name"] for a in json.load(open(sys.argv[1])).get("environmentGroupAttachments",[]) if a.get("environment")==sys.argv[2]))' "$TMP/body" "$EXTPROC_ENV"); do
        code=$(api DELETE "/envgroups/${EXTPROC_ENVGROUP}/attachments/${id}"); report "$code" "envgroup attachment $id"; wait_op
      done
    fi
    code=$(api DELETE "/envgroups/${EXTPROC_ENVGROUP}"); report "$code" "envgroup $EXTPROC_ENVGROUP"; wait_op
  fi
  # X3. instance attachment + environment
  if confirm "Detach $EXTPROC_ENV from instance $APIGEE_INSTANCE and delete the environment (several minutes)?"; then
    code=$(api GET "/instances/${APIGEE_INSTANCE}/attachments")
    if [ "$code" = 200 ]; then
      for id in $(python3 -c 'import json,sys; print(" ".join(a["name"] for a in json.load(open(sys.argv[1])).get("attachments",[]) if a.get("environment")==sys.argv[2]))' "$TMP/body" "$EXTPROC_ENV"); do
        code=$(api DELETE "/instances/${APIGEE_INSTANCE}/attachments/${id}"); report "$code" "instance attachment $id"; wait_op
      done
    fi
    code=$(api DELETE "/environments/${EXTPROC_ENV}"); report "$code" "environment $EXTPROC_ENV"; wait_op
  fi
fi
echo "✅ Teardown finished (Agent Gateway / PSC / DNS / authz resources are removed by infra/ teardown)."
