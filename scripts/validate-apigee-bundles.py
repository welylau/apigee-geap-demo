#!/usr/bin/env python3
"""Offline structural checks for the Apigee bundles under apigee/*/apiproxy (no cloud calls).

Checks: XML well-formedness, root descriptor name == directory, policy file name == policy name attribute,
every <Step><Name> resolves to a policy file, every policy file is used, every jsc:// resource and
IncludeURL exists, endpoints listed in the descriptor exist, no unreplaced template tokens except the
documented deploy-time placeholder, no obvious secrets, and the expected private./custom variable prefixes.
Exit 0 = all good, 1 = problems found.
Usage: python3 scripts/validate-apigee-bundles.py [repo_root]
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
APIGEE = os.path.join(ROOT, "apigee")
ALLOWED_PLACEHOLDERS = {"__CREDIT_BUREAU_HOSTS__", "__CREDIT_BUREAU_URL__", "__CREDIT_BUREAU_HOST__", "__CREDIT_BUREAU_AUDIENCE__"}  # replaced by setup-apigee.sh in a staged copy
SECRET_PATTERNS = [re.compile(p) for p in (r"AIza[0-9A-Za-z_\-]{30,}", r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
                                            r"ya29\.[0-9A-Za-z_\-]{20,}")]
OWNED_PREFIXES = ("request.", "response.", "message.", "route.", "proxy.", "client.", "system.",
                  "fault.", "error.", "apiproxy.", "environment.", "organization.")

PASSTHROUGH_BUNDLES = {"cymbal-ge-demo-credit-bureau"}  # response body must reach the caller untouched (S3)
BODY_POLICIES = {"Javascript", "ExtractVariables", "JSONToXML", "XMLToJSON", "JSONThreatProtection",
                 "RegularExpressionProtection", "SanitizeModelResponse", "XSL", "ParsePayload"}

problems = []


def bad(msg):
    problems.append(msg)


def check_bundle(name, base):
    files = {}
    for dirpath, _, fnames in os.walk(base):
        for f in fnames:
            files[os.path.relpath(os.path.join(dirpath, f), base)] = os.path.join(dirpath, f)

    # 1. XML parse
    trees = {}
    for rel, path in files.items():
        if rel.endswith(".xml"):
            try:
                trees[rel] = ET.parse(path).getroot()
            except ET.ParseError as e:
                bad(f"{name}: XML parse error in {rel}: {e}")

    # 2. root descriptor
    desc = trees.get(f"{name}.xml")
    if desc is None or desc.tag != "APIProxy":
        bad(f"{name}: missing root descriptor apiproxy/{name}.xml")
    elif desc.get("name") != name:
        bad(f"{name}: descriptor name {desc.get('name')!r} != directory")

    # 3. policies
    policies = {}
    for rel, root in trees.items():
        if rel.startswith("policies/"):
            pname = os.path.basename(rel)[:-4]
            if root.get("name") != pname:
                bad(f"{name}: {rel} name attribute {root.get('name')!r} != file name")
            policies[pname] = root

    # 4. endpoints and steps
    used = set()
    endpoints = {"proxies": set(), "targets": set()}
    for rel, root in trees.items():
        if rel.startswith("proxies/") or rel.startswith("targets/"):
            endpoints[rel.split("/")[0]].add(root.get("name"))
            for step in root.iter("Step"):
                n = step.find("Name")
                if n is None or not (n.text or "").strip():
                    bad(f"{name}: {rel} has a Step without Name")
                    continue
                pn = n.text.strip()
                used.add(pn)
                if pn not in policies:
                    bad(f"{name}: {rel} references missing policy {pn}")
            for rr in root.iter("RouteRule"):
                te = rr.find("TargetEndpoint")
                if te is not None and not os.path.exists(os.path.join(base, "targets", te.text.strip() + ".xml")):
                    bad(f"{name}: RouteRule targets missing endpoint {te.text.strip()}")
    for pn in policies:
        if pn not in used:
            bad(f"{name}: policy {pn} is never attached")
    if desc is not None:
        for pe in desc.iter("ProxyEndpoint"):
            if pe.text and pe.text.strip() not in endpoints["proxies"]:
                bad(f"{name}: descriptor lists missing ProxyEndpoint {pe.text.strip()}")
        for te in desc.iter("TargetEndpoint"):
            if te.text and te.text.strip() not in endpoints["targets"]:
                bad(f"{name}: descriptor lists missing TargetEndpoint {te.text.strip()}")

    # 5. JS resources
    jsc_used = set()
    for pn, root in policies.items():
        for tag in ("ResourceURL", "IncludeURL"):
            for el in root.iter(tag):
                ref = (el.text or "").strip()
                if not ref.startswith("jsc://"):
                    bad(f"{name}: {pn} {tag} must be jsc://")
                    continue
                f = ref[len("jsc://"):]
                jsc_used.add(f)
                if f"resources/jsc/{f}" not in files:
                    bad(f"{name}: {pn} references missing resources/jsc/{f}")
        if root.tag == "Javascript" and not root.get("timeLimit"):
            bad(f"{name}: {pn} has no timeLimit")
    for rel in files:
        if rel.startswith("resources/jsc/") and os.path.basename(rel) not in jsc_used:
            bad(f"{name}: unused JS resource {rel}")

    # 5b. passthrough bundles: no policy in any normal Response flow may read or change the body
    if name in PASSTHROUGH_BUNDLES:
        for rel, root in trees.items():
            if not (rel.startswith("proxies/") or rel.startswith("targets/")):
                continue
            for flow_parent in list(root.iter("PreFlow")) + list(root.iter("PostFlow")) + list(root.iter("Flow")):
                resp = flow_parent.find("Response")
                if resp is None:
                    continue
                for step in resp.iter("Step"):
                    pol = policies.get((step.findtext("Name") or "").strip())
                    if pol is None:
                        continue
                    body_touch = pol.tag in BODY_POLICIES or (pol.tag == "AssignMessage" and (
                        pol.find(".//Payload") is not None or pol.find(".//Copy") is not None))
                    if body_touch:
                        bad(f"{name}: response step {pol.get('name')} may read/alter the passthrough body")

    # 6. content scans
    for rel, path in files.items():
        text = open(path, encoding="utf-8").read()
        for tok in re.findall(r"__[A-Z][A-Z0-9_]+__", text):
            if tok not in ALLOWED_PLACEHOLDERS:
                bad(f"{name}: unreplaced token {tok} in {rel}")
        for pat in SECRET_PATTERNS:
            if pat.search(text):
                bad(f"{name}: possible secret in {rel}")
        if rel.endswith(".xml"):
            for var in re.findall(r"<Name>([^<]+)</Name>", text):
                if rel.startswith("policies/") and "AssignVariable" in text and var.startswith(OWNED_PREFIXES) \
                        and not var.startswith(("target.", "request.header", "response.header")):
                    bad(f"{name}: {rel} assigns Apigee-owned variable {var}")
    # KVM / JWT secrets must only flow through private.* variables
    for pn, root in policies.items():
        for v in root.iter("Value"):
            ref = v.get("ref")
            if ref and root.tag in ("GenerateJWT", "VerifyJWT") and not ref.startswith("private."):
                bad(f"{name}: {pn} secret ref {ref} must use the private. prefix")
        if root.tag == "KeyValueMapOperations":
            for g in root.iter("Get"):
                if not (g.get("assignTo") or "").startswith("private."):
                    bad(f"{name}: {pn} KVM value must be assigned to a private. variable")
    return len(files)


def main():
    if not os.path.isdir(APIGEE):
        print(f"no apigee/ under {ROOT}")
        return 1
    total = 0
    bundles = sorted(d for d in os.listdir(APIGEE) if os.path.isdir(os.path.join(APIGEE, d, "apiproxy")))
    for b in bundles:
        n = check_bundle(b, os.path.join(APIGEE, b, "apiproxy"))
        total += n
        print(f"  {b}: {n} files")
    if problems:
        print(f"FAIL ({len(problems)} problems):")
        for p in problems:
            print("  - " + p)
        return 1
    print(f"OK: {len(bundles)} bundles, {total} files, structure valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
