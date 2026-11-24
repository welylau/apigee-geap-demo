#!/usr/bin/env bash
# 02c - Grant the basic roles that a gateway-bound AGENT_IDENTITY runtime needs
#       in order to START, to all agents in this project (AGENT_PRINCIPAL_SET):
#         roles/browser                          resourcemanager.projects.get during SDK init
#         roles/serviceusage.serviceUsageConsumer quota / SDK usage
#         roles/logging.logWriter                container stdout/stderr -> Cloud Logging
#         roles/monitoring.metricWriter          metrics
#         roles/agentregistry.viewer             read registered destinations
#       Without these, agent/deploy.py fails with "The Reasoning Engine's container
#       failed to start" and there are NO runtime logs (no logWriter).
#       Sources: troubleshoot-agent-gateway.md ("Errors during Agent Runtime
#       startup"), agent-identity.md ("Grant access to an agent").
#       roles/aiplatform.user is deliberately NOT granted (least privilege, per
#       agent-identity.md). Idempotent: existing bindings are skipped.
#   ./infra/02c-agent-identity-roles.sh [--dry-run]
# Run BEFORE agent/deploy.py. Teardown (99) removes exactly these bindings (y/N).
set -euo pipefail
source "$(dirname "$0")/env.sh"
source "$(dirname "$0")/lib.sh"
parse_common_flags "$@"

banner "02c agent identity basic roles"
note "member: ${AGENT_PRINCIPAL_SET}"
for role in ${AGENT_IDENTITY_ROLES}; do
  if project_has_binding "${AGENT_PRINCIPAL_SET}" "${role}"; then
    ok "${role} already granted"
  else
    plan "grant ${role}"
    run gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="${AGENT_PRINCIPAL_SET}" --role="${role}" --condition=None --quiet --format=none
  fi
done

# Secret-scoped (NOT project-wide): with AGENT_IDENTITY, a secret referenced as an
# env var (CYMBAL_AGENT_API_KEY) must be readable by the agent identity AND by the
# Agent Platform service agent (agent-identity.md "Grant access to an agent").
# Without it the container never starts and writes no logs.
SECRET_ROLE="roles/secretmanager.secretAccessor"
for secret in "${AGENT_SECRET}" "${INSIGHTS_SECRET}"; do   # RM Agent key, Insights Agent key (scenario 7)
  if quiet gcloud secrets describe "${secret}" --project="${PROJECT_ID}"; then
    for member in "${AGENT_PRINCIPAL_SET}" "serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com"; do
      if secret_has_binding "${secret}" "${member}" "${SECRET_ROLE}"; then
        ok "${SECRET_ROLE} on secret ${secret} already granted to ${member}"
      else
        plan "grant ${SECRET_ROLE} on secret ${secret} to ${member}"
        run gcloud secrets add-iam-policy-binding "${secret}" --project="${PROJECT_ID}" \
          --member="${member}" --role="${SECRET_ROLE}" --condition=None --quiet --format=none
      fi
    done
  else
    warn "secret ${secret} not found - create it (scripts/setup-apigee.sh) and re-run 02c before agent/deploy.py"
  fi
done
note "IAM propagation can take ~60s; wait before running agent/deploy.py."
