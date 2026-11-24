"""Minimal MCP (Streamable HTTP, JSON-only) client + decision classification.

Every tool returns the DESIGN.md contract:
  {"ok": bool, "http_status": int,
   "decided_by": "apigee"|"apigee-extproc"|"agent-gateway"|"backend"|None,
   "policy": str|None, "detail": str, "data": any}

Classification (first match wins):
  1. response header  x-cymbal-decided-by (+ x-cymbal-policy)      -> as stated
  2. JSON body decided_by at  .decided_by | .error.decided_by |
     .error.data.decided_by (+ policy next to it)                   -> as stated
  3. HTTP 4xx or 498 with neither marker                            -> agent-gateway
       policy: "model-armor" if the body mentions Model Armor (our template's
               custom block message "cymbal-model-armor: ..." or the words
               "model armor"/"modelarmor"/"sanitiz"),
               "egress-not-authorized" for the documented IAP/UAP body
               "Egress request is not authorized", "gateway-498" for 498,
               else "gateway-<status>"
     exception (only CYMBAL_CREDIT_BUREAU_DIRECT=1, ext-proc variant): 429 from the direct Cloud Run bureau without markers ->
               apigee-extproc / "credit-bureau-quota (inferred)" (only Apigee meters it)
  detail for every non-2xx = "HTTP <status>: <first 200 chars of the raw body>"
  4. 5xx without marker                                              -> backend
  5. 2xx with JSON-RPC error and no marker                           -> backend
     2xx with result.isError == true                                 -> backend/tool-error
  6. 2xx success                                                     -> ok, decided_by None
  Transport failure (DNS, reset, timeout)                            -> decided_by None,
     policy "transport-error" (the gateway may also reset a denied connection).
"""

from __future__ import annotations

import itertools
import json
import ssl
import urllib.error
import urllib.request
from typing import Any

from . import config

MCP_PROTOCOL_VERSION = "2025-06-18"
USER_AGENT = "cymbal-rm-agent/1.0"
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
_ids = itertools.count(1)
_KNOWN = {"apigee", "apigee-extproc", "agent-gateway", "backend"}


def _ssl_context() -> ssl.SSLContext:
    # Honors SSL_CERT_FILE / system store, where Agent Runtime installs the
    # Agent Gateway root CA for source-based deployments.
    return ssl.create_default_context()


def result(ok: bool, http_status: int, decided_by: str | None, policy: str | None,
           detail: str, data: Any = None) -> dict[str, Any]:
    return {"ok": ok, "http_status": int(http_status), "decided_by": decided_by,
            "policy": policy, "detail": detail[:500], "data": data}


def http_post_json(url: str, body: Any, headers: dict[str, str]) -> tuple[int, dict[str, str], bytes, str | None]:
    """POST JSON. Returns (status, lower-cased headers, body bytes, transport_error)."""
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", USER_AGENT)
    for k, v in headers.items():
        if v:
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=config.http_timeout(), context=_ssl_context()) as resp:
            return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read(MAX_RESPONSE_BYTES), None
    except urllib.error.HTTPError as e:
        try:
            raw = e.read(MAX_RESPONSE_BYTES)
        except Exception:  # pylint: disable=broad-except
            raw = b""
        hdrs = {k.lower(): v for k, v in (e.headers.items() if e.headers else [])}
        return e.code, hdrs, raw, None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
        reason = getattr(e, "reason", e)
        return 0, {}, b"", f"{type(e).__name__}: {reason}"


def _json(raw: bytes) -> Any:
    try:
        return json.loads(raw.decode("utf-8", "replace")) if raw else None
    except ValueError:
        return None


def _marker_from_body(body: Any) -> tuple[str | None, str | None]:
    if not isinstance(body, dict):
        return None, None
    candidates = [body]
    err = body.get("error")
    if isinstance(err, dict):
        candidates.append(err)
        if isinstance(err.get("data"), dict):
            candidates.append(err["data"])
    for c in candidates:
        d = c.get("decided_by")
        if isinstance(d, str) and d:
            p = c.get("policy")
            return d, p if isinstance(p, str) else None
    return None, None


