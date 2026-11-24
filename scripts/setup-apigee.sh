#!/usr/bin/env bash
# ==============================================================================
# scripts/setup-apigee.sh - idempotent Apigee X setup for "Agents Meet APIs" (Cymbal Bank)
#
#   1. KVM cymbal-ge-demo-kvm (encrypted, env YOUR_APIGEE_ENV) + entry jwt-hs256-secret
#      (random 64-char secret generated locally, sent from a 0600 temp file, never printed)
#   2. Import + deploy cymbal-ge-demo-token / -mcp-banking / -llm to YOUR_APIGEE_ENV as the runtime SA
#   3. Credit bureau (S5): grant the runtime SA roles/run.invoker on Cloud Run cymbal-ge-demo-credit-bureau,
#      import + deploy cymbal-ge-demo-credit-bureau (target URL auto-detected) to YOUR_APIGEE_ENV as the runtime SA
#   4. API products cymbal-ge-demo-webui / -internal-agent (+ bureau proxy) / -partner / -insights (LLM only)
#   5. Developer cymbal-ge-demo@example.com + apps -webui-app / -agent-app / -finpal-app / -insights-app
#   6. App keys -> Secret Manager cymbal-ge-demo-webui-key / -agent-key / -partner-key / -insights-key (masked output)
#   OPT-IN (--with-extproc; NOT used by the demo: the org is at its environment limit):
#   X. Ext-proc env cymbal-ge-demo-extproc (apigee-service-extension-enabled=true), instance attachment,
#      envgroup cymbal-ge-demo-extproc-grp (host apigee-extproc.cymbal-ge-demo.internal), proxy cymbal-ge-demo-extproc
#
# Usage: ./scripts/setup-apigee.sh [--dry-run] [--no-deploy] [--rotate-jwt-secret] [--with-extproc]
#   --dry-run            read-only GETs run (when ADC is available); every write is printed, not executed
#   --no-deploy          skip bundle import/deploy (KVM, products, apps, secrets only)
#   --rotate-jwt-secret  replace an existing KVM secret (invalidates outstanding demo user tokens)
#   --with-extproc       also create the ext-proc env/envgroup and deploy cymbal-ge-demo-extproc (default off)
#
# Auth: Application Default Credentials. The gcloud *user* token is rejected by apigee.googleapis.com
# in this org (ACCESS_TOKEN_TYPE_UNSUPPORTED). For this repo run with:
#   export GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/adc-YOUR_PROJECT_ID.json \
#          CLOUDSDK_CONFIG=~/.config/gcloud CLOUDSDK_CORE_PROJECT=YOUR_PROJECT_ID
# Every REST call branches on the HTTP code (curl exits 0 on 4xx/5xx). The access token is passed to
# curl through a 0600 header file, never on the command line.
# Overrides: PROJECT_ID APIGEE_ORG APIGEE_ENV REGION APIGEE_INSTANCE RUNTIME_SA CREDIT_BUREAU_SERVICE
#   CREDIT_BUREAU_URL (service base URL, no /mcp) LLM_TOKEN_LIMIT LLM_TOKEN_INTERVAL LLM_TOKEN_UNIT
#   PARTNER_QUOTA; ext-proc only: EXTPROC_ENV EXTPROC_ENVGROUP EXTPROC_HOST EXTPROC_ENV_TYPE CREDIT_BUREAU_HOSTS
# ==============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
APIGEE_ORG="${APIGEE_ORG:-$PROJECT_ID}"
APIGEE_ENV="${APIGEE_ENV:-YOUR_APIGEE_ENV}"
REGION="${REGION:-asia-southeast1}"
APIGEE_INSTANCE="${APIGEE_INSTANCE:-asia-southeast1}"
RUNTIME_SA="${RUNTIME_SA:-sa-apigee-aiservices@${PROJECT_ID}.iam.gserviceaccount.com}"
EXTPROC_ENV="${EXTPROC_ENV:-cymbal-ge-demo-extproc}"
EXTPROC_ENVGROUP="${EXTPROC_ENVGROUP:-cymbal-ge-demo-extproc-grp}"
EXTPROC_HOST="${EXTPROC_HOST:-apigee-extproc.cymbal-ge-demo.internal}"
# Org YOUR_PROJECT_ID is SUBSCRIPTION_2021 and its envs carry no "type", so the quickstart's
# "type": "COMPREHENSIVE" is omitted by default. Set EXTPROC_ENV_TYPE=COMPREHENSIVE on PAYG/Sub-2024 orgs.
EXTPROC_ENV_TYPE="${EXTPROC_ENV_TYPE:-}"
CREDIT_BUREAU_SERVICE="${CREDIT_BUREAU_SERVICE:-cymbal-ge-demo-credit-bureau}"
CREDIT_BUREAU_URL="${CREDIT_BUREAU_URL:-}"
CREDIT_BUREAU_HOSTS="${CREDIT_BUREAU_HOSTS:-}"
LLM_TOKEN_LIMIT="${LLM_TOKEN_LIMIT:-200000}"   # roomy: the LLM budget is no longer a demo scenario
LLM_TOKEN_INTERVAL="${LLM_TOKEN_INTERVAL:-5}"
LLM_TOKEN_UNIT="${LLM_TOKEN_UNIT:-minute}"
PARTNER_QUOTA="${PARTNER_QUOTA:-5}"
INTERNAL_QUOTA="${INTERNAL_QUOTA:-600}"

