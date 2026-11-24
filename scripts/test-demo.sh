#!/usr/bin/env bash
# ==============================================================================
# End-to-end checks for the Agents Meet APIs demo (run after deploying).
#   ./scripts/test-demo.sh            # Apigee acceptance + UI (IAP) checks
#   UI_URL=https://cymbal-ge-demo.YOUR_DOMAIN ./scripts/test-demo.sh
# Agent scenarios need a local BFF (./web-ui/run-local.sh), then:
#   LOCAL_BFF=http://127.0.0.1:8080 ROUNDS=5 ./scripts/test-demo.sh
# ==============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI_URL="${UI_URL:-https://YOUR_UI_DOMAIN}"

echo "▶ Apigee acceptance tests"
"$ROOT/scripts/test-apigee.sh"

echo "▶ UI must be behind IAP (never 200 anonymously)"
code=$(curl -s -o /dev/null -w '%{http_code}' "$UI_URL/healthz" || true)
case "$code" in
  302|401|403) echo "  ok  $UI_URL/healthz -> $code (IAP)";;
  *) echo "  FAIL $UI_URL/healthz -> $code (expected 302/401/403)"; exit 1;;
esac

if [ -n "${LOCAL_BFF:-}" ]; then
  echo "▶ All 8 scenarios against $LOCAL_BFF (ROUNDS=${ROUNDS:-1}; 5 for the reliability bar)"
  python3 "$ROOT/scripts/verify-scenarios.py" --bff "$LOCAL_BFF" --rounds "${ROUNDS:-1}"
fi
echo "✅ done"
