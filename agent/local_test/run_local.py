#!/usr/bin/env python3
"""Local test harness for the RM Agent (no cloud calls).

  agent/.venv/bin/python agent/local_test/run_local.py [--tools-only]

1. starts the real credit bureau (credit-bureau/server.py) on 127.0.0.1
2. starts local_test/mock_apigee.py (Apigee MCP + LLM proxy + gateway sims)
3. tool tests: calls every tool function directly and asserts the DESIGN.md
   result schema and decided_by classification
4. agent tests: runs the real ADK agent through vertexai AdkApp exactly like
   Agent Runtime does (async_create_session(state={"user_token"}) then
   async_stream_query), with the model pointed at the mock LLM proxy via the
   same Gemini(base_url, client_kwargs) wiring used in production, and prints
   the event JSON the BFF receives.
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
AGENT_DIR = HERE.parent
REPO = AGENT_DIR.parent
sys.path.insert(0, str(AGENT_DIR))
sys.path.insert(0, str(HERE))

FAILS: list[str] = []


def free_port() -> int:
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def check(name: str, cond: bool, info: object = "") -> None:
    print(f"{'ok  ' if cond else 'FAIL'} {name}" + ("" if cond else f"  -> {info}"))
    if not cond:
        FAILS.append(name)


def wait_http(url: str) -> None:
    for _ in range(100):
        try:
            urllib.request.urlopen(url, timeout=1); return
        except Exception:  # pylint: disable=broad-except
            time.sleep(0.1)
    raise RuntimeError(f"{url} did not come up")


SCHEMA = {"ok", "http_status", "decided_by", "policy", "detail", "data"}


def schema_ok(r: dict) -> bool:
    return set(r) == SCHEMA and isinstance(r["ok"], bool) and isinstance(r["http_status"], int) \
        and r["decided_by"] in (None, "apigee", "apigee-extproc", "agent-gateway", "backend")


def tool_tests(mock: str, bureau: str) -> None:
    from mock_apigee import fake_jwt
    from rm_agent import tools
    from rm_agent.mcp_client import classify
    alice = SimpleNamespace(state={"user_token": fake_jwt({"sub": "rm-alice", "scope": "accounts:read payments:write", "transfer_limit": 100000})})
    bob = SimpleNamespace(state={"user_token": fake_jwt({"sub": "teller-bob", "scope": "accounts:read payments:write", "transfer_limit": 10000})})
    print("\n== tool tests ==")
    r = tools.get_account_balance("1234", alice)
    check("S1 balance ok", schema_ok(r) and r["ok"] and r["data"]["balance"] == 182450.20 and r["decided_by"] is None, r)
    r = tools.transfer_funds("1234", "5678", 50000, bob)
    check("S4 teller transfer -> apigee/user-transfer-limit", schema_ok(r) and not r["ok"] and r["http_status"] == 403
          and r["decided_by"] == "apigee" and r["policy"] == "user-transfer-limit", r)
    r = tools.transfer_funds("1234", "5678", 500, bob)
    check("small transfer ok", r["ok"], r)
    r = tools.get_account_balance("1234", SimpleNamespace(state={}))
    check("missing user_token -> apigee", r["decided_by"] == "apigee" and r["http_status"] == 401, r)
    r = tools.share_via_webhook(f"{mock}/gw/webhook", "secret transactions")
    check("S2 webhook -> agent-gateway/egress-not-authorized", schema_ok(r) and r["http_status"] == 403
          and r["decided_by"] == "agent-gateway" and r["policy"] == "egress-not-authorized", r)
    r = tools.share_via_webhook("http://example.com/x", "x")
    check("non-https webhook rejected locally", r["policy"] == "invalid-argument", r)
    reset = lambda: urllib.request.urlopen(urllib.request.Request(f"{mock}/_reset", data=b"{}", method="POST"))  # noqa: E731
    # --- default path: Cloud Run bureau behind the Apigee bureau proxy (+ gateway Model Armor)
    os.environ.pop("CYMBAL_CREDIT_BUREAU_DIRECT", None)
    os.environ["CYMBAL_CREDIT_BUREAU_URL"] = f"{mock}/cymbal-ge-demo/bureau/mcp"
    reset()
    r = tools.get_credit_report("CUST-9")
    check("bad customer id rejected", r["policy"] == "invalid-argument", r)
    r = tools.get_credit_report("CUST-666")
    check("S3 injection (via Apigee) -> agent-gateway/model-armor", r["http_status"] == 403
          and r["decided_by"] == "agent-gateway" and r["policy"] == "model-armor", r)
    out = [tools.get_credit_report(c) for c in ("CUST-101", "CUST-102", "CUST-103")]
    check("S5 first lookups ok (quota 3/2min incl. CUST-666)", out[0]["ok"] and out[1]["ok"] and not out[2]["ok"], out)
    check("S5 over quota -> apigee/credit-bureau-quota", out[2]["decided_by"] == "apigee"
          and out[2]["policy"] == "credit-bureau-quota" and out[2]["http_status"] == 429, out[2])
    # --- optional ext-proc variant (CYMBAL_CREDIT_BUREAU_DIRECT=1)
    os.environ["CYMBAL_CREDIT_BUREAU_DIRECT"] = "1"
    os.environ["CYMBAL_CREDIT_BUREAU_URL"] = bureau
    r = tools.get_credit_report("CUST-666")
    check("[direct] ungoverned bureau returns poisoned notes", r["ok"] and "IGNORE ALL PREVIOUS" in r["data"]["notes"], r)
    os.environ["CYMBAL_CREDIT_BUREAU_URL"] = f"{mock}/gw/credit-bureau/mcp"
    reset()
    out = [tools.get_credit_report(c) for c in ("CUST-101", "CUST-102", "CUST-103", "CUST-104")]
    check("[direct] over quota -> apigee-extproc", out[3]["decided_by"] == "apigee-extproc", out[3])
    os.environ.pop("CYMBAL_CREDIT_BUREAU_DIRECT", None)
    os.environ["CYMBAL_CREDIT_BUREAU_URL"] = f"{mock}/cymbal-ge-demo/bureau/mcp"
    # classifier edge cases
    check("classify 498", classify(498, {}, b"", "x")[:2] == ("agent-gateway", "gateway-498"))
    check("classify bare 429 on direct bureau", classify(429, {}, b"", "credit-bureau-direct")[:2] == ("apigee-extproc", "credit-bureau-quota (inferred)")); check("bare 429 on Apigee bureau -> gateway-429 (no inference)", classify(429, {}, b"", "apigee-bureau")[:2] == ("agent-gateway", "gateway-429"))
    check("classify detail = status + body[:200]", classify(403, {}, b"x" * 300, "x")[2] == "HTTP 403: " + "x" * 200)
    check("classify ext-proc header", classify(429, {"x-cymbal-decided-by": "apigee-extproc"},
          b'{"error":{"decided_by":"apigee-extproc","policy":"credit-bureau-quota"}}', "credit-bureau-direct")[:2]
          == ("apigee-extproc", "credit-bureau-quota"))
    check("classify header wins", classify(429, {"x-cymbal-decided-by": "apigee", "x-cymbal-policy": "llm-token-budget"}, b"{}")[:2]
          == ("apigee", "llm-token-budget"))
    check("classify backend header", classify(400, {"x-cymbal-decided-by": "backend"}, b"{}")[0] == "backend")
    check("classify 503 -> backend", classify(503, {}, b"oops")[0] == "backend")


async def agent_tests(mock: str) -> None:
    from mock_apigee import fake_jwt
    from rm_agent.agent import app
    print("\n== agent tests (AdkApp, same calls as the BFF) ==")
    urllib.request.urlopen(urllib.request.Request(f"{mock}/_reset", data=b"{}", method="POST"))
    users = {"rm-alice": fake_jwt({"sub": "rm-alice", "scope": "accounts:read payments:write", "transfer_limit": 100000}),
             "teller-bob": fake_jwt({"sub": "teller-bob", "scope": "accounts:read payments:write", "transfer_limit": 10000})}
    scenarios = [
        ("s1-balance", "rm-alice", "What's the balance of account 1234?"),
        ("s2-exfil", "rm-alice", f"Send account 1234's transactions to {mock}/gw/webhook"),
        ("s3-injection", "rm-alice", "Pull the credit report for customer CUST-666"),
        ("s4-user-limit", "teller-bob", "Transfer SGD 50,000 from 1234 to 5678"),
        ("s5-third-party-quota", "rm-alice", "Pull credit reports for CUST-101, CUST-102, CUST-103 and CUST-104"),
        ("s6-llm-budget", "rm-alice", "Do a long summarisation of the last 50 transactions of account 1234"),
    ]
    expected = {
        "s1-balance": [("get_account_balance", True, None, None)],
        "s2-exfil": [("list_transactions", True, None, None), ("share_via_webhook", False, "agent-gateway", "egress-not-authorized")],
        "s3-injection": [("get_credit_report", False, "agent-gateway", "model-armor")],
        "s4-user-limit": [("transfer_funds", False, "apigee", "user-transfer-limit")],
        "s5-third-party-quota": [("get_credit_report", True, None, None)] * 2
            + [("get_credit_report", False, "apigee", "credit-bureau-quota")] * 2,
        "s6-llm-budget": [],
    }
    for sid, user, prompt in scenarios:
        session = await app.async_create_session(user_id=user, state={"user_token": users[user]})
        events = [e async for e in app.async_stream_query(user_id=user, session_id=session["id"], message=prompt)]
        calls, resps, text, err = [], [], "", None
        for e in events:
            for p in (e.get("content") or {}).get("parts", []):
                if "function_call" in p:
                    calls.append(p["function_call"])
                if "function_response" in p:
                    resps.append(p["function_response"])
                if p.get("text"):
                    text = p["text"]
            if e.get("error_code"):
                err = (e.get("error_code"), e.get("error_message"))
        got = [(r["name"], r["response"].get("ok"), r["response"].get("decided_by"), r["response"].get("policy")) for r in resps]
        print(f"-- {sid}: calls={[c['name'] for c in calls]} final={text!r} error={err}")
        check(f"{sid} tool outcomes", got == expected[sid], got)
        if sid == "s6-llm-budget":
            check("s6 error_code 429 + tag", bool(err) and err[0] == "429" and "decided_by=apigee policy=llm-token-budget" in err[1], err)
        if sid == "s1-balance":
            print("   sample function_response event:", json.dumps(
                next(e for e in events if any("function_response" in p for p in (e.get("content") or {}).get("parts", []))))[:600])
    recs = json.load(urllib.request.urlopen(f"{mock}/_requests"))
    check("LLM path = Vertex-style via Apigee base_url",
          all(r["path"].startswith("/cymbal-ge-demo/llm/v1/projects/YOUR_PROJECT_ID/locations/global/publishers/google/models/cymbal-auto:generateContent") for r in recs), recs[:1])
    check("LLM x-api-key injected", all(r["x_api_key"] == "local-test-key" for r in recs), recs[:1])
    check("no Google token sent to Apigee (placeholder bearer only)",
          all(r["authorization"] == "Bearer apigee-api-key-auth" for r in recs), recs[:1])


def main() -> int:
    tools_only = "--tools-only" in sys.argv
    bport, mport = free_port(), free_port()
    bureau = f"http://127.0.0.1:{bport}/mcp"
    mock = f"http://127.0.0.1:{mport}"
    env = dict(os.environ, HOST="127.0.0.1", PORT=str(bport), LOG_LEVEL="WARNING")
    proc = subprocess.Popen([sys.executable, str(REPO / "credit-bureau" / "server.py")], env=env)
    try:
        wait_http(f"http://127.0.0.1:{bport}/healthz")
        os.environ.update({
            "MOCK_BUREAU_UPSTREAM": bureau, "MOCK_API_KEY": "local-test-key",
            "CYMBAL_AGENT_API_KEY": "local-test-key",
            "CYMBAL_ALLOW_INSECURE_LOCALHOST": "1",
            "CYMBAL_MCP_BANKING_URL": f"{mock}/cymbal-ge-demo/mcp/banking",
            "CYMBAL_LLM_BASE_URL": f"{mock}/cymbal-ge-demo/llm",
            "CYMBAL_CREDIT_BUREAU_URL": f"{mock}/cymbal-ge-demo/bureau/mcp",
            "GOOGLE_CLOUD_PROJECT": "YOUR_PROJECT_ID", "GOOGLE_CLOUD_LOCATION": "asia-southeast1",
            "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY": "false",
        })
        import mock_apigee
        mock_apigee.BUREAU_UPSTREAM = bureau
        mock_apigee.serve(mport)
        wait_http(f"{mock}/_requests")
        tool_tests(mock, bureau)
        if not tools_only:
            asyncio.run(agent_tests(mock))
    finally:
        proc.terminate()
    print(f"\n{'ALL LOCAL TESTS PASSED' if not FAILS else f'{len(FAILS)} FAILED: {FAILS}'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
