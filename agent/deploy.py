#!/usr/bin/env python3
"""Deploy the RM Agent to Agent Runtime (asia-southeast1), bound to Agent Gateway.

  agent/.venv/bin/python agent/deploy.py --dry-run                 # build + print the request, no API call
  agent/.venv/bin/python agent/deploy.py                           # create the RM Agent engine
  agent/.venv/bin/python agent/deploy.py --update                  # push new code/config to the SAME engine
                                                                    # (engine id, Agent Identity and IAM grants kept)
  agent/.venv/bin/python agent/deploy.py --agent insights          # create the Insights Agent (scenario 7)

What it creates (one reasoning engine, display name cymbal-ge-demo-rm-agent):
  * source-based deployment (no pickling, no staging bucket): rm_agent/ + requirements.txt,
    entrypoint rm_agent.agent:app (vertexai AdkApp), agent_framework google-adk
  * identity_type = AGENT_IDENTITY (required whenever agent_gateway_config is set)
  * agent_gateway_config.agent_to_anywhere_config.agent_gateway =
      projects/YOUR_PROJECT_ID/locations/asia-southeast1/agentGateways/cymbal-ge-demo-agw
  * env: CYMBAL_AGENT_API_KEY <- Secret Manager cymbal-ge-demo-agent-key (latest),
         CYMBAL_CREDIT_BUREAU_URL = Apigee bureau proxy URL registered in Agent Registry
         (https://YOUR_APIGEE_HOST/cymbal-ge-demo/bureau/mcp; --direct-bureau = optional ext-proc variant)
  * min_instances=1 (one warm instance, no cold start), max_instances=2
Writes the resource id to agent/.deployed.json (read by infra/04-uap.sh and the BFF).

Refs: agent-gateway-runtime-deploy.md ("For new agents using the Python SDK"),
deploy-an-agent.md ("Source files", "Define environment variables" secret form).
Prereqs: infra 02 (gateway exists, DRY_RUN) and the secret exists with
roles/secretmanager.secretAccessor granted to the Agent Platform service agent
service-YOUR_PROJECT_NUMBER@gcp-sa-aiplatform.iam.gserviceaccount.com.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_ID = "YOUR_PROJECT_ID"
PROJECT_NUMBER = "YOUR_PROJECT_NUMBER"
ORG_ID = "YOUR_ORG_ID"
REGION = "asia-southeast1"
GATEWAY = f"projects/{PROJECT_ID}/locations/{REGION}/agentGateways/cymbal-ge-demo-agw"
CREDIT_BUREAU_SERVICE = "cymbal-ge-demo-credit-bureau"
# Same code, two deployments = two Agent Identities. Each agent calls Apigee with its OWN app key.
AGENTS = {
    "rm": {"display_name": "cymbal-ge-demo-rm-agent", "secret": "cymbal-ge-demo-agent-key",
           "state_file": HERE / ".deployed.json", "component": "rm-agent",
           "description": "RM Agent - Cymbal Bank relationship-manager assistant (Agent Gateway x Apigee demo)"},
    "insights": {"display_name": "cymbal-ge-demo-insights-agent", "secret": "cymbal-ge-demo-insights-key",
                 "state_file": HERE / ".deployed-insights.json", "component": "insights-agent",
                 "description": "Insights Agent - Cymbal Bank marketing assistant (scenario 7: same tool, different identity)"},
}
# Defaults for the RM Agent (kept for older references).
DISPLAY_NAME = AGENTS["rm"]["display_name"]
SECRET = AGENTS["rm"]["secret"]
STATE_FILE = AGENTS["rm"]["state_file"]


def gcloud(*args: str) -> str:
    """Read-only gcloud helper (argument list, no shell)."""
    try:
        out = subprocess.run(["gcloud", *args, f"--project={PROJECT_ID}"], check=True,
                             capture_output=True, text=True, timeout=60)
        return out.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return ""


APIGEE_BUREAU_URL = "https://YOUR_APIGEE_HOST/cymbal-ge-demo/bureau/mcp"


def resolve_credit_bureau_url(override: str | None, direct: bool = False) -> str:
    if override:
        return override
    if not direct:
        return APIGEE_BUREAU_URL  # default: bureau behind the Apigee proxy (S5 quota in Apigee)
    url = gcloud("run", "services", "describe", CREDIT_BUREAU_SERVICE, f"--region={REGION}",
                 "--format=value(status.url)")
    return f"{url.rstrip('/')}/mcp" if url else ""


def build_config(credit_bureau_url: str, class_methods: list[dict], direct: bool = False,
                 kind: str = "rm") -> dict:
    spec = AGENTS[kind]
    cfg = {
        "display_name": spec["display_name"],
        "description": spec["description"],
        "labels": {"demo": "cymbal-ge-demo", "component": spec["component"]},
        "source_packages": ["rm_agent", "requirements.txt"],
        "entrypoint_module": "rm_agent.agent",
        "entrypoint_object": "app",
        "requirements_file": "requirements.txt",
        "class_methods": class_methods,
        "agent_framework": "google-adk",
        "identity_type": "AGENT_IDENTITY",
        "agent_gateway_config": {"agent_to_anywhere_config": {"agent_gateway": GATEWAY}},
        "min_instances": 1,  # one warm instance: avoids the 60-90 s cold start (costs an always-on instance)
        "max_instances": 2,
        "env_vars": {
            "CYMBAL_AGENT_KIND": kind,
            "CYMBAL_AGENT_API_KEY": {"secret": spec["secret"], "version": "latest"},
            "CYMBAL_CREDIT_BUREAU_URL": credit_bureau_url,
            "CYMBAL_MCP_BANKING_URL": "https://YOUR_APIGEE_HOST/cymbal-ge-demo/mcp/banking",
            "CYMBAL_LLM_BASE_URL": "https://YOUR_APIGEE_HOST/cymbal-ge-demo/llm",
            "CYMBAL_LLM_MODEL": "cymbal-auto",
            "CYMBAL_LLM_PROJECT": PROJECT_ID,
            "CYMBAL_LLM_LOCATION": "global",
            "CYMBAL_BQ_PROJECT": PROJECT_ID,
            "CYMBAL_BQ_LOCATION": REGION,
        },
    }
    if direct:  # optional ext-proc variant: agent calls the Cloud Run bureau directly
        cfg["env_vars"]["CYMBAL_CREDIT_BUREAU_DIRECT"] = "1"
    return cfg


def stage_sources() -> Path:
    tmp = Path(tempfile.mkdtemp(prefix="rm-agent-deploy-"))
    shutil.copytree(HERE / "rm_agent", tmp / "rm_agent",
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copy2(HERE / "requirements.txt", tmp / "requirements.txt")
    return tmp


def class_methods_for_app(staged: Path) -> list[dict]:
    """Generate class_methods from the real AdkApp (no network, no key needed)."""
    sys.path.insert(0, str(staged))
    from agentplatform._genai import _runtimes_utils  # pylint: disable=import-outside-toplevel
    from rm_agent.agent import app  # pylint: disable=import-outside-toplevel
    specs = _runtimes_utils._generate_class_methods_spec_or_raise(  # pylint: disable=protected-access
        agent=app, operations=app.register_operations())
    return [_runtimes_utils._to_dict(s) for s in specs]  # pylint: disable=protected-access


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="build and print the request only")
    ap.add_argument("--credit-bureau-url", help="override https://<run-host>/mcp")
    ap.add_argument("--direct-bureau", action="store_true",
                    help="optional ext-proc variant: call the Cloud Run bureau directly (needs infra/06)")
    ap.add_argument("--force-new", action="store_true",
                    help="create a new engine even if the state file exists")
    ap.add_argument("--agent", choices=sorted(AGENTS), default="rm",
                    help="which agent to deploy: rm (RM Agent, default) or insights (Insights Agent)")
    ap.add_argument("--update", action="store_true",
                    help="update the existing engine in place (keeps engine id, Agent Identity, IAM grants)")
    ap.add_argument("--diag-no-gateway", action="store_true",
                    help="DIAGNOSTIC ONLY: deploy '<name>-diag' WITHOUT the Agent Gateway binding to "
                         "isolate startup failures; does not write agent/.deployed.json (delete it after)")
    ap.add_argument("--diag-min-instances", type=int, default=None,
                    help="DIAGNOSTIC ONLY (with --diag-no-gateway): override min_instances")
    args = ap.parse_args()
    spec = AGENTS[args.agent]
    state_file = spec["state_file"]

    if args.update and not state_file.exists():
        print(f"--update needs {state_file} (deploy the {args.agent} agent first)", file=sys.stderr)
        return 2
    if state_file.exists() and not (args.force_new or args.update) and not args.dry_run:
        print(f"{state_file} exists ({json.loads(state_file.read_text()).get('name')}). "
              "Use --update to push new code to it, delete that engine first, or pass --force-new. "
              "(Changing the gateway binding of an existing engine archives its revisions; all agents "
              "in a project+region must use the same egress gateway.)", file=sys.stderr)
        return 2

    cb_url = resolve_credit_bureau_url(args.credit_bureau_url, args.direct_bureau)
    if not cb_url:
        if not args.dry_run:
            print("Cloud Run bureau URL unknown (--direct-bureau): deploy credit-bureau first or pass --credit-bureau-url", file=sys.stderr)
            return 2
        cb_url = f"https://{CREDIT_BUREAU_SERVICE}-PENDING.a.run.app/mcp"

    # Defaults so the module imports locally; Agent Runtime sets its own values.
    os.environ.setdefault("GOOGLE_CLOUD_PROJECT", PROJECT_ID)
    os.environ.setdefault("GOOGLE_CLOUD_LOCATION", REGION)
    staged = stage_sources()
    cwd = os.getcwd()
    try:
        os.chdir(staged)  # source_packages are tarred relative to the CWD
        os.environ["CYMBAL_AGENT_KIND"] = args.agent  # so class_methods come from the right persona
        config = build_config(cb_url, class_methods_for_app(staged), args.direct_bureau, args.agent)
        if args.diag_no_gateway:
            config.pop("agent_gateway_config")
            config["display_name"] = spec["display_name"] + "-diag"
            config["labels"] = dict(config["labels"], component="rm-agent-diag")
            if args.diag_min_instances is not None:
                config["min_instances"] = args.diag_min_instances
        printable = dict(config, class_methods=[m.get("name") for m in config["class_methods"]])
        print("Agent Runtime create config:\n" + json.dumps(printable, indent=2))
        if args.dry_run:
            if not gcloud("secrets", "describe", spec["secret"], "--format=value(name)"):
                print(f"WARNING: secret {spec['secret']} not found in {PROJECT_ID} (create it before deploying)")
            if not gcloud("network-services", "agent-gateways", "describe", "cymbal-ge-demo-agw",
                          f"--location={REGION}", "--format=value(name)"):
                print("WARNING: gateway cymbal-ge-demo-agw not found (run infra/02 first)")
            print("DRY-RUN: no API call made.")
            return 0

        import agentplatform  # pylint: disable=import-outside-toplevel
        client = agentplatform.Client(project=PROJECT_ID, location=REGION)
        if args.update:
            existing = json.loads(state_file.read_text())["name"]
            upd = dict(config)
            # Identity type and gateway binding are left as they are: changing the binding archives revisions.
            upd.pop("identity_type", None)
            upd.pop("agent_gateway_config", None)
            print(f"Updating {existing} in place ...")
            runtime = client.runtimes.update(name=existing, config=upd)
            print(f"Updated {runtime.api_resource.name} (engine id and Agent Identity unchanged).")
            return 0
        runtime = client.runtimes.create(config=config)
    finally:
        os.chdir(cwd)
        shutil.rmtree(staged, ignore_errors=True)

    res = runtime.api_resource
    name = res.name
    engine_id = name.rsplit("/", 1)[-1]
    if args.diag_no_gateway:
        print(f"DIAGNOSTIC engine is up (no gateway): {name}. Not written to {state_file}; delete it when done.")
        return 0
    effective = getattr(getattr(res, "spec", None), "effective_identity", None) or ""
    state = {
        "name": name,
        "engine_id": engine_id,
        "project": PROJECT_ID,
        "project_number": PROJECT_NUMBER,
        "region": REGION,
        "display_name": spec["display_name"],
        "agent": args.agent,
        "agent_gateway": GATEWAY,
        "credit_bureau_url": cb_url,
        "effective_identity": effective,
        "principal": f"principal://agents.global.org-{ORG_ID}.system.id.goog/resources/aiplatform/"
                     f"projects/{PROJECT_NUMBER}/locations/{REGION}/reasoningEngines/{engine_id}",
        "query_url": f"https://{REGION}-aiplatform.googleapis.com/v1/{name}:query",
        "stream_query_url": f"https://{REGION}-aiplatform.googleapis.com/v1/{name}:streamQuery?alt=sse",
        "created": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    state_file.write_text(json.dumps(state, indent=2) + "\n")
    print(json.dumps(state, indent=2))
    print(f"\nWrote {state_file}. Next: re-run infra/04-uap.sh to scope the UAP to this agent principal.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