def _text_of(body: Any, raw: bytes) -> str:
    if isinstance(body, dict):
        err = body.get("error")
        if isinstance(err, dict) and isinstance(err.get("message"), str):
            return err["message"]
        if isinstance(body.get("message"), str):
            return body["message"]
    return raw.decode("utf-8", "replace").strip()


def classify(status: int, headers: dict[str, str], raw: bytes,
             target: str = "") -> tuple[str | None, str | None, str]:
    """Return (decided_by, policy, detail) for a NON-successful response."""
    body = _json(raw)
    snippet = raw.decode("utf-8", "replace").strip().replace("\n", " ")[:200]
    text = f"HTTP {status}: {snippet}" if snippet else f"HTTP {status}"
    hdr = (headers.get("x-cymbal-decided-by") or "").strip().lower()
    if hdr:
        return hdr, headers.get("x-cymbal-policy") or _marker_from_body(body)[1], text
    d, p = _marker_from_body(body)
    if d:
        return d, p, text
    low = raw.decode("utf-8", "replace").lower()
    if (400 <= status < 500) or status == 498:
        if status == 429 and target == "credit-bureau-direct":
            return "apigee-extproc", "credit-bureau-quota (inferred)", text
        if "cymbal-model-armor" in low or "model armor" in low or "modelarmor" in low or "sanitiz" in low:
            policy = "model-armor"
        elif "egress request is not authorized" in low:
            policy = "egress-not-authorized"
        elif status == 498:
            policy = "gateway-498"
        else:
            policy = f"gateway-{status}"
        return "agent-gateway", policy, text
    return "backend", None, text


def call_tool(url: str, tool: str, arguments: dict[str, Any],
              headers: dict[str, str] | None = None, target: str = "") -> dict[str, Any]:
    """One stateless MCP tools/call (no initialize handshake: one request per
    tool call keeps the Apigee ext-proc quota count == number of lookups)."""
    if not url:
        return result(False, 0, None, "not-configured", f"no URL configured for {target or tool}")
    bad = config.validate_target_url(url)
    if bad:
        return result(False, 0, None, "invalid-url", bad)
    msg = {"jsonrpc": "2.0", "id": next(_ids), "method": "tools/call",
           "params": {"name": tool, "arguments": arguments}}
    hdrs = {"Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": MCP_PROTOCOL_VERSION}
    hdrs.update(headers or {})
    status, rhdrs, raw, terr = http_post_json(url, msg, hdrs)
    if terr:
        return result(False, 0, None, "transport-error", terr)
    if not 200 <= status < 300:
        d, p, detail = classify(status, rhdrs, raw, target)
        return result(False, status, d, p, detail)
    body = _json(raw)
    if not isinstance(body, dict):
        return result(False, status, "backend", "bad-response", "response was not JSON-RPC")
    if "error" in body:
        d, p = _marker_from_body(body)
        if not d and "cymbal-model-armor" in raw.decode("utf-8", "replace").lower():
            d, p = "agent-gateway", "model-armor"
        return result(False, status, d or "backend", p or "jsonrpc-error", _text_of(body, raw))
    res = body.get("result")
    if not isinstance(res, dict):
        return result(False, status, "backend", "bad-response", "missing JSON-RPC result")
    data: Any = res.get("structuredContent")
    if data is None:
        texts = [c.get("text", "") for c in res.get("content", []) if isinstance(c, dict) and c.get("type") == "text"]
        joined = "\n".join(texts)
        parsed = _json(joined.encode()) if joined else None
        data = parsed if parsed is not None else joined
    if res.get("isError"):
        return result(False, status, "backend", "tool-error", str(data), data)
    return result(True, status, None, None, "ok", data)