KVM="cymbal-ge-demo-kvm"
KVM_ENTRY="jwt-hs256-secret"
PROXIES=(cymbal-ge-demo-token cymbal-ge-demo-mcp-banking cymbal-ge-demo-llm)
BUREAU_PROXY="cymbal-ge-demo-credit-bureau"
EXTPROC_PROXY="cymbal-ge-demo-extproc"
P_WEBUI="cymbal-ge-demo-webui"
P_INTERNAL="cymbal-ge-demo-internal-agent"
P_PARTNER="cymbal-ge-demo-partner"
P_INSIGHTS="cymbal-ge-demo-insights"   # Insights Agent (scenario 7): LLM gateway only, no banking tools
DEV_EMAIL="cymbal-ge-demo@example.com"
LLM_MODELS=(gemini-3.5-flash gemini-3.5-flash-lite)
ALL_TOOLS="get_account_balance list_transactions transfer_funds get_account_summary get_fx_rate"
PARTNER_TOOLS="get_account_summary get_fx_rate"
# app|product|secret
APPS=("cymbal-ge-demo-webui-app|${P_WEBUI}|cymbal-ge-demo-webui-key"
      "cymbal-ge-demo-agent-app|${P_INTERNAL}|cymbal-ge-demo-agent-key"
      "cymbal-ge-demo-finpal-app|${P_PARTNER}|cymbal-ge-demo-partner-key"
      "cymbal-ge-demo-insights-app|${P_INSIGHTS}|cymbal-ge-demo-insights-key")

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
API="https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}"
API_ROOT="https://apigee.googleapis.com/v1"

DRY_RUN=0; DO_DEPLOY=1; ROTATE=0; WITH_EXTPROC=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-deploy) DO_DEPLOY=0 ;;
    --rotate-jwt-secret) ROTATE=1 ;;
    --with-extproc) WITH_EXTPROC=1 ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ---------- preflight ----------
if [ -f "$ROOT/.sanitize.state" ] && grep -q sanitized "$ROOT/.sanitize.state"; then
  echo "❌ Repo is sanitized (YOUR_* placeholders). Run ./restore.sh first." >&2; exit 1
fi
for bin in curl python3 gcloud; do
  command -v "$bin" >/dev/null || { echo "❌ $bin not found" >&2; exit 1; }
done
umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ "$DO_DEPLOY" = 1 ]; then
  python3 "$DIR/validate-apigee-bundles.py" "$ROOT" >/dev/null || { python3 "$DIR/validate-apigee-bundles.py" "$ROOT"; exit 1; }
fi

HAVE_TOKEN=1
if ! TOKEN="$(gcloud auth application-default print-access-token 2>/dev/null)" || [ -z "$TOKEN" ]; then
  if [ "$DRY_RUN" = 1 ]; then HAVE_TOKEN=0; echo "⚠️  no ADC token: dry-run without read-only lookups"
  else echo "❌ ADC token unavailable: gcloud auth application-default login" >&2; exit 1; fi
fi
printf 'Authorization: Bearer %s\n' "${TOKEN:-none}" > "$TMP/auth"; unset TOKEN

[ "$DRY_RUN" = 1 ] && echo "🧪 DRY RUN: no writes will be made"
echo "🔧 org=$APIGEE_ORG env=$APIGEE_ENV extproc-env=$EXTPROC_ENV instance=$APIGEE_INSTANCE sa=$RUNTIME_SA"

# ---------- REST helpers ----------
# api METHOD URL_OR_PATH [BODY_FILE] -> prints HTTP code; body in $TMP/body.
#   dry-run: writes print "[dry-run] ..." and return DRY; GETs without a token return SKIP.
api() {
  local method="$1" url="$2" body="${3:-}" code
  [[ "$url" == https://* ]] || url="${API}${url}"
  if [ "$DRY_RUN" = 1 ] && [ "$method" != GET ]; then
    echo "   [dry-run] $method $url${body:+  <- $(basename "$body")}" >&2; echo DRY; return 0
  fi
  if [ "$HAVE_TOKEN" = 0 ]; then echo "   [dry-run] GET $url (skipped: no token)" >&2; echo SKIP; return 0; fi
  local args=(-sS -o "$TMP/body" -w '%{http_code}' -X "$method" -H @"$TMP/auth" "$url")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" --data-binary @"$body")
  code="$(curl "${args[@]}" 2>/dev/null)" || true
  echo "${code:-000}"
}
new() { if [ "$DRY_RUN" = 1 ]; then echo "   📝 would: $*"; else echo "   ➕ $*"; fi; }
ok() { case "$1" in 200|201|DRY) return 0 ;; *) return 1 ;; esac; }
absent() { case "$1" in 404|SKIP) return 0 ;; *) return 1 ;; esac; }
fail() { echo "❌ $1 (HTTP $2): $(head -c 400 "$TMP/body" 2>/dev/null)" >&2; exit 1; }
fail_quiet() { echo "❌ $1 (HTTP $2) [response body withheld: may contain secrets]" >&2; exit 1; }
jget() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$TMP/body" "$1" 2>/dev/null || true; }

