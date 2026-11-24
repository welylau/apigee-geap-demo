#!/usr/bin/env bash
# ==============================================================================
# scripts/test-apigee.sh - curl acceptance tests for the cymbal-ge-demo Apigee proxies.
# Keys are read from Secret Manager at runtime into 0600 header files (never on argv, never printed).
#
#   token : 401 without/with wrong key, 200 for rm-alice / teller-bob, 400 unknown user, 405 GET
#   mcp   : initialize, notifications (202), tools/list filtering (5 vs 2), S1 balance, tool-not-in-product,
#           user-token-required / -invalid, S4 user-transfer-limit, S7 partner quota (5 ok then 429)
#   llm   : 401s, cymbal-auto -> gemini-3.5-flash / -flash-lite, model-not-allowed, streaming 400,
#           optional S6 budget exhaustion (--s6, spends ~20k tokens)
#   bureau: 401s, handshake passthrough (initialize/notifications/tools/list), S5 paid quota: 3 tools/call ok
#           with handshake calls interleaved (not counted), 4th tools/call -> 429 credit-bureau-quota, handshake
#           still allowed afterwards; CUST-666 response body passes through unmodified (S3 needs it)
#   extproc: OPT-IN (--with-extproc) read-only management checks of the optional ext-proc env
#
# Usage: ./scripts/test-apigee.sh [--s6] [--with-extproc] [--only token|mcp|llm|bureau|extproc]
# Note: the bureau quota is a 1-minute rolling window per app (same agent app as the demo): wait 1 min after
#       this test before running S5 live, and 1 min between runs of this test.
# Env: APIGEE_HOST (default YOUR_APIGEE_HOST), PROJECT_ID, APIGEE_ENV, EXTPROC_ENV
# Note: S7 uses a 1-minute rolling quota; wait 60 s between runs or the first calls may already be 429.
# ==============================================================================
set -uo pipefail

PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
APIGEE_ORG="${APIGEE_ORG:-$PROJECT_ID}"
APIGEE_HOST="${APIGEE_HOST:-YOUR_APIGEE_HOST}"
APIGEE_ENV="${APIGEE_ENV:-YOUR_APIGEE_ENV}"
EXTPROC_ENV="${EXTPROC_ENV:-cymbal-ge-demo-extproc}"
BASE="https://${APIGEE_HOST}/cymbal-ge-demo"
S6=0; ONLY=""; WITH_EXTPROC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --s6) S6=1 ;;
    --with-extproc) WITH_EXTPROC=1 ;;
    --only) ONLY="${2:-}"; shift ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
for bin in curl python3 gcloud; do command -v "$bin" >/dev/null || { echo "❌ $bin not found" >&2; exit 1; }; done
umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

keyfile() { # keyfile SECRET NAME -> writes $TMP/h-NAME ("x-api-key: <key>")
  local v
  v="$(gcloud secrets versions access latest --secret "$1" --project "$PROJECT_ID" 2>/dev/null)" || { echo "❌ cannot read secret $1" >&2; exit 1; }
  printf 'x-api-key: %s\n' "$v" > "$TMP/h-$2"
}
keyfile cymbal-ge-demo-webui-key webui
keyfile cymbal-ge-demo-agent-key agent
keyfile cymbal-ge-demo-partner-key partner
printf 'x-api-key: %s\n' "not-a-real-key" > "$TMP/h-bad"
: > "$TMP/h-none"

