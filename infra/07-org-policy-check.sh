#!/usr/bin/env bash
# 07 - Check the managed org-policy constraint that blocks UAP bindings:
#      constraints/iam.managed.disableAccessPolicyBindings
# (enabled by default for NEW organizations; must be NOT enforced for the
# project, otherwise 04's `gcloud iam policy-bindings create` fails).
# Read-only by default. With --fix it sets a project-level policy enforce:false
# (needs roles/orgpolicy.policyAdmin; asks for confirmation).
# Ref: set-up-agent-gateway.md note, configure-iam-policies-uap.md "Before you begin".
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"
FIX=0; for a in "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"; do [[ "$a" == "--fix" ]] && FIX=1; done

C="iam.managed.disableAccessPolicyBindings"
banner "07 Org policy ${C}"
parent="$(gcloud projects describe "${PROJECT_ID}" --format='value(parent.type,parent.id)' 2>/dev/null || true)"
note "project parent: ${parent:-unknown}"

out="$(gcloud org-policies describe "${C}" --project="${PROJECT_ID}" --effective --format=json 2>&1 || true)"
if grep -q 'NOT_FOUND' <<<"${out}"; then
  ok "no effective policy for ${C} on ${PROJECT_ID} (constraint not set anywhere in the hierarchy) -> UAP bindings allowed"
  exit 0
fi
enforced="$(python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read())
except Exception: print("unknown"); sys.exit()
rules=(d.get("spec") or {}).get("rules") or []
print("true" if any(r.get("enforce") for r in rules) else "false")' <<<"${out}")"
echo "${out}" | head -30
if [[ "${enforced}" == "false" ]]; then ok "${C} is NOT enforced -> UAP bindings allowed"; exit 0; fi
warn "${C} effective enforcement: ${enforced}"
if [[ "${FIX}" != "1" ]]; then
  note "re-run with --fix to set a project-level override (enforce: false)"; exit 1
fi
POL="${STATE_DIR}/rendered/orgpolicy-${C}.yaml"
cat >"${POL}" <<EOF
name: projects/${PROJECT_ID}/policies/${C}
spec:
  rules:
  - enforce: false
EOF
plan "project-level org policy ${C}: enforce=false"
confirm "Set ${C} enforce=false on ${PROJECT_ID}?" || die "aborted"
run gcloud org-policies set-policy "${POL}"
ok "done (propagation can take a few minutes)"