# wait_op: poll the long-running operation named in $TMP/body until done (timeout seconds in $1).
wait_op() {
  local timeout="${1:-900}" name start code done
  [ "$DRY_RUN" = 1 ] && return 0
  name="$(jget name)"; [ -n "$name" ] || return 0
  start=$(date +%s)
  while :; do
    code=$(api GET "${API_ROOT}/${name}")
    ok "$code" || fail "poll $name" "$code"
    done="$(jget done)"
    if [ "$done" = "True" ]; then
      [ -z "$(jget error.message)" ] || fail "operation $name" "$(jget error.code)"
      return 0
    fi
    [ $(( $(date +%s) - start )) -lt "$timeout" ] || { echo "❌ timeout waiting for $name" >&2; exit 1; }
    sleep 10
  done
}

jsonfile() { # jsonfile NAME PYTHON_EXPR  (env vars available via os.environ)
  python3 -c "import json,os; print(json.dumps($2))" > "$TMP/$1.json"; echo "$TMP/$1.json"
}

# ---------- 1. KVM + JWT secret ----------
echo "🔐 KVM $KVM in $APIGEE_ENV"
code=$(api GET "/environments/${APIGEE_ENV}/keyvaluemaps")
if ok "$code" && python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])) else 1)' "$TMP/body" "$KVM" 2>/dev/null; then
  echo "   ✔ KVM exists"
else
  absent "$code" || ok "$code" || fail "list KVMs" "$code"
  f=$(KVM="$KVM" jsonfile kvm '{"name": os.environ["KVM"], "encrypted": True}')
  code=$(api POST "/environments/${APIGEE_ENV}/keyvaluemaps" "$f"); ok "$code" || fail "create KVM" "$code"
  new "KVM created (encrypted)"
fi
write_secret_entry() { # METHOD PATH
  python3 - "$TMP/kvm-entry.json" "$KVM_ENTRY" <<'PY'
import json, os, secrets, sys
path, name = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"name": name, "value": secrets.token_urlsafe(48)}, f)  # 64 chars >= 32 bytes for HS256
PY
  local c; c=$(api "$1" "$2" "$TMP/kvm-entry.json"); rm -f "$TMP/kvm-entry.json" "$TMP/body"; echo "$c"
}
code=$(api GET "/environments/${APIGEE_ENV}/keyvaluemaps/${KVM}/entries/${KVM_ENTRY}"); rm -f "$TMP/body"
if [ "$code" = 200 ]; then
  if [ "$ROTATE" = 1 ]; then
    code=$(write_secret_entry PUT "/environments/${APIGEE_ENV}/keyvaluemaps/${KVM}/entries/${KVM_ENTRY}")
    ok "$code" || fail_quiet "rotate KVM entry" "$code"; echo "   🔁 JWT secret rotated (value not shown)"
  else
    echo "   ✔ JWT secret entry exists (kept; --rotate-jwt-secret to replace)"
  fi
elif absent "$code"; then
  code=$(write_secret_entry POST "/environments/${APIGEE_ENV}/keyvaluemaps/${KVM}/entries")
  ok "$code" || fail_quiet "create KVM entry" "$code"; new "JWT secret generated and stored (value not shown)"
else
  fail_quiet "get KVM entry" "$code"
fi

# ---------- X. (opt-in) ext-proc environment, instance attachment, envgroup ----------
if [ "$WITH_EXTPROC" = 1 ]; then
  echo "🧩 Ext-proc environment $EXTPROC_ENV (--with-extproc)"
  code=$(api GET "/environments/${EXTPROC_ENV}")
  if [ "$code" = 200 ]; then
    if python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