# req NAME METHOD URL KEYNAME [BODY_FILE] [EXTRA_HEADER_FILE] -> sets STATUS, POLICY, $TMP/out, $TMP/hdr
req() {
  local name="$1" method="$2" url="$3" key="$4" body="${5:-}" extra="${6:-}"
  local args=(-sS -o "$TMP/out" -D "$TMP/hdr" -w '%{http_code}' -X "$method" -H @"$TMP/h-$key" "$url")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" --data-binary @"$body")
  [ -n "$extra" ] && args+=(-H @"$extra")
  STATUS="$(curl "${args[@]}" 2>/dev/null)" || STATUS="000"
  POLICY="$(hdr x-cymbal-policy)"
}
hdr() { tr -d '\r' < "$TMP/hdr" | awk -v k="$(echo "$1" | tr 'A-Z' 'a-z')" -F': ' 'tolower($1)==k {print $2}' | tail -1; }
check() { # check NAME EXPECTED_STATUS EXPECTED_POLICY [python-assert-on-body]
  local name="$1" es="$2" ep="$3" pyexpr="${4:-}" ok=1 why=""
  [ "$STATUS" = "$es" ] || { ok=0; why="status $STATUS != $es"; }
  if [ -n "$ep" ] && [ "$POLICY" != "$ep" ]; then ok=0; why="$why policy '$POLICY' != '$ep'"; fi
  if [ "$ok" = 1 ] && [ -n "$pyexpr" ]; then
    python3 -c "import json,sys; b=json.load(open(sys.argv[1])) if open(sys.argv[1]).read().strip() else None; assert ($pyexpr)" "$TMP/out" 2>/dev/null \
      || { ok=0; why="body check failed: $pyexpr"; }
  fi
  if [ "${STATUS:-0}" -ge 400 ] 2>/dev/null && grep -qiE 'faultstring|"policies\.|steps\.|verifyapikey\.' "$TMP/out" 2>/dev/null; then
    ok=0; why="$why native fault leaked"
  fi
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); printf '  ✅ %-58s %s %s\n' "$name" "$STATUS" "$POLICY"
  else FAIL=$((FAIL+1)); printf '  ❌ %-58s %s\n' "$name" "$why"; head -c 300 "$TMP/out" | sed 's/^/       /'; echo; fi
}
json() { python3 -c "import json,sys; print(json.dumps($1))" > "$TMP/$2.json"; echo "$TMP/$2.json"; }
rpc() { json "{'jsonrpc':'2.0','id':$1,'method':'$2','params':$3}" "rpc$1"; }
tool() { rpc "$1" tools/call "{'name':'$2','arguments':$3}"; }
run() { if [ -n "$ONLY" ]; then [ "$ONLY" = "$1" ]; elif [ "$1" = extproc ]; then [ "$WITH_EXTPROC" = 1 ]; else true; fi; }

# ---------------------------------------------------------------- token
if run token || run mcp; then
  echo "🔑 cymbal-ge-demo-token"
  ALICE="$(json "{'user':'rm-alice'}" alice)"; BOB="$(json "{'user':'teller-bob'}" bob)"
  req t1 POST "$BASE/token" none "$ALICE"; check "no x-api-key -> 401" 401 invalid-api-key
  req t2 POST "$BASE/token" partner "$ALICE"; check "partner key (not on webui product) -> 401" 401 invalid-api-key
  req t3 POST "$BASE/token" webui "$(json "{'user':'mallory'}" mallory)"; check "unknown user -> 400" 400 unknown-user
  req t4 GET "$BASE/token" webui; check "GET -> 405" 405 method-not-allowed
  req t5 POST "$BASE/token" webui "$ALICE"; check "rm-alice -> 200 JWT" 200 token-issued "b['expires_in']==900 and b['access_token'].count('.')==2"
  python3 -c 'import json,sys; print("x-user-token: "+json.load(open(sys.argv[1]))["access_token"])' "$TMP/out" > "$TMP/u-alice" 2>/dev/null || : > "$TMP/u-alice"
  req t6 POST "$BASE/token" webui "$BOB"; check "teller-bob -> 200 JWT" 200 token-issued
  python3 -c 'import json,sys; print("x-user-token: "+json.load(open(sys.argv[1]))["access_token"])' "$TMP/out" > "$TMP/u-bob" 2>/dev/null || : > "$TMP/u-bob"
  printf 'x-user-token: %s\n' "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.invalid" > "$TMP/u-bogus"
