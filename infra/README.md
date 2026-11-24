# infra/ - Agent Gateway side of "Agents Meet APIs: Agent Gateway x Apigee"

Numbered, idempotent bash scripts plus YAML/JSON templates. They set up everything
the RM Agent's egress needs in `YOUR_PROJECT_ID` / `asia-southeast1`.

- Every script uses `set -euo pipefail`, sources [env.sh](env.sh), which holds the fixed
  values, and accepts `--dry-run`. In dry-run mode only read-only describe/list
  calls run.
- Each script prints a `[plan]` line for every resource it would create. Rendered files go to
  `infra/.state/rendered/`, which is gitignored.
- gcloud runs with `CLOUDSDK_CONFIG=~/.config/gcloud` and the
  `adc-YOUR_PROJECT_ID.json` ADC. env.sh refuses to run with `~/.config/gcloud-argolis`.

> [!IMPORTANT]
> Nothing here has been applied yet. Run it only after approval, in the order below.

## Order of operations

| # | Command | Creates | Role in the story |
|---|---|---|---|
| 0 | `infra/07-org-policy-check.sh` | nothing (read-only; `--fix` sets a project override) | UAP bindings are blocked if `iam.managed.disableAccessPolicyBindings` is enforced. The read-only check found no policy on this project's hierarchy, so it should pass. |
| 1 | `infra/00-apis.sh` | enables any missing APIs | |
| 2 | `credit-bureau/deploy.sh` | Cloud Run `cymbal-ge-demo-credit-bureau` (public, max 1 instance) | The mock third-party SaaS. It is the **target** of the Apigee proxy `/cymbal-ge-demo/bureau/mcp` (built by the apigee/ owner). The agent never calls it directly. |
| 3 | `infra/01-model-armor.sh [--test]` | Model Armor template `cymbal-ge-demo-ma`, plus 3 role grants to `service-YOUR_PROJECT_NUMBER@gcp-sa-dep` | The content-safety floor (S3) |
| 4 | `infra/02-agent-gateway.sh` | `cymbal-ge-demo-agw` (AGENT_TO_ANYWHERE, regional registry), authz extension `cymbal-ge-demo-iap-authz-dryrun` (IAP V2, **DRY_RUN**), REQUEST_AUTHZ policy `cymbal-ge-demo-iap-policy` | The agent's only way out. It checks agent identity against the UAP. |
| 5 | `infra/03-registry.sh` | registry services `cymbal-ge-demo-mcp-banking` (MCP, `…/mcp/banking`), `cymbal-ge-demo-credit-bureau` (MCP, Apigee URL `https://YOUR_APIGEE_HOST/cymbal-ge-demo/bureau/mcp`) and `cymbal-ge-demo-llm` (endpoint). Writes `.state/registry.env`. | The approved destinations. The apihub entry `mcp-proxy-dev` is never touched. |
| 6 | `infra/04-uap.sh` | UAP `cymbal-ge-demo-agent-egress` + project binding | Allows the agent to reach the 3 registered destinations and the 20 essential platform hosts, and nothing else (S2) |
| 7 | `infra/05-model-armor-authz.sh` | `cymbal-ge-demo-ma-authz` + CONTENT_AUTHZ `cymbal-ge-demo-ma-policy` (host `YOUR_APIGEE_HOST`, path prefixes `/cymbal-ge-demo/mcp/` and `/cymbal-ge-demo/bureau/`) | Model Armor on `tools/call` requests and responses. S3: the poisoned CUST-666 report flows Cloud Run → Apigee → Agent Gateway, where Model Armor blocks it. |
| (opt) | `infra/06-apigee-extproc.sh --enable-extproc` — **OPTIONAL, not in the default order** (the Apigee org is at its 2-environment limit, so there is no ext-proc env). Without the flag it exits immediately. With it, it registers `cymbal-ge-demo-credit-bureau-direct` (the Cloud Run URL) and creates | network attachment, PSC address/endpoint, private zone + A record, 2 role grants to the gateway service agent, gateway `networkConfig` (export, edit, import), `cymbal-ge-demo-apigee-authz` + CONTENT_AUTHZ `cymbal-ge-demo-apigee-policy` (credit-bureau host only) | Apigee meters the paid third-party call without proxying it (S5). Needs an Apigee ext-proc env/envgroup/proxy, then `agent/deploy.py --direct-bureau` and a re-run of 04 (which adds the direct-bureau rule). |
| 7b | `infra/02c-agent-identity-roles.sh` | 5 project role grants to the agent principal set (all agents in the project): Browser, Service Usage Consumer, Logs Writer, Monitoring Metric Writer, Agent Registry Viewer; plus Secret Manager Secret Accessor on the secret `cymbal-ge-demo-agent-key` only (agent principal set and the Agent Platform service agent). Idempotent. Wait ~60s for propagation. | Without these the gateway-bound agent fails with "container failed to start" and writes no logs at all (no Browser: the SDK cannot resolve the project; no Logs Writer: no stdout/stderr; no secret accessor for the agent identity: the secret env var cannot be resolved and the container never launches). |
| 8 | `agent/.venv/bin/python agent/deploy.py` | reasoning engine `cymbal-ge-demo-rm-agent` (AGENT_IDENTITY, egress bound to the gateway, **min_instances 0** = scale to zero, max 2). Writes `agent/.deployed.json`. | The RM Agent |
| 9 | `infra/04-uap.sh` (re-run) | narrows the UAP principal from "all agents in the project" to the single engine | Least privilege |
| 10 | Run S1–S6 while still in DRY_RUN and read the IAP logs (see below) | | Confirms the allowlist is complete |
| 11 | `infra/02b-enforce-iap.sh` (`--rollback` reverts) | `cymbal-ge-demo-iap-authz-enforced`, then repoints the policy to it | Turns the S2 deny into a real block |
| — | `infra/99-teardown.sh [--include-agent] [--yes]` | deletes in reverse order, asking y/N per step | |