p={x.get("name"):x.get("value") for x in (d.get("properties") or {}).get("property",[])}
sys.exit(0 if p.get("apigee-service-extension-enabled")=="true" else 1)' "$TMP/body"; then
      echo "   ✔ env exists with apigee-service-extension-enabled=true"
    else
      echo "❌ env $EXTPROC_ENV exists WITHOUT apigee-service-extension-enabled=true; fix it manually (not modified)" >&2; exit 1
    fi
  elif absent "$code"; then
    f=$(EXTPROC_ENV="$EXTPROC_ENV" EXTPROC_ENV_TYPE="$EXTPROC_ENV_TYPE" jsonfile env 'dict({"name": os.environ["EXTPROC_ENV"], "displayName": os.environ["EXTPROC_ENV"],
      "description": "Cymbal GE demo: Apigee extension processor for Agent Gateway authz",
      "state": "ACTIVE", "deploymentType": "PROXY", "apiProxyType": "PROGRAMMABLE",
      "properties": {"property": [{"name": "apigee-service-extension-enabled", "value": "true"}]}},
      **({"type": os.environ["EXTPROC_ENV_TYPE"]} if os.environ["EXTPROC_ENV_TYPE"] else {}))')
    code=$(api POST "/environments" "$f"); ok "$code" || fail "create env (try EXTPROC_ENV_TYPE=COMPREHENSIVE if the org uses env types)" "$code"
    wait_op 900; new "env created"
  else
    fail "get env" "$code"
  fi

  code=$(api GET "/instances/${APIGEE_INSTANCE}/attachments")
  if ok "$code" && python3 -c 'import json,sys; sys.exit(0 if any(a.get("environment")==sys.argv[2] for a in json.load(open(sys.argv[1])).get("attachments",[])) else 1)' "$TMP/body" "$EXTPROC_ENV"; then
    echo "   ✔ env attached to instance $APIGEE_INSTANCE"
  else
    absent "$code" || ok "$code" || fail "list instance attachments" "$code"
    f=$(EXTPROC_ENV="$EXTPROC_ENV" jsonfile attach '{"environment": os.environ["EXTPROC_ENV"]}')
    [ "$DRY_RUN" = 1 ] || echo "   ⏳ attaching env to instance (can take ~10 min)"
    code=$(api POST "/instances/${APIGEE_INSTANCE}/attachments" "$f"); ok "$code" || fail "attach env to instance" "$code"
    wait_op 1500; new "env attached to instance"
  fi

  code=$(api GET "/envgroups/${EXTPROC_ENVGROUP}")
  if [ "$code" = 200 ]; then
    python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])).get("hostnames",[]) else 1)' "$TMP/body" "$EXTPROC_HOST" \
      && echo "   ✔ envgroup $EXTPROC_ENVGROUP has host $EXTPROC_HOST" \
      || { echo "❌ envgroup $EXTPROC_ENVGROUP exists without host $EXTPROC_HOST (not modified)" >&2; exit 1; }
  elif absent "$code"; then
    f=$(G="$EXTPROC_ENVGROUP" H="$EXTPROC_HOST" jsonfile grp '{"name": os.environ["G"], "hostnames": [os.environ["H"]]}')
    code=$(api POST "/envgroups" "$f"); ok "$code" || fail "create envgroup" "$code"
    wait_op 600; new "envgroup created (host $EXTPROC_HOST)"
  else
    fail "get envgroup" "$code"
  fi

  code=$(api GET "/envgroups/${EXTPROC_ENVGROUP}/attachments")
  if ok "$code" && python3 -c 'import json,sys; sys.exit(0 if any(a.get("environment")==sys.argv[2] for a in json.load(open(sys.argv[1])).get("environmentGroupAttachments",[])) else 1)' "$TMP/body" "$EXTPROC_ENV"; then
    echo "   ✔ env attached to envgroup"
  else
    absent "$code" || ok "$code" || fail "list envgroup attachments" "$code"
    f=$(EXTPROC_ENV="$EXTPROC_ENV" jsonfile grpattach '{"environment": os.environ["EXTPROC_ENV"]}')
    code=$(api POST "/envgroups/${EXTPROC_ENVGROUP}/attachments" "$f"); ok "$code" || fail "attach env to envgroup" "$code"
    wait_op 600; new "env attached to envgroup"
  fi
else
  echo "⏭  ext-proc env/envgroup skipped (opt-in: --with-extproc)"
fi

# ---------- 3/4. bundles ----------
resolve_cb_hosts() {
  [ -n "$CREDIT_BUREAU_HOSTS" ] && { echo "$CREDIT_BUREAU_HOSTS"; return; }
  gcloud run services describe "$CREDIT_BUREAU_SERVICE" --region "$REGION" --project "$PROJECT_ID" --format=json 2>/dev/null \
    | python3 -c 'import json,sys
from urllib.parse import urlparse
d=json.load(sys.stdin); urls=[d.get("status",{}).get("url","")]
try: urls += json.loads(d.get("metadata",{}).get("annotations",{}).get("run.googleapis.com/urls","[]"))
except Exception: pass
print(",".join(sorted({urlparse(u).hostname for u in urls if u})))' 2>/dev/null || true
}

# Base URL of the Cloud Run credit bureau (no /mcp). Prefers the deterministic
# https://<service>-<project-number>.<region>.run.app URL (also the GoogleIDToken audience).
resolve_bureau_url() {
  [ -n "$CREDIT_BUREAU_URL" ] && { echo "${CREDIT_BUREAU_URL%/}"; return; }
  gcloud run services describe "$CREDIT_BUREAU_SERVICE" --region "$REGION" --project "$PROJECT_ID" --format=json 2>/dev/null \
    | python3 -c 'import json,re,sys
d=json.load(sys.stdin); urls=[d.get("status",{}).get("url","")]
try: urls += json.loads(d.get("metadata",{}).get("annotations",{}).get("run.googleapis.com/urls","[]"))
except Exception: pass
urls=[u.rstrip("/") for u in urls if u]
det=[u for u in urls if re.match(r"^https://[a-z0-9-]+-[0-9]+\.[a-z0-9-]+\.run\.app$", u)]
print((det or urls or [""])[0])' 2>/dev/null || true
}

