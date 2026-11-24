#!/usr/bin/env bash
# 08 - BigQuery data for scenario 8 ("the agent reads BigQuery as itself").
#   cymbal_kyc.customer_risk       demo KYC / AML risk ratings (CUST-101..104)
#   cymbal_hr.staff_compensation   demo staff pay (rm-alice, teller-bob)
# IAM, granted to the RM Agent's own Agent Identity principal only (no service account, no key):
#   roles/bigquery.dataViewer on TABLE cymbal_kyc.customer_risk   (table-level IAM policy)
#   roles/bigquery.jobUser    on the project                       (to run query jobs)
# Nothing is granted on cymbal_hr, so the agent's HR lookup is refused by IAM (403 Access Denied).
# All data is fictional. Idempotent: datasets/tables/rows/bindings are created only when missing.
#   ./infra/08-bigquery.sh [--dry-run]
# Prereq: agent/.deployed.json (the RM Agent principal). Teardown: 99-teardown.sh (y/N).
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"

banner "08 BigQuery datasets + Agent Identity IAM (scenario 8)"
LABEL="datacloud:antigravity"
[[ -n "$(agent_engine_id)" ]] || die "agent/.deployed.json missing: deploy the RM Agent first (agent/deploy.py)"
PRINCIPAL="$(agent_principal)"
note "agent principal: ${PRINCIPAL}"

ensure_dataset() {  # ensure_dataset <dataset> <description>
  if quiet bq --project_id="${PROJECT_ID}" show --dataset "${PROJECT_ID}:$1"; then
    ok "dataset $1 exists"
  else
    plan "create dataset $1 (${REGION})"
    run bq --project_id="${PROJECT_ID}" --location="${REGION}" mk --dataset --label "${LABEL}" \
      --label demo:cymbal-ge-demo --description "$2" "${PROJECT_ID}:$1"
  fi
}

ensure_table() {  # ensure_table <dataset.table> <schema> <insert-values-sql>
  if quiet bq --project_id="${PROJECT_ID}" show "${PROJECT_ID}:$1"; then
    ok "table $1 exists"
  else
    plan "create table $1 + demo rows"
    run bq --project_id="${PROJECT_ID}" --location="${REGION}" mk --table --label "${LABEL}" \
      --label demo:cymbal-ge-demo "${PROJECT_ID}:$1" "$2"
    run bq --project_id="${PROJECT_ID}" --location="${REGION}" query --use_legacy_sql=false --label "${LABEL}" \
      "INSERT INTO \`${PROJECT_ID}.$1\` VALUES $3"
  fi
}

ensure_dataset cymbal_kyc "Cymbal GE demo: customer KYC / AML risk (fictional). The RM Agent may read customer_risk."
ensure_dataset cymbal_hr "Cymbal GE demo: staff compensation (fictional). No agent has access."

ensure_table cymbal_kyc.customer_risk \
  "id:STRING,customer_name:STRING,risk_rating:STRING,kyc_status:STRING,pep:BOOLEAN,last_review:DATE,next_review:DATE" \
  "('CUST-101','Tan Wei Ming','LOW','VERIFIED',FALSE,DATE '2026-06-12',DATE '2027-06-12'),
   ('CUST-102','Priya Nair','MEDIUM','VERIFIED',FALSE,DATE '2026-03-02',DATE '2026-12-02'),
   ('CUST-103','Lim Hardware Trading Pte Ltd','MEDIUM','REVIEW_DUE',FALSE,DATE '2025-11-20',DATE '2026-11-20'),
   ('CUST-104','Ahmad Rahman','HIGH','ENHANCED_DUE_DILIGENCE',TRUE,DATE '2026-09-30',DATE '2027-03-30')"

ensure_table cymbal_hr.staff_compensation \
  "id:STRING,staff_name:STRING,role:STRING,base_salary_sgd:NUMERIC,bonus_sgd:NUMERIC" \
  "('rm-alice','Alice Tan','Relationship Manager',148000,36000),
   ('teller-bob','Bob Lim','Teller',52000,6500)"

# Table-level IAM policy (supports principal:// members). Only the KYC table.
TABLE_REF="${PROJECT_ID}:cymbal_kyc.customer_risk"
if bq --project_id="${PROJECT_ID}" get-iam-policy --format=prettyjson "${TABLE_REF}" 2>/dev/null \
   | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(b.get("role")=="roles/bigquery.dataViewer" and sys.argv[1] in b.get("members",[]) for b in d.get("bindings",[])) else 1)' "${PRINCIPAL}"; then
  ok "roles/bigquery.dataViewer on ${TABLE_REF} already granted to the agent"
else
  plan "grant roles/bigquery.dataViewer on ${TABLE_REF} to the agent principal"
  run bq --project_id="${PROJECT_ID}" add-iam-policy-binding --member="${PRINCIPAL}" \
    --role=roles/bigquery.dataViewer "${TABLE_REF}"
fi

if project_has_binding "${PRINCIPAL}" roles/bigquery.jobUser; then
  ok "roles/bigquery.jobUser already granted to the agent"
else
  plan "grant roles/bigquery.jobUser on project ${PROJECT_ID} to the agent principal"
  run gcloud projects add-iam-policy-binding "${PROJECT_ID}" --member="${PRINCIPAL}" \
    --role=roles/bigquery.jobUser --condition=None --quiet --format=none
fi
note "Agent Gateway must also allow bigquery.googleapis.com: re-run 04-uap.sh. IAM can take ~60 s to apply."
ok "done"