**Before step 8** (after 7b): the secret `cymbal-ge-demo-agent-key` must exist (the Apigee side creates it; it did not exist at review time). Then grant the Agent Platform service agent access so it can inject the secret as an env var at deploy time:
```bash
gcloud secrets add-iam-policy-binding cymbal-ge-demo-agent-key --project=YOUR_PROJECT_ID \
  --member=serviceAccount:service-YOUR_PROJECT_NUMBER@gcp-sa-aiplatform.iam.gserviceaccount.com \
  --role=roles/secretmanager.secretAccessor
```

**Dry-run audit before enforcing:**
```bash
gcloud logging read 'protoPayload.serviceName="iap.googleapis.com" AND protoPayload.metadata.iapPolicyVersion="v2" AND protoPayload.authorizationInfo.granted=false' --project=YOUR_PROJECT_ID --limit=50 \
  --format='table(timestamp,protoPayload.authorizationInfo[0].resource,labels."iap.googleapis.com/audited_resource_name")'
gcloud logging read 'resource.type="networkservices.googleapis.com/Gateway" AND httpRequest.requestUrl:*' --project=YOUR_PROJECT_ID --limit=100 \
  --format='value(httpRequest.status,jsonPayload.authzPolicyInfo.result,httpRequest.requestUrl)' | sort -u
```
Any host that appears with `granted=false` other than the webhook (for example `oauth2.googleapis.com`) has to be added to the 4th rule of [uap-agent-egress.json](templates/uap-agent-egress.json) before you enforce.

## How the policies fit together on the gateway

An egress gateway allows at most **4** authorization policies. The default setup uses 2; the optional ext-proc variant adds a third:

| Profile | Policy | Extension | Scope |
|---|---|---|---|
| REQUEST_AUTHZ | `cymbal-ge-demo-iap-policy` | IAP (`iapPolicyVersion: V2`) | all egress (UAP decides) |
| CONTENT_AUTHZ | `cymbal-ge-demo-ma-policy` | Model Armor (`cymbal-ge-demo-ma` on requests and responses) | `YOUR_APIGEE_HOST` paths `/cymbal-ge-demo/mcp/*` and `/cymbal-ge-demo/bureau/*` |
| CONTENT_AUTHZ (optional) | `cymbal-ge-demo-apigee-policy` | Apigee ext-proc (`cymbal-ge-demo-extproc` proxy) | direct Cloud Run `<bureau-host>/mcp` only |