stage_bundle() { # stage_bundle PROXY -> prints zip path
  local p="$1" s="$TMP/stage/$1"
  rm -rf "$s"; mkdir -p "$s"; cp -R "$ROOT/apigee/$p/apiproxy" "$s/apiproxy"
  case "$p" in
    cymbal-ge-demo-llm)
      sed -i.bak -e "s|^vertex_project=.*|vertex_project=${PROJECT_ID}|" "$s/apiproxy/resources/properties/llm.properties" ;;
    cymbal-ge-demo-credit-bureau)
      sed -i.bak -e "s|^target_url=.*|target_url=${BUREAU_URL}/mcp|" -e "s|^target_host=.*|target_host=${BUREAU_URL#https://}|" \
        -e "s|^audience=.*|audience=${BUREAU_URL}|" "$s/apiproxy/resources/properties/bureau.properties" ;;
    cymbal-ge-demo-extproc)
      sed -i.bak -e "s|^credit_bureau_hosts=.*|credit_bureau_hosts=${CB_HOSTS}|" "$s/apiproxy/resources/properties/extproc.properties" ;;
  esac
  find "$s" -name '*.bak' -delete
  python3 - "$s" "$TMP/$p.zip" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for d, _, fs in os.walk(os.path.join(src, "apiproxy")):
        for f in sorted(fs):
            full = os.path.join(d, f)
            z.write(full, os.path.relpath(full, src))
PY
  echo "$TMP/$p.zip"
}

import_and_deploy() { # PROXY ENV SA(optional)
  local p="$1" env="$2" sa="${3:-}" zip code rev state start q
  zip=$(stage_bundle "$p")
  if [ "$DRY_RUN" = 1 ]; then
    echo "   [dry-run] POST ${API}/apis?name=${p}&action=import  <- $(basename "$zip") ($(python3 -c 'import sys,zipfile; print(len(zipfile.ZipFile(sys.argv[1]).namelist()))' "$zip") files)"
    echo "   [dry-run] POST ${API}/environments/${env}/apis/${p}/revisions/<new>/deployments?override=true${sa:+&serviceAccount=${sa}}"
    return 0
  fi
  code="$(curl -sS -o "$TMP/body" -w '%{http_code}' -X POST -H @"$TMP/auth" -F "file=@${zip};type=application/zip" \
    "${API}/apis?name=${p}&action=import" 2>/dev/null)" || true
  ok "${code:-000}" || fail "import $p" "${code:-000}"
  rev="$(jget revision)"; [ -n "$rev" ] || fail "import $p (no revision)" "$code"
  echo "   📦 $p imported as revision $rev"
  q="override=true"; [ -n "$sa" ] && q="${q}&serviceAccount=${sa}"
  code=$(api POST "/environments/${env}/apis/${p}/revisions/${rev}/deployments?${q}"); ok "$code" || fail "deploy $p r$rev to $env" "$code"
  start=$(date +%s)
  while :; do
    code=$(api GET "/environments/${env}/apis/${p}/revisions/${rev}/deployments")
    state="$(jget state)"
    [ "$state" = READY ] && break
    [ "$state" = ERROR ] && fail "deployment of $p r$rev" "$code"
    [ $(( $(date +%s) - start )) -lt 600 ] || { echo "❌ timeout deploying $p" >&2; exit 1; }
    sleep 8
  done
  echo "   🚀 $p r$rev READY in $env"
}

if [ "$DO_DEPLOY" = 1 ]; then
  echo "📦 Proxies -> $APIGEE_ENV (runtime SA $RUNTIME_SA)"
  for p in "${PROXIES[@]}"; do import_and_deploy "$p" "$APIGEE_ENV" "$RUNTIME_SA"; done

  echo "🏛  Credit bureau proxy (S5)"
  BUREAU_URL="$(resolve_bureau_url)"
  if [ -z "$BUREAU_URL" ]; then
    echo "⚠️  Cloud Run $CREDIT_BUREAU_SERVICE not found and CREDIT_BUREAU_URL unset: $BUREAU_PROXY NOT deployed."
    echo "    Deploy credit-bureau/ first, then re-run this script."
  else
    echo "   target ${BUREAU_URL}/mcp (GoogleIDToken audience ${BUREAU_URL})"
    # roles/run.invoker for the Apigee runtime SA (the bureau is not publicly invokable). Idempotent.
    if gcloud run services get-iam-policy "$CREDIT_BUREAU_SERVICE" --region "$REGION" --project "$PROJECT_ID" --format=json 2>/dev/null \
       | python3 -c 'import json,sys