fi

# ---------------------------------------------------------------- mcp
if run mcp; then
  echo "🏦 cymbal-ge-demo-mcp-banking"
  M="$BASE/mcp/banking"
  req m1 POST "$M" agent "$(rpc 1 initialize "{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'test-apigee','version':'1'}}")"
  check "initialize -> 200" 200 allow "b['result']['serverInfo']['name']=='cymbal-ge-demo-mcp-banking'"
  req m2 POST "$M" agent "$(json "{'jsonrpc':'2.0','method':'notifications/initialized'}" notif)"; check "notifications/initialized -> 202" 202 allow
  req m3 POST "$M" agent "$(rpc 3 tools/list '{}')"; check "tools/list internal -> 5 tools" 200 allow "len(b['result']['tools'])==5"
  req m4 POST "$M" partner "$(rpc 4 tools/list '{}')"
  check "tools/list partner -> 2 tools (filtered)" 200 tools-filtered "sorted(t['name'] for t in b['result']['tools'])==['get_account_summary','get_fx_rate']"
  req m5 POST "$M" partner "$(tool 5 get_account_balance "{'account_id':'1234'}")"
  check "partner get_account_balance -> 403" 403 tool-not-in-product "b['error']['code']==-32001 and b['error']['data']=={'decided_by':'apigee','policy':'tool-not-in-product'} and b['id']==5"
  req m6 POST "$M" agent "$(tool 6 get_account_balance "{'account_id':'1234'}")"; check "internal call without x-user-token -> 401" 401 user-token-required
  req m7 POST "$M" agent "$(tool 7 get_account_balance "{'account_id':'1234'}")" "$TMP/u-bogus"; check "invalid x-user-token -> 401" 401 user-token-invalid
  req m8 POST "$M" agent "$(tool 8 get_account_balance "{'account_id':'1234'}")" "$TMP/u-alice"
  check "S1 rm-alice balance 1234 -> 200" 200 allow "b['result']['structuredContent']['balance']==182450.2"
  req m9 POST "$M" agent "$(tool 9 transfer_funds "{'from_account':'1234','to_account':'5678','amount':50000,'memo':'S4'}")" "$TMP/u-bob"
  check "S4 teller-bob transfer 50,000 -> 403" 403 user-transfer-limit "b['error']['data']['policy']=='user-transfer-limit'"
  req m10 POST "$M" agent "$(tool 10 transfer_funds "{'from_account':'1234','to_account':'5678','amount':500}")" "$TMP/u-alice"
  check "rm-alice transfer 500 -> 200 (simulated)" 200 allow "b['result']['structuredContent']['status']=='accepted'"
  req m11 POST "$M" agent "$(rpc 11 resources/list '{}')"; check "unsupported method -> 400 -32601" 400 method-not-found
  req m12 GET "$M" agent; check "GET (no SSE) -> 405" 405 method-not-allowed
  echo "   S7: FinPal get_account_summary x6 (partner quota 5/min)"
  codes=""
  for i in 1 2 3 4 5 6; do
    req "s7-$i" POST "$M" partner "$(tool $((20+i)) get_account_summary "{'account_id':'1234'}")"; codes="$codes $STATUS"
  done
  check "S7 6th call -> 429 product-quota (codes:$codes)" 429 product-quota "b['error']['data']['policy']=='product-quota'"
  case "$codes" in " 200"*) ;; *) echo "   ⚠️  first S7 call was not 200: quota window still active from a previous run?";; esac
fi