- **More than one CONTENT_AUTHZ policy is supported on egress.** Ingress gateways allow only one.
- **Evaluation order:** REQUEST_AUTHZ runs first, then CONTENT_AUTHZ. The order among policies with the **same** profile is **not guaranteed**.
- **Effect on the demo:** every extension must allow a call. In the default flow S5 is decided by the Apigee bureau proxy behind the gateway (429 + `x-cymbal-decided-by: apigee`, `x-cymbal-policy: credit-bureau-quota` after 3 `tools/call` per 2 min). For S3 the request passes Apigee (quota permitting) and the gateway's Model Armor blocks the *response* on its way back to the agent.
- Sources: delegate-authorization.md, "Recommended ingress and egress configuration", "Policy evaluation on egress" and "Limitations".

## How `decided_by` is inferred (RM Agent tools)

[mcp_client.py](../agent/rm_agent/mcp_client.py) applies these rules in order. The first match wins.

1. **Header:** `x-cymbal-decided-by` (+ `x-cymbal-policy`). Apigee sets it on every decision. The credit bureau sets `backend` on its own errors.
2. **Body:** a `decided_by` field at `.decided_by`, `.error.decided_by` or `.error.data.decided_by`. This covers the Apigee JSON-RPC errors and the ext-proc deny body `{"error":{"decided_by":"apigee-extproc",...}}`.
3. **HTTP 4xx or 498 with no marker** → `agent-gateway`. The policy is set as follows:
   - `model-armor` if the body contains `cymbal-model-armor` (the template's custom block message), "model armor" or "sanitiz".
   - `egress-not-authorized` for the documented IAP/UAP body.
   - `gateway-498` for status 498.
   - `gateway-<status>` otherwise.
   - Exception, optional ext-proc variant only (`CYMBAL_CREDIT_BUREAU_DIRECT=1`): a bare 429 from the direct Cloud Run bureau → `apigee-extproc` / `credit-bureau-quota (inferred)`. In the default flow, Apigee sends its header, so S5 classifies as `apigee/credit-bureau-quota`.
4. **5xx with no marker**, or a JSON-RPC error / `isError` result on HTTP 2xx → `backend`.
5. **Success** → `ok: true`, `decided_by: null`.
6. **Transport failure** (reset, DNS, timeout) → `decided_by: null`, `policy: "transport-error"`.

LLM calls go through ADK's `on_model_error_callback`. It uses the same classifier and emits a final event with `error_code` (for example `"429"`) and an `error_message` that contains `decided_by=<layer> policy=<policy>`.

## What an Agent Gateway denial looks like

- **IAP/UAP egress deny** (troubleshoot-agent-gateway.md, "403 Forbidden errors"). The response is HTTP **403** with this body:
  ```json
  {"code": 403, "message": "403 Forbidden. {'message': 'Egress request is not authorized.', 'status': 'Forbidden'}"}
  ```
  The gateway log entry (`resource.type="networkservices.googleapis.com/Gateway"`) shows `httpRequest.status=403` and `jsonPayload.authzPolicyInfo.result=DENIED`, plus `jsonPayload.agentGatewayInfo.mcpInfo.method/parameter` for MCP calls. The egress codelab adds that IAP returns "HTTP 403 Forbidden" when it denies a request.
- **Platform calls before the essential hosts are allowlisted:** the docs say agent invocations fail with **498** once the gateway is enforcing (agent-gateway-runtime-deploy.md, caution in step 3). That is why the gateway starts in DRY_RUN.
- **Model Armor block:** the docs do not state the status code or body the gateway returns. The template therefore sets a custom block code (`403`) and a custom message starting with `cymbal-model-armor:`, so the tool can recognise it if the gateway passes it through. If it does not, the result is still attributed to `agent-gateway`, with policy `gateway-403`.
- **Apigee bureau quota (default S5):** this is an ordinary upstream response (429 + `x-cymbal-*` headers). The gateway forwards upstream responses, so it classifies as `apigee`. (Optional ext-proc variant: whether the gateway relays the callout's 429 status/body unchanged is unverified; the inferred rule covers it.)

## IAM / roles

| Who | Roles | Why |
|---|---|---|
| Operator running the scripts | Network Services Admin (`roles/networkservices.admin`), Service Extensions Admin (`roles/networkservices.serviceExtensionsAdmin`), Network Security Admin (`roles/networksecurity.admin`), Compute Network Admin (`roles/compute.networkAdmin`, includes `compute.networkAttachments.use`), DNS Admin (`roles/dns.admin`), Model Armor Admin (`roles/modelarmor.admin`), Agent Registry Editor (`roles/agentregistry.editor`), Access Policy Admin (`roles/iam.accessPolicyAdmin`), Project IAM Admin (`roles/resourcemanager.projectIamAdmin`), Cloud Run Admin (`roles/run.admin`) + Cloud Build Editor (`roles/cloudbuild.builds.editor`), Agent Platform user (`roles/aiplatform.user`) or admin, Apigee Org Admin (`roles/apigee.admin`, read instances/envgroups) | set-up-agent-gateway.md, extension-processor-agent-gateway.md, configure-iam-policies-uap.md |
| `service-YOUR_PROJECT_NUMBER@gcp-sa-dep.iam.gserviceaccount.com` | Model Armor Callout User (`roles/modelarmor.calloutUser`), Service Usage Consumer (`roles/serviceusage.serviceUsageConsumer`), Model Armor User (`roles/modelarmor.user`) | Model Armor callouts (granted by 01) |
| `service-YOUR_PROJECT_NUMBER@gcp-sa-agentgateway.iam.gserviceaccount.com` | Compute Network Viewer (`roles/compute.networkViewer`), DNS Reader (`roles/dns.reader`) | Validates DNS peering and the attachment subnet (granted by 06) |
| `service-YOUR_PROJECT_NUMBER@gcp-sa-aiplatform.iam.gserviceaccount.com` | Secret Manager Secret Accessor (`roles/secretmanager.secretAccessor`) on `cymbal-ge-demo-agent-key` | Injects the secret env var at deploy (manual, see above) |
| Agent identity (`principal://agents.global.org-YOUR_ORG_ID.system.id.goog/resources/aiplatform/projects/YOUR_PROJECT_NUMBER/locations/asia-southeast1/reasoningEngines/<id>`) | default `roles/aiplatform.agentDefaultAccess` and `roles/aiplatform.agentContextEditor`; plus, on the project principal set `principalSet://agents.global.org-YOUR_ORG_ID.system.id.goog/attribute.platformContainer/aiplatform/projects/YOUR_PROJECT_NUMBER`, Browser (`roles/browser`), Service Usage Consumer, Logs Writer, Monitoring Metric Writer and Agent Registry Viewer (granted by 02c; removed by 99 only with y/N), and Secret Manager Secret Accessor on `cymbal-ge-demo-agent-key` (secret-scoped, required for the secret env var with AGENT_IDENTITY). `roles/aiplatform.user` is not granted (least privilege) | troubleshoot-agent-gateway.md |

## Estimated cost drivers (demo scale)

- **Agent Runtime:** `min_instances=0` (scale to zero, user-approved; the first request after idle pays a cold start) and `max_instances=2`. vCPU and memory are billed while it serves requests.
- **Agent Gateway:** Google-managed, billed per gateway and per request processed. Check the current SKU before leaving it running.
- **Model Armor:** charged per sanitized token above the free tier. Only MCP `tools/call` traffic is sent to it.
- **Apigee calls:** banking MCP, bureau proxy and LLM proxy calls in `YOUR_APIGEE_ENV`.
- **Optional ext-proc variant only:** a PSC endpoint (forwarding rule hourly + data processed), a network attachment, a private DNS zone (monthly per zone + queries) and ext-proc calls in a separate Apigee env.
- **Cloud Run credit bureau:** scales to zero, max 1 instance. Cloud Build/Artifact Registry costs apply per deploy.
- **Gemini tokens:** counted at Vertex behind the Apigee LLM proxy, which enforces a small token budget.
- **Teardown:** `infra/99-teardown.sh --include-agent` removes everything above. The service-agent role grants stay; they cost nothing.
