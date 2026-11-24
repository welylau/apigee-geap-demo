#!/usr/bin/env python3
"""Reliability check for the 8 demo scenarios against a running BFF (local or tunnelled).

  python3 scripts/verify-scenarios.py --bff http://127.0.0.1:8080 --rounds 5

Each round runs all 8 scenarios once and checks verdict + deciding layer (+ policy where it is fixed).
Order and the pause between rounds matter: the credit bureau quota (3 lookups / min, rolling) is shared by
S3 (CUST-666 lookup) and S5, and the partner quota is 5 calls / min. So S5 runs last in a round and
the next round starts --gap seconds (default 70) after S5 finished, so S3 sees a fresh window.
Exit code 0 only if every run of every scenario matched.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request

# id -> (verdict, decided_by, policy or None, extra check or None)
EXPECT = {
    "s1-balance": ("allowed", "both", None, None),
    "s2-exfil": ("blocked", "agent-gateway", "egress-not-authorized", None),
    "s3-injection": ("blocked", "agent-gateway", "model-armor", None),
    "s4-user-limit": ("blocked", "apigee", "user-transfer-limit", "delegation"),
    "s7-wrong-agent": ("blocked", "agent-gateway", "egress-not-authorized", "insights"),
    "s8-agent-iam": ("blocked", "iam", "bigquery-access-denied", "kyc-ok"),
    "s6-partner": ("blocked", "apigee", "product-quota", None),
    "s5-third-party-quota": ("blocked", "apigee", "credit-bureau-quota", None),
}
ORDER = list(EXPECT)


def run(bff: str, sid: str) -> dict:
    req = urllib.request.Request(f"{bff.rstrip('/')}/api/run", data=json.dumps({"scenarioId": sid}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=240) as r:
        return json.loads(r.read())


def check(sid: str, d: dict) -> tuple[bool, str]:
    verdict, decider, policy, extra = EXPECT[sid]
    got = f"{d.get('verdict')}/{d.get('decidedBy')}/{d.get('policy')} HTTP {d.get('httpStatus')} {d.get('latencyMs')}ms"
    ok = d.get("verdict") == verdict and d.get("decidedBy") == decider and (policy is None or d.get("policy") == policy)
    steps = (d.get("trace") or {}).get("steps") or []
    if ok and extra == "delegation":
        dl = (d.get("requestHeaders") or {}).get("delegation") or {}
        ok = dl.get("sub") == "teller-bob" and (dl.get("act") or {}).get("sub") == "cymbal-ge-demo-agent-app"
        got += f" | delegation sub={dl.get('sub')} act={(dl.get('act') or {}).get('sub')}"
    if ok and extra == "insights":
        ok = d.get("agent") == "insights"
        got += f" | agent={d.get('agent')}"
    if ok and extra == "kyc-ok":
        ok = any(s.get("tool") == "query_bigquery" and s.get("ok") for s in steps)
        got += f" | kyc step ok={ok}"
    return ok, got


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bff", default="http://127.0.0.1:8080")
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--gap", type=int, default=70, help="seconds after a round ends before the next (quota windows)")
    ap.add_argument("--only", nargs="*", help="subset of scenario ids")
    a = ap.parse_args()
    order = [s for s in ORDER if not a.only or s in a.only]
    tally = {s: 0 for s in order}
    for rnd in range(1, a.rounds + 1):
        print(f"--- round {rnd}/{a.rounds}", flush=True)
        for sid in order:
            try:
                ok, got = check(sid, run(a.bff, sid))
            except Exception as e:  # noqa: BLE001
                ok, got = False, f"{type(e).__name__}: {e}"
            tally[sid] += ok
            print(f"  {'ok  ' if ok else 'FAIL'} {sid:22s} {got}", flush=True)
        if rnd < a.rounds:
            print(f"  (waiting {a.gap} s after S5 for the bureau / partner quota windows)", flush=True)
            time.sleep(a.gap)
    print("--- summary")
    for sid in order:
        print(f"  {sid:22s} {tally[sid]}/{a.rounds}")
    return 0 if all(v == a.rounds for v in tally.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