# ---------------------------------------------------------------- llm
if run llm; then
  echo "🤖 cymbal-ge-demo-llm"
  L="$BASE/llm/v1/projects/${PROJECT_ID}/locations/global/publishers/google/models"
  SHORT="$(json "{'contents':[{'role':'user','parts':[{'text':'Reply with the single word OK.'}]}],'generationConfig':{'maxOutputTokens':32}}" short)"
  LONG="$(json "{'contents':[{'role':'user','parts':[{'text':'Summarise in one line: '+('Transfer SGD 120.50 to NTUC FairPrice on 2026-11-01. '*140)}]}],'generationConfig':{'maxOutputTokens':32}}" long)"
  req l1 POST "$L/cymbal-auto:generateContent" none "$SHORT"; check "no x-api-key -> 401" 401 invalid-api-key
  req l2 POST "$L/cymbal-auto:generateContent" partner "$SHORT"; check "partner key (not on product) -> 401" 401 invalid-api-key
  req l3 POST "$L/cymbal-auto:generateContent" agent "$SHORT"
  check "cymbal-auto short -> gemini-3.5-flash" 200 model-routing "'candidates' in b"
  echo "     x-cymbal-model=$(hdr x-cymbal-model) x-cymbal-tokens-used=$(hdr x-cymbal-tokens-used)"
  [ "$(hdr x-cymbal-model)" = gemini-3.5-flash ] || { FAIL=$((FAIL+1)); echo "  ❌ expected x-cymbal-model gemini-3.5-flash"; }
  req l4 POST "$L/cymbal-auto:generateContent" agent "$LONG"
  check "cymbal-auto >6000 chars -> gemini-3.5-flash-lite" 200 model-routing
  echo "     x-cymbal-model=$(hdr x-cymbal-model) x-cymbal-tokens-used=$(hdr x-cymbal-tokens-used)"
  [ "$(hdr x-cymbal-model)" = gemini-3.5-flash-lite ] || { FAIL=$((FAIL+1)); echo "  ❌ expected x-cymbal-model gemini-3.5-flash-lite"; }
  req l5 POST "$L/gemini-2.5-pro:generateContent" agent "$SHORT"; check "model outside allowlist -> 400" 400 model-not-allowed
  req l6 POST "$L/cymbal-auto:streamGenerateContent" agent "$SHORT"; check "streaming -> 400" 400 streaming-not-supported
  req l7 POST "$BASE/llm/v1/projects/${PROJECT_ID}/locations/us-central1/publishers/google/models/cymbal-auto:generateContent" agent "$SHORT"
  check "non-global location -> 400" 400 location-not-allowed
  if [ "$S6" = 1 ]; then
    echo "   S6: long prompts until the per-app token budget (product llmQuota) is exhausted"
    BIG="$(json "{'contents':[{'role':'user','parts':[{'text':'Summarise these transactions in one line: '+('2026-11-01 NTUC FairPrice -120.50 SGD; '*600)}]}],'generationConfig':{'maxOutputTokens':32}}" big)"
    for i in $(seq 1 10); do
      req "s6-$i" POST "$L/cymbal-auto:generateContent" agent "$BIG"
      echo "     call $i: $STATUS $POLICY model=$(hdr x-cymbal-model) tokens=$(hdr x-cymbal-tokens-used)"
      [ "$STATUS" = 429 ] && break
    done
    check "S6 budget exhausted -> 429 llm-token-budget" 429 llm-token-budget "b['error']['decided_by']=='apigee'"
  else
    echo "   (S6 budget exhaustion skipped; run with --s6)"
  fi
fi