d=json.load(sys.stdin); m="serviceAccount:"+sys.argv[1]
sys.exit(0 if any(b.get("role")=="roles/run.invoker" and m in b.get("members",[]) for b in d.get("bindings",[])) else 1)' "$RUNTIME_SA"; then
      echo "   ✔ $RUNTIME_SA already has roles/run.invoker on $CREDIT_BUREAU_SERVICE"
    elif [ "$DRY_RUN" = 1 ]; then
      echo "   [dry-run] gcloud run services add-iam-policy-binding $CREDIT_BUREAU_SERVICE --region $REGION --member serviceAccount:$RUNTIME_SA --role roles/run.invoker"
    else
      gcloud run services add-iam-policy-binding "$CREDIT_BUREAU_SERVICE" --region "$REGION" --project "$PROJECT_ID" \
        --member "serviceAccount:$RUNTIME_SA" --role roles/run.invoker --quiet >/dev/null
      new "roles/run.invoker granted to $RUNTIME_SA on $CREDIT_BUREAU_SERVICE"
    fi
    import_and_deploy "$BUREAU_PROXY" "$APIGEE_ENV" "$RUNTIME_SA"
  fi

  if [ "$WITH_EXTPROC" = 1 ]; then
    CB_HOSTS="$(resolve_cb_hosts)"
    if [ -z "$CB_HOSTS" ]; then
      CB_HOSTS="__CREDIT_BUREAU_HOSTS__"
      echo "⚠️  credit-bureau host unknown: ext-proc proxy deploys but governs nothing."
    else
      echo "   credit-bureau hosts governed by ext-proc: $CB_HOSTS"
    fi
    echo "📦 Ext-proc proxy -> $EXTPROC_ENV (--with-extproc)"
    import_and_deploy "$EXTPROC_PROXY" "$EXTPROC_ENV" ""
  fi
else
  echo "⏭  --no-deploy: bundles not imported"
fi

# ---------- 5. API products ----------
upsert() { # upsert KIND_PATH NAME JSON_FILE LABEL
  local code
  code=$(api GET "$1/$2")
  if [ "$code" = 200 ]; then
    code=$(api PUT "$1/$2" "$3"); ok "$code" || fail "update $4 $2" "$code"; echo "   ✔ $4 $2 updated"
  elif absent "$code"; then
    code=$(api POST "$1" "$3"); ok "$code" || fail "create $4 $2" "$code"; new "$4 $2 created"
  else
    fail "get $4 $2" "$code"
  fi
}

echo "🛒 API products"
export APIGEE_ENV P_WEBUI P_INTERNAL P_PARTNER P_INSIGHTS ALL_TOOLS PARTNER_TOOLS LLM_TOKEN_LIMIT LLM_TOKEN_INTERVAL LLM_TOKEN_UNIT PARTNER_QUOTA INTERNAL_QUOTA
export LLM_MODELS_CSV; LLM_MODELS_CSV="$(IFS=,; echo "${LLM_MODELS[*]}")"
f=$(jsonfile p-webui '{"name": os.environ["P_WEBUI"], "displayName": "Cymbal GE Demo - Web UI (token facade)",
  "description": "Web UI BFF: mint demo user tokens via cymbal-ge-demo-token.", "approvalType": "auto",
  "environments": [os.environ["APIGEE_ENV"]],
  "operationGroup": {"operationConfigType": "proxy", "operationConfigs": [
    {"apiSource": "cymbal-ge-demo-token", "operations": [{"resource": "/", "methods": ["POST"]}]},
     {"apiSource": "cymbal-ge-demo-token", "operations": [{"resource": "/**", "methods": ["POST"]}]}]}}')
upsert /apiproducts "$P_WEBUI" "$f" product

f=$(jsonfile p-internal '{"name": os.environ["P_INTERNAL"], "displayName": "Cymbal GE Demo - Internal agent",
  "description": "RM Agent: all banking MCP tools (end-user JWT required), LLM gateway with a per-app token budget, paid credit bureau (3 lookups / min).",
  "approvalType": "auto", "environments": [os.environ["APIGEE_ENV"]],
  "attributes": [{"name": "allowed_tools", "value": os.environ["ALL_TOOLS"]}, {"name": "user_token_required", "value": "true"}],
  "quota": os.environ["INTERNAL_QUOTA"], "quotaInterval": "1", "quotaTimeUnit": "minute",
  "operationGroup": {"operationConfigType": "proxy", "operationConfigs": [
    {"apiSource": "cymbal-ge-demo-mcp-banking", "operations": [{"resource": "/", "methods": ["POST"]}],
     "quota": {"limit": os.environ["INTERNAL_QUOTA"], "interval": "1", "timeUnit": "minute"}},
     {"apiSource": "cymbal-ge-demo-mcp-banking", "operations": [{"resource": "/**", "methods": ["POST"]}],
     "quota": {"limit": os.environ["INTERNAL_QUOTA"], "interval": "1", "timeUnit": "minute"}},
    {"apiSource": "cymbal-ge-demo-llm", "operations": [{"resource": "/", "methods": ["POST"]}]},
     {"apiSource": "cymbal-ge-demo-llm", "operations": [{"resource": "/**", "methods": ["POST"]}]},
    {"apiSource": "cymbal-ge-demo-credit-bureau", "operations": [{"resource": "/", "methods": ["POST"]}]},
     {"apiSource": "cymbal-ge-demo-credit-bureau", "operations": [{"resource": "/**", "methods": ["POST"]}]}]},
  "llmQuota": os.environ["LLM_TOKEN_LIMIT"], "llmQuotaInterval": os.environ["LLM_TOKEN_INTERVAL"], "llmQuotaTimeUnit": os.environ["LLM_TOKEN_UNIT"],
  "llmOperationGroup": {"operationConfigs": [
    {"apiSource": "cymbal-ge-demo-llm", "llmOperations": [{"resource": "/**", "methods": ["POST"], "model": m}]}
    for m in os.environ["LLM_MODELS_CSV"].split(",")]}}')
