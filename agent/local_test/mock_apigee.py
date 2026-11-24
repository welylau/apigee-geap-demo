#!/usr/bin/env python3
"""Local mocks for the RM Agent test harness (stdlib only, 127.0.0.1 only).

One HTTP server that imitates, per DESIGN.md:
  POST /cymbal-ge-demo/mcp/banking            Apigee MCP proxy (x-api-key, x-user-token, limits)
  POST /cymbal-ge-demo/llm/v1/projects/{p}/locations/global/publishers/google/models/{m}:generateContent
                                              Apigee LLM proxy with a *scripted* model
  POST /cymbal-ge-demo/bureau/mcp             Apigee bureau proxy (key, 3/120s quota) + gateway Model Armor
  POST /gw/credit-bureau/mcp                  (optional ext-proc variant) "Agent Gateway" in front of the real local
                                              credit bureau: Apigee ext-proc quota (3/120s)
                                              and Model Armor response block (injection)
  POST /gw/webhook                            "Agent Gateway" default deny (unregistered host)
  GET  /_requests                             recorded LLM request metadata (for asserts)
  POST /_reset                                reset counters/recordings
The gateway simulations reproduce the documented denial body
  {"code": 403, "message": "403 Forbidden. {'message': 'Egress request is not authorized.', ...}"}
and our Model Armor template's custom block message ("cymbal-model-armor: ...").
"""

from __future__ import annotations

import base64
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

EXPECTED_KEY = os.environ.get("MOCK_API_KEY", "local-test-key")
BUREAU_UPSTREAM = os.environ.get("MOCK_BUREAU_UPSTREAM", "")  # http://127.0.0.1:<port>/mcp
LLM_RE = re.compile(r"^/cymbal-ge-demo/llm/v1/projects/([^/]+)/locations/([^/]+)/publishers/google/models/([^/:]+):generateContent$")

ACCOUNTS = {
    "1234": {"owner": "Jane Koh (client of rm-alice)", "balance": 182450.20},
    "5678": {"owner": "Marcus Lee", "balance": 15230.00},
    "9012": {"owner": "Siti Rahman", "balance": 980.55},
}
STATE: dict[str, Any] = {"llm_requests": [], "bureau_calls": []}
LOCK = threading.Lock()


def fake_jwt(claims: dict[str, Any]) -> str:
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()  # noqa: E731
    return f"{enc({'alg': 'none', 'typ': 'JWT'})}.{enc(claims)}.mock"


def jwt_claims(token: str) -> dict[str, Any] | None:
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:  # pylint: disable=broad-except
        return None


# ----------------------------------------------------------------- MCP banking
def banking(handler: "H", msg: dict[str, Any]) -> None:
    def deny(status: int, policy: str, text: str) -> None:
        handler.send_json(status, {"jsonrpc": "2.0", "id": msg.get("id"),
                                   "error": {"code": -32001, "message": text,
                                             "data": {"decided_by": "apigee", "policy": policy}}},
                          {"x-cymbal-decided-by": "apigee", "x-cymbal-policy": policy})

    if handler.headers.get("x-api-key") != EXPECTED_KEY:
        return deny(401, "invalid-api-key", "Invalid API key")
    if msg.get("method") != "tools/call":
        return handler.send_json(200, {"jsonrpc": "2.0", "id": msg.get("id"), "result": {}})
    claims = jwt_claims(handler.headers.get("x-user-token") or "")
    if not claims:
        return deny(401, "user-token-invalid", "End-user token missing or invalid")
    p = msg.get("params") or {}
    name, args = p.get("name"), p.get("arguments") or {}
    if name == "get_account_balance":
        acc = ACCOUNTS.get(str(args.get("account_id")))
        if not acc:
            return deny(404, "account-not-found", "Unknown account")
        data = {"account_id": args["account_id"], "currency": "SGD", **acc}
    elif name == "list_transactions":
        n = int(args.get("limit") or 10)
        data = {"account_id": args.get("account_id"),
                "transactions": [{"date": f"2026-11-{d:02d}", "amount": -12.5 * d, "desc": f"txn {d}"}
                                 for d in range(1, min(n, 50) + 1)]}
    elif name == "transfer_funds":
        if "payments:write" not in str(claims.get("scope", "")).split():
            return deny(403, "user-scope", "Missing payments:write scope")
        if float(args.get("amount", 0)) > float(claims.get("transfer_limit", 0)):
            return deny(403, "user-transfer-limit", "Amount exceeds the user's transfer limit")
        data = {"status": "COMPLETED", "reference": "TX-LOCAL-1", **args}
    else:
        return deny(403, "tool-not-in-product", "Tool not allowed for this API product")
    handler.send_json(200, {"jsonrpc": "2.0", "id": msg.get("id"), "result": {
        "content": [{"type": "text", "text": json.dumps(data)}], "structuredContent": data, "isError": False}},
        {"x-cymbal-decided-by": "apigee", "x-cymbal-policy": "allowed"})