# ---------------------------------------------------------------- credit bureau (S5)
if run bureau; then
  echo "🏛  cymbal-ge-demo-credit-bureau"
  B="$BASE/bureau"
  INIT="$(rpc 401 initialize "{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'test-apigee','version':'1'}}")"
  LIST="$(rpc 402 tools/list '{}')"
  req b1 POST "$B" none "$LIST"; check "no x-api-key -> 401" 401 invalid-api-key "b['error']['data']['decided_by']=='apigee'"
  req b2 POST "$B" partner "$LIST"; check "partner key (not on internal product) -> 401" 401 invalid-api-key
  req b3 GET "$B" agent; check "GET -> 405" 405 method-not-allowed
  printf '%s' '{"jsonrpc":' > "$TMP/badjson.json"
  req b4 POST "$B" agent "$TMP/badjson.json"; check "malformed JSON -> 400 parse-error" 400 parse-error "b['error']['code']==-32700"
  req b5 POST "$B" agent "$INIT"; check "initialize passthrough -> 200" 200 allow "'result' in b"
  [ "$(hdr x-cymbal-upstream)" = credit-bureau ] || { FAIL=$((FAIL+1)); echo "  ❌ expected x-cymbal-upstream: credit-bureau"; }
  req b6 POST "$B/mcp" agent "$(json "{'jsonrpc':'2.0','method':'notifications/initialized'}" bnotif)"; check "notifications/initialized -> 202 (path /mcp too)" 202 ""
  echo "   S5: 3 paid lookups with handshake calls in between, then the 4th lookup"
  req s5-1 POST "$B" agent "$(tool 411 get_credit_report "{'customer_id':'CUST-101'}")"; check "lookup 1 (CUST-101) -> 200" 200 allow "'result' in b"
  req s5-h1 POST "$B" agent "$LIST"; check "tools/list between lookups -> 200 (not counted)" 200 allow
  req s5-2 POST "$B" agent "$(tool 412 get_credit_report "{'customer_id':'CUST-102'}")"; check "lookup 2 (CUST-102) -> 200" 200 allow
  req s5-h2 POST "$B" agent "$INIT"; check "initialize between lookups -> 200 (not counted)" 200 allow
  req s5-3 POST "$B" agent "$(tool 413 get_credit_report "{'customer_id':'CUST-666'}")"
  check "lookup 3 (CUST-666) -> 200, poisoned body passed through unchanged" 200 allow "'IGNORE ALL PREVIOUS INSTRUCTIONS' in json.dumps(b)"
  req s5-4 POST "$B" agent "$(tool 414 get_credit_report "{'customer_id':'CUST-104'}")"
  check "lookup 4 within 1 min -> 429 credit-bureau-quota" 429 credit-bureau-quota "b['id']==414 and b['error']['code']==-32001 and b['error']['data']=={'decided_by':'apigee','policy':'credit-bureau-quota'}"
  req s5-h3 POST "$B" agent "$LIST"; check "tools/list after quota exhausted -> 200 (handshake free)" 200 allow
fi

# ---------------------------------------------------------------- extproc (OPT-IN, management plane, read-only)
if run extproc; then
  echo "🧩 cymbal-ge-demo-extproc (read-only checks)"
  printf 'Authorization: Bearer %s\n' "$(gcloud auth application-default print-access-token)" > "$TMP/auth"
  A="https://apigee.googleapis.com/v1/organizations/${APIGEE_ORG}"
  STATUS="$(curl -sS -o "$TMP/out" -D "$TMP/hdr" -w '%{http_code}' -H @"$TMP/auth" "$A/environments/${EXTPROC_ENV}")"; POLICY=""
  check "env has apigee-service-extension-enabled=true" 200 "" "{p['name']:p['value'] for p in b['properties']['property']}.get('apigee-service-extension-enabled')=='true'"
  STATUS="$(curl -sS -o "$TMP/out" -D "$TMP/hdr" -w '%{http_code}' -H @"$TMP/auth" "$A/environments/${EXTPROC_ENV}/apis/cymbal-ge-demo-extproc/deployments")"
  check "ext-proc proxy deployed READY" 200 "" "any(d.get('state')=='READY' for d in b.get('deployments',[]))"
  STATUS="$(curl -sS -o "$TMP/out" -D "$TMP/hdr" -w '%{http_code}' -H @"$TMP/auth" "$A/envgroups/cymbal-ge-demo-extproc-grp")"
  check "envgroup host apigee-extproc.cymbal-ge-demo.internal" 200 "" "'apigee-extproc.cymbal-ge-demo.internal' in b['hostnames']"
  echo "   (ext-proc is optional and not part of the demo; S5 is enforced by cymbal-ge-demo-credit-bureau)"
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