upsert /apiproducts "$P_INTERNAL" "$f" product

f=$(jsonfile p-partner '{"name": os.environ["P_PARTNER"], "displayName": "Cymbal GE Demo - Open Banking partner (FinPal)",
  "description": "External partner agent: masked account summary + FX only, 5 tool calls per minute.",
  "approvalType": "auto", "environments": [os.environ["APIGEE_ENV"]],
  "attributes": [{"name": "allowed_tools", "value": os.environ["PARTNER_TOOLS"]}, {"name": "user_token_required", "value": "false"}],
  "quota": os.environ["PARTNER_QUOTA"], "quotaInterval": "1", "quotaTimeUnit": "minute",
  "operationGroup": {"operationConfigType": "proxy", "operationConfigs": [
    {"apiSource": "cymbal-ge-demo-mcp-banking", "operations": [{"resource": "/", "methods": ["POST"]}],
     "quota": {"limit": os.environ["PARTNER_QUOTA"], "interval": "1", "timeUnit": "minute"}},
     {"apiSource": "cymbal-ge-demo-mcp-banking", "operations": [{"resource": "/**", "methods": ["POST"]}],
     "quota": {"limit": os.environ["PARTNER_QUOTA"], "interval": "1", "timeUnit": "minute"}}]}}')
upsert /apiproducts "$P_PARTNER" "$f" product

# Insights Agent: may use the LLM gateway only. It has no banking or bureau proxies, so even if Agent Gateway
# ever let it reach the MCP server, Apigee would refuse its key (and its delegated tokens name a different app).
f=$(jsonfile p-insights '{"name": os.environ["P_INSIGHTS"], "displayName": "Cymbal GE Demo - Insights agent",
  "description": "Marketing Insights Agent: LLM gateway only (no banking tools, no credit bureau).",
  "approvalType": "auto", "environments": [os.environ["APIGEE_ENV"]],
  "operationGroup": {"operationConfigType": "proxy", "operationConfigs": [
    {"apiSource": "cymbal-ge-demo-llm", "operations": [{"resource": "/", "methods": ["POST"]}]},
     {"apiSource": "cymbal-ge-demo-llm", "operations": [{"resource": "/**", "methods": ["POST"]}]}]},
  "llmQuota": os.environ["LLM_TOKEN_LIMIT"], "llmQuotaInterval": os.environ["LLM_TOKEN_INTERVAL"], "llmQuotaTimeUnit": os.environ["LLM_TOKEN_UNIT"],
  "llmOperationGroup": {"operationConfigs": [
    {"apiSource": "cymbal-ge-demo-llm", "llmOperations": [{"resource": "/**", "methods": ["POST"], "model": m}]}
    for m in os.environ["LLM_MODELS_CSV"].split(",")]}}')
upsert /apiproducts "$P_INSIGHTS" "$f" product

# ---------- 6. developer + apps ----------
echo "👤 Developer and apps"
code=$(api GET "/developers/${DEV_EMAIL}")
if [ "$code" = 200 ]; then echo "   ✔ developer $DEV_EMAIL exists"
elif absent "$code"; then
  f=$(E="$DEV_EMAIL" jsonfile dev '{"email": os.environ["E"], "firstName": "Cymbal", "lastName": "GE Demo", "userName": "cymbal-ge-demo"}')
  code=$(api POST "/developers" "$f"); ok "$code" || fail "create developer" "$code"; new "developer created"
else fail "get developer" "$code"; fi

# ---------- 7. keys -> Secret Manager ----------
store_secret() { # SECRET KEYFILE
  local s="$1" kf="$2"
  if [ "$DRY_RUN" = 1 ]; then echo "   [dry-run] Secret Manager $s <- app key (masked)"; return 0; fi
  if ! gcloud secrets describe "$s" --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud secrets create "$s" --project "$PROJECT_ID" --replication-policy=user-managed --locations="$REGION" \
      --labels=demo=cymbal-ge-demo >/dev/null
    new "secret $s created"
  fi
  if gcloud secrets versions access latest --secret "$s" --project "$PROJECT_ID" --out-file="$TMP/cur" >/dev/null 2>&1 \
     && cmp -s "$TMP/cur" "$kf"; then
    echo "   ✔ secret $s already holds the current key"
  else
    gcloud secrets versions add "$s" --project "$PROJECT_ID" --data-file="$kf" >/dev/null
    new "secret $s new version added"
  fi
  rm -f "$TMP/cur"
}