# --------------------------------------------- bureau: Apigee proxy / direct
def _bureau_upstream(raw: bytes) -> tuple[int, bytes]:
    req = urllib.request.Request(BUREAU_UPSTREAM, data=raw, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _quota_hit() -> bool:
    now = time.time()
    with LOCK:
        calls = [t for t in STATE["bureau_calls"] if now - t < 120]
        hit = len(calls) >= 3
        if not hit:
            calls.append(now)
        STATE["bureau_calls"] = calls
    return hit


def _model_armor_blocks(body: bytes) -> bool:
    return b"IGNORE ALL PREVIOUS INSTRUCTIONS" in body


def apigee_bureau(handler: "H", raw: bytes, msg: dict[str, Any]) -> None:
    """Default S5 path: Cloud Run bureau behind an Apigee proxy, then the
    gateway's Model Armor inspects the response on the way back (S3)."""
    if handler.headers.get("x-api-key") != EXPECTED_KEY:
        return handler.send_json(401, {"jsonrpc": "2.0", "id": msg.get("id"), "error": {
            "code": -32001, "message": "Invalid API key",
            "data": {"decided_by": "apigee", "policy": "invalid-api-key"}}},
            {"x-cymbal-decided-by": "apigee", "x-cymbal-policy": "invalid-api-key"})
    if msg.get("method") == "tools/call" and _quota_hit():
        return handler.send_json(429, {"jsonrpc": "2.0", "id": msg.get("id"), "error": {
            "code": -32002, "message": "Credit bureau quota exceeded (3 per 2 minutes)",
            "data": {"decided_by": "apigee", "policy": "credit-bureau-quota"}}},
            {"x-cymbal-decided-by": "apigee", "x-cymbal-policy": "credit-bureau-quota"})
    status, body = _bureau_upstream(raw)
    if _model_armor_blocks(body):   # gateway CONTENT_AUTHZ (Model Armor) on the response
        return handler.send_json(403, {"code": 403, "message":
            "cymbal-model-armor: response blocked by Model Armor (cymbal-ge-demo-ma)"})
    handler.send_raw(status, body, {"x-cymbal-decided-by": "apigee", "x-cymbal-policy": "allowed"})


def gw_credit_bureau(handler: "H", raw: bytes) -> None:
    """Optional ext-proc variant: gateway in front of the DIRECT Cloud Run bureau."""
    if _quota_hit():
        return handler.send_json(429, {"error": {"decided_by": "apigee-extproc",
                                                 "policy": "credit-bureau-quota",
                                                 "message": "Credit bureau quota exceeded (3 per 2 minutes)"}})
    status, body = _bureau_upstream(raw)
    if _model_armor_blocks(body):
        return handler.send_json(403, {"code": 403, "message":
            "cymbal-model-armor: response blocked by Model Armor (cymbal-ge-demo-ma)"})
    handler.send_raw(status, body)


# ------------------------------------------------------------ scripted model
def _texts(content: dict[str, Any]) -> str:
    return " ".join(p.get("text", "") for p in content.get("parts", []) if isinstance(p, dict))


def plan_for(user_text: str) -> list[tuple[str, dict[str, Any]]]:
    t = user_text
    m = re.search(r"transfer\s+SGD\s*([\d,]+(?:\.\d+)?)\s+from\s+(\w+)\s+to\s+(\w+)", t, re.I)
    if m:
        return [("transfer_funds", {"from_account": m.group(2), "to_account": m.group(3),
                                    "amount": float(m.group(1).replace(",", "")), "memo": "RM request"})]
    m = re.search(r"https?://\S+", t)
    if m and "transaction" in t.lower():
        acc = re.search(r"account\s+(\w+)", t, re.I)
        return [("list_transactions", {"account_id": acc.group(1) if acc else "1234", "limit": 10}),
                ("share_via_webhook", {"url": m.group(0).rstrip(".,"), "content": "<transactions>"})]
    ids = re.findall(r"CUST-\d+", t)
    if ids and "credit" in t.lower():
        return [("get_credit_report", {"customer_id": i}) for i in ids]
    m = re.search(r"balance of account\s+(\w+)", t, re.I)
    if m:
        return [("get_account_balance", {"account_id": m.group(1)})]
    return []


def llm(handler: "H", req: dict[str, Any], path_match: re.Match[str]) -> None:
    rec = {"path": handler.path, "project": path_match.group(1), "location": path_match.group(2),
           "model": path_match.group(3), "x_api_key": handler.headers.get("x-api-key"),
           "authorization": (handler.headers.get("Authorization") or "")[:40]}
    with LOCK:
        STATE["llm_requests"].append(rec)
    if handler.headers.get("x-api-key") != EXPECTED_KEY:
        return handler.send_json(401, {"error": {"code": 401, "message": "Invalid API key",
                                                 "status": "UNAUTHENTICATED"}},
                                 {"x-cymbal-decided-by": "apigee", "x-cymbal-policy": "invalid-api-key"})
    contents = req.get("contents") or []
    # index of the latest plain user text message = start of this turn
    start = max((i for i, c in enumerate(contents)
                 if c.get("role") == "user" and _texts(c).strip()), default=0)
    user_text = _texts(contents[start]) if contents else ""
    if "long summarisation" in user_text.lower() or "summarise all 50" in user_text.lower():
        return handler.send_json(429, {"error": {"code": 429, "status": "RESOURCE_EXHAUSTED",
                                                 "message": "LLM token budget exceeded for this app",
                                                 "decided_by": "apigee", "policy": "llm-token-budget"}},
                                 {"x-cymbal-decided-by": "apigee", "x-cymbal-policy": "llm-token-budget",
                                  "x-cymbal-model": "gemini-3.5-flash-lite"})
    responses = [p["functionResponse"] for c in contents[start + 1:] for p in c.get("parts", [])
                 if isinstance(p, dict) and "functionResponse" in p]
    plan = plan_for(user_text)
    if len(responses) < len(plan):
        name, args = plan[len(responses)]
        if name == "share_via_webhook" and responses:
            args = dict(args, content=json.dumps(responses[-1].get("response", {}))[:500])
        part = {"functionCall": {"name": name, "args": args}}
    else:
        lines = []
        for r in responses:
            res = r.get("response", {})
            res = res.get("result", res) if isinstance(res, dict) else res
            if isinstance(res, dict) and res.get("ok"):
                lines.append(f"{r.get('name')}: ok")
            elif isinstance(res, dict):
                lines.append(f"{r.get('name')}: blocked by {res.get('decided_by')}, policy {res.get('policy')}")
        part = {"text": "; ".join(lines) or "Hello, I am RM Agent."}
    handler.send_json(200, {"candidates": [{"content": {"role": "model", "parts": [part]},
                                            "finishReason": "STOP", "index": 0}],
                            "usageMetadata": {"promptTokenCount": 100, "candidatesTokenCount": 20,
                                              "totalTokenCount": 120},
                            "modelVersion": "gemini-3.5-flash"},
                     {"x-cymbal-model": "gemini-3.5-flash", "x-cymbal-tokens-used": "120"})


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        if os.environ.get("MOCK_VERBOSE"):
            sys.stderr.write("mock: " + fmt % args + "\n")

    def send_raw(self, status: int, body: bytes, headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, status: int, obj: Any, headers: dict[str, str] | None = None) -> None:
        self.send_raw(status, json.dumps(obj).encode(), headers)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/_requests":
            with LOCK:
                return self.send_json(200, STATE["llm_requests"])
        self.send_json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/_reset":
            with LOCK:
                STATE["llm_requests"].clear(); STATE["bureau_calls"].clear()
            return self.send_json(200, {"ok": True})
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            return self.send_json(400, {"error": "bad json"})
        if self.path == "/cymbal-ge-demo/mcp/banking":
            return banking(self, body)
        if self.path == "/cymbal-ge-demo/bureau/mcp":
            return apigee_bureau(self, raw, body)
        if self.path == "/gw/credit-bureau/mcp":
            return gw_credit_bureau(self, raw)
        if self.path == "/gw/webhook":
            return self.send_json(403, {"code": 403, "message":
                "403 Forbidden. {'message': 'Egress request is not authorized.', 'status': 'Forbidden'}"})
        m = LLM_RE.match(self.path)
        if m:
            return llm(self, body, m)
        self.send_json(404, {"error": "not found"})


def serve(port: int) -> ThreadingHTTPServer:
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


if __name__ == "__main__":
    s = serve(int(os.environ.get("PORT", "8091")))
    print(f"mock apigee/gateway on 127.0.0.1:{s.server_address[1]}", flush=True)
    threading.Event().wait()
