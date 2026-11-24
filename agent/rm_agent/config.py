"""Runtime configuration for the RM Agent (all from environment variables).

Nothing secret is hard-coded. The Apigee API key arrives as the env var
CYMBAL_AGENT_API_KEY, which Agent Runtime populates from Secret Manager secret
`cymbal-ge-demo-agent-key` (deploy.py uses the secret-reference form
{"secret": ..., "version": "latest"}), so the key never lands in source,
in the deployment archive, or in logs.
"""

from __future__ import annotations

import os
from urllib.parse import urlparse

DEFAULT_APIGEE = "https://YOUR_APIGEE_HOST/cymbal-ge-demo"


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def mcp_banking_url() -> str:
    return _env("CYMBAL_MCP_BANKING_URL", f"{DEFAULT_APIGEE}/mcp/banking")


def credit_bureau_url() -> str:
    # Default: the Apigee proxy in front of the bureau (quota = Apigee, S5).
    # Must equal the URL registered in Agent Registry (gateway matches hosts exactly).
    return _env("CYMBAL_CREDIT_BUREAU_URL", f"{DEFAULT_APIGEE}/bureau/mcp")


def credit_bureau_direct() -> bool:
    """Optional legacy mode: call the Cloud Run bureau directly (ext-proc variant)."""
    return _env("CYMBAL_CREDIT_BUREAU_DIRECT") == "1"


def llm_base_url() -> str:
    return _env("CYMBAL_LLM_BASE_URL", f"{DEFAULT_APIGEE}/llm")


def llm_model() -> str:
    return _env("CYMBAL_LLM_MODEL", "cymbal-auto")


def llm_project() -> str:
    # Only used to build the Vertex-style path the Apigee proxy expects:
    # /v1/projects/{p}/locations/global/publishers/google/models/{model}:generateContent
    return _env("CYMBAL_LLM_PROJECT", "YOUR_PROJECT_ID")


def llm_location() -> str:
    return _env("CYMBAL_LLM_LOCATION", "global")


def api_key() -> str:
    return _env("CYMBAL_AGENT_API_KEY")


def agent_kind() -> str:
    """'rm' (RM Agent, default) or 'insights' (Insights Agent, scenario 7). Same code, different identity."""
    return "insights" if _env("CYMBAL_AGENT_KIND") == "insights" else "rm"


def bq_project() -> str:
    return _env("CYMBAL_BQ_PROJECT", "YOUR_PROJECT_ID")


def bq_location() -> str:
    return _env("CYMBAL_BQ_LOCATION", "asia-southeast1")


def http_timeout() -> float:
    try:
        return max(1.0, float(_env("CYMBAL_HTTP_TIMEOUT", "20")))
    except ValueError:
        return 20.0


def allow_insecure_localhost() -> bool:
    """Local test harness only: permit http://127.0.0.1 / localhost targets."""
    return _env("CYMBAL_ALLOW_INSECURE_LOCALHOST") == "1"


def validate_target_url(url: str) -> str | None:
    """Return an error string if `url` is not an allowed outbound target."""
    try:
        p = urlparse(url)
    except ValueError:
        return "malformed URL"
    if p.scheme == "https" and p.hostname:
        return None
    if (p.scheme == "http" and allow_insecure_localhost()
            and p.hostname in ("127.0.0.1", "localhost")):
        return None
    return "only https:// URLs are allowed"