for entry in "${APPS[@]}"; do
  IFS='|' read -r app product secret <<< "$entry"
  code=$(api GET "/developers/${DEV_EMAIL}/apps/${app}")
  if [ "$code" = 200 ]; then echo "   ✔ app $app exists"
  elif absent "$code"; then
    f=$(A="$app" P="$product" jsonfile "app-$app" '{"name": os.environ["A"], "apiProducts": [os.environ["P"]]}')
    code=$(api POST "/developers/${DEV_EMAIL}/apps" "$f"); ok "$code" || fail_quiet "create app $app" "$code"
    new "app $app created"
  else fail "get app $app" "$code"; fi
  if [ "$DRY_RUN" = 1 ]; then store_secret "$secret" /dev/null; continue; fi
  code=$(api GET "/developers/${DEV_EMAIL}/apps/${app}"); [ "$code" = 200 ] || fail_quiet "read app $app" "$code"
  # Extract key to a 0600 file; check the product is on the key. The key never hits stdout.
  has=$(python3 - "$TMP/body" "$TMP/key-$app" "$product" <<'PY'
import json, os, sys
body, out, product = sys.argv[1:4]
creds = [c for c in json.load(open(body)).get("credentials", []) if c.get("status") == "approved"] or [{}]
c = creds[0]
key = c.get("consumerKey") or ""
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(key)
print("yes" if any(p.get("apiproduct") == product for p in c.get("apiProducts", [])) else ("nokey" if not key else "no"))
PY
)
  rm -f "$TMP/body"
  [ "$has" = nokey ] && { echo "❌ app $app has no approved credential" >&2; exit 1; }
  if [ "$has" = no ]; then
    f=$(P="$product" jsonfile addprod '{"apiProducts": [os.environ["P"]]}')
    code=$(api POST "/developers/${DEV_EMAIL}/apps/${app}/keys/$(cat "$TMP/key-$app")" "$f"); rm -f "$TMP/body"
    ok "$code" || fail_quiet "add $product to $app key" "$code"; new "$product added to $app key"
  fi
  store_secret "$secret" "$TMP/key-$app"
  echo "   🔑 $app key ****$(tail -c 4 "$TMP/key-$app") -> $secret"
  rm -f "$TMP/key-$app"
done

# ---------- 8. readback ----------
echo "🔎 Readback"
if gcloud projects get-iam-policy "$PROJECT_ID" --format=json 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); m="serviceAccount:"+sys.argv[1]
sys.exit(0 if any(b["role"]=="roles/aiplatform.user" and m in b.get("members",[]) for b in d.get("bindings",[])) else 1)' "$RUNTIME_SA"; then
  echo "   ✔ $RUNTIME_SA has roles/aiplatform.user"
else
  echo "   ⚠️  could not confirm roles/aiplatform.user for $RUNTIME_SA (needed by the LLM proxy's GoogleAccessToken)"
fi
if [ "$HAVE_TOKEN" = 1 ]; then
  for p in "${PROXIES[@]}"; do
    code=$(api GET "/environments/${APIGEE_ENV}/apis/${p}/deployments")
    echo "   $p@$APIGEE_ENV: HTTP $code $(python3 -c 'import json,sys; print([(d.get("revision"),d.get("state","")) for d in json.load(open(sys.argv[1])).get("deployments",[])])' "$TMP/body" 2>/dev/null || true)"
  done
  for p in "$BUREAU_PROXY"; do
    code=$(api GET "/environments/${APIGEE_ENV}/apis/${p}/deployments")
    echo "   $p@$APIGEE_ENV: HTTP $code $(python3 -c 'import json,sys; print([(d.get("revision"),d.get("state","")) for d in json.load(open(sys.argv[1])).get("deployments",[])])' "$TMP/body" 2>/dev/null || true)"
  done
  [ "$WITH_EXTPROC" = 1 ] || { echo "✅ Done. Product/attribute changes reach the runtime cache in ~3 minutes; then run ./scripts/test-apigee.sh"; exit 0; }
  code=$(api GET "/environments/${EXTPROC_ENV}/apis/${EXTPROC_PROXY}/deployments")
  echo "   $EXTPROC_PROXY@$EXTPROC_ENV: HTTP $code $(python3 -c 'import json,sys; print([(d.get("revision"),d.get("state","")) for d in json.load(open(sys.argv[1])).get("deployments",[])])' "$TMP/body" 2>/dev/null || true)"
fi
echo "✅ Done. Product/attribute changes reach the runtime cache in ~3 minutes; then run ./scripts/test-apigee.sh"
