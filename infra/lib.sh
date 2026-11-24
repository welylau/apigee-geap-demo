# shellcheck shell=bash
# Shared helpers for infra/NN-*.sh. Source env.sh first.

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
EXTRA_ARGS=()

_c() { if [[ -t 1 ]]; then printf '\033[%sm' "$1"; fi; }
banner() { printf '\n%s== %s ==%s\n' "$(_c '1;34')" "$*" "$(_c 0)"; }
plan()   { printf '  %s[plan]%s %s\n' "$(_c 36)" "$(_c 0)" "$*"; }
note()   { printf '  %s[info]%s %s\n' "$(_c 2)" "$(_c 0)" "$*"; }
ok()     { printf '  %s[ ok ]%s %s\n' "$(_c 32)" "$(_c 0)" "$*"; }
warn()   { printf '  %s[warn]%s %s\n' "$(_c 33)" "$(_c 0)" "$*" >&2; }
die()    { printf '  %s[fail]%s %s\n' "$(_c 31)" "$(_c 0)" "$*" >&2; exit 1; }

usage_common() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--yes] [--help]
  --dry-run   print what would be created/changed; only read-only describe/list calls run
  --yes, -y   do not prompt (teardown / destructive confirmations)
EOF
}

parse_common_flags() {
  EXTRA_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --help|-h) usage_common; exit 0 ;;
      *) EXTRA_ARGS+=("$1") ;;
    esac
    shift
  done
  export DRY_RUN ASSUME_YES
  mkdir -p "${STATE_DIR}/rendered"
  if [[ "${DRY_RUN}" == "1" ]]; then
    note "DRY-RUN: no resources will be created, changed or deleted"
  fi
}

# run <cmd...>: echo the command; execute it unless --dry-run.
run() {
  printf '  %s+%s' "$(_c 35)" "$(_c 0)"
  printf ' %q' "$@"
  printf '\n'
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  "$@"
}

# quiet <cmd...>: run a READ-ONLY command silently, return its exit code.
quiet() { "$@" >/dev/null 2>&1; }

confirm() {  # confirm "question" -> 0 if yes
  if [[ "${ASSUME_YES}" == "1" ]]; then return 0; fi
  if [[ "${DRY_RUN}" == "1" ]]; then return 0; fi
  local ans
  read -r -p "  $1 [y/N] " ans || true
  [[ "${ans}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# render <template-file> <output-file>: substitute ${VAR} from the environment.
# Fails if any placeholder is unresolved (no silent empty strings).
render() {
  local src="$1" dst="$2"
  python3 -c '
import os, re, string, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
missing = sorted({m for m in re.findall(r"\$\{([A-Z_][A-Z0-9_]*)\}", text) if m not in os.environ})
if missing:
    sys.exit("render: unresolved variables in %s: %s" % (src, ", ".join(missing)))
open(dst, "w").write(string.Template(text).substitute(os.environ))
' "$src" "$dst"
  note "rendered $(basename "$src") -> ${dst#"${REPO_DIR}/"}"
}

host_of() { python3 -c 'import sys,urllib.parse as u; print(u.urlparse(sys.argv[1]).hostname or "")' "$1"; }

# credit_bureau_url: https://<cloud-run-host>/mcp (exact host the agent calls).
credit_bureau_url() {
  local url
  url="$(gcloud run services describe "${CREDIT_BUREAU_SERVICE}" --region="${REGION}" \
          --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
  if [[ -z "${url}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      echo "https://${CREDIT_BUREAU_SERVICE}-PENDING.a.run.app/mcp"; return 0
    fi
    die "Cloud Run service ${CREDIT_BUREAU_SERVICE} not found; run credit-bureau/deploy.sh first"
  fi
  echo "${url%/}/mcp"
}

# registry_resource <service-id>: the generated McpServer/Endpoint resource name
# (projects/.../mcpServers/agentregistry-... or .../endpoints/...), no leading slash.
registry_resource() {
  local r
  r="$(gcloud agent-registry services describe "$1" --location="${REGION}" \
        --project="${PROJECT_ID}" --format='value(registryResource)' 2>/dev/null || true)"
  r="${r#//agentregistry.googleapis.com/}"
  r="${r#/}"
  echo "${r}"
}

agent_engine_id() {  # from agent/.deployed.json (written by agent/deploy.py)
  local f="${REPO_DIR}/agent/.deployed.json"
  [[ -f "$f" ]] || { echo ""; return 0; }
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("engine_id",""))' "$f"
}

agent_principal() {  # individual principal if deployed, else project principal set
  local id
  id="$(agent_engine_id)"
  if [[ -n "${id}" ]]; then
    echo "principal://${TRUST_DOMAIN}/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${id}"
  else
    echo "${AGENT_PRINCIPAL_SET}"
  fi
}

insights_principal() {  # Insights Agent (scenario 7) principal, empty if not deployed
  local f="${REPO_DIR}/agent/.deployed-insights.json" id
  [[ -f "$f" ]] || { echo ""; return 0; }
  id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("engine_id",""))' "$f")"
  [[ -n "${id}" ]] && echo "principal://${TRUST_DOMAIN}/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${id}"
  return 0
}

access_token() { gcloud auth print-access-token 2>/dev/null; }

# project_has_binding <member> <role>: 0 if the project policy has an
# UNCONDITIONAL binding of exactly <role> to exactly <member> (read-only).
project_has_binding() {
  gcloud projects get-iam-policy "${PROJECT_ID}" --format=json 2>/dev/null | python3 -c '
import json, sys
member, role = sys.argv[1], sys.argv[2]
p = json.load(sys.stdin)
ok = any(b.get("role") == role and "condition" not in b and member in b.get("members", [])
         for b in p.get("bindings", []))
sys.exit(0 if ok else 1)' "$1" "$2"
}

# secret_has_binding <secret> <member> <role>: same check on a secret's IAM policy.
secret_has_binding() {
  gcloud secrets get-iam-policy "$1" --project="${PROJECT_ID}" --format=json 2>/dev/null | python3 -c '
import json, sys
member, role = sys.argv[1], sys.argv[2]
p = json.load(sys.stdin)
ok = any(b.get("role") == role and "condition" not in b and member in b.get("members", [])
         for b in p.get("bindings", []))
sys.exit(0 if ok else 1)' "$2" "$3"
}
