"""LLM wiring: ADK Gemini model -> Apigee LLM proxy (model alias cymbal-auto).

Verified against the installed libraries (google-adk 2.14.1, google-genai 2.34.0):
  * google/adk/models/google_llm.py `Gemini` exposes `base_url`, `api_version`
    and `client_kwargs` (forwarded to google.genai.Client; ADK docstring says
    to use client_kwargs rather than overriding `api_client`).
  * google/genai/_api_client.py: with enterprise(vertexai)=True + project +
    location + a custom base_url, the request URL is
      {base_url}/{api_version}/projects/{p}/locations/{l}/publishers/google/models/{m}:generateContent
    i.e. exactly the Apigee contract path
      /cymbal-ge-demo/llm/v1/projects/YOUR_PROJECT_ID/locations/global/publishers/google/models/cymbal-auto:generateContent
  * In that mode genai always sets `Authorization: Bearer <credentials.token>`.
    We pass a static placeholder credential so NO Google access token (agent
    identity, CAA-bound) is ever sent to Apigee; Apigee authenticates the app
    with x-api-key and strips Authorization per contract.
  * `x-api-key` is injected per request in before_model_callback via
    llm_request.config.http_options.headers (Gemini.generate_content_async
    merges them), so the key is read lazily from the env at call time.
  * Runner default RunConfig has no SSE streaming -> generate_content (not
    :streamGenerateContent, which the Apigee proxy rejects).
  * LlmAgent.on_model_error_callback(callback_context, llm_request, error) can
    return an LlmResponse to recover; we turn Apigee 429 / gateway 403 into a
    final event whose error_code/error_message the BFF parses.
"""

from __future__ import annotations

import logging
from typing import Any

from google.adk.agents.callback_context import CallbackContext
from google.adk.models import Gemini
from google.adk.models.llm_request import LlmRequest
from google.adk.models.llm_response import LlmResponse
from google.auth import credentials as ga_credentials
from google.genai import types

from . import config
from .mcp_client import classify

log = logging.getLogger("cymbal.rm_agent")


class ApiKeyOnlyCredentials(ga_credentials.Credentials):
    """Static placeholder bearer so genai never fetches/sends a Google token."""

    PLACEHOLDER = "apigee-api-key-auth"

    def __init__(self) -> None:
        super().__init__()
        self.token = self.PLACEHOLDER
        self.expiry = None  # never expires

    def refresh(self, request: Any) -> None:  # noqa: ARG002
        self.token = self.PLACEHOLDER

    @property
    def expired(self) -> bool:
        return False

    @property
    def valid(self) -> bool:
        return True


def build_model() -> Gemini:
    return Gemini(
        model=config.llm_model(),
        base_url=config.llm_base_url(),
        api_version="v1",
        client_kwargs={
            "enterprise": True,
            "project": config.llm_project(),
            "location": config.llm_location(),
            "credentials": ApiKeyOnlyCredentials(),
        },
    )


def inject_api_key(callback_context: CallbackContext, llm_request: LlmRequest) -> None:
    """before_model_callback: add x-api-key for the Apigee LLM proxy."""
    del callback_context
    key = config.api_key()
    if not key:
        log.warning("CYMBAL_AGENT_API_KEY is not set; Apigee will reject the LLM call")
    if llm_request.config is None:
        llm_request.config = types.GenerateContentConfig()
    if llm_request.config.http_options is None:
        llm_request.config.http_options = types.HttpOptions()
    headers = dict(llm_request.config.http_options.headers or {})
    if key:
        headers["x-api-key"] = key
    llm_request.config.http_options.headers = headers
    return None


def _error_parts(error: Exception) -> tuple[int, dict[str, str], bytes]:
    code = getattr(error, "code", 0) or 0
    resp = getattr(error, "response", None)
    headers: dict[str, str] = {}
    raw_headers = getattr(resp, "headers", None)
    if raw_headers is not None:
        try:
            headers = {str(k).lower(): str(v) for k, v in raw_headers.items()}
        except Exception:  # pylint: disable=broad-except
            headers = {}
    details = getattr(error, "details", None)
    try:
        import json
        raw = json.dumps(details).encode() if details is not None else str(error).encode()
    except (TypeError, ValueError):
        raw = str(error).encode()
    return int(code) if str(code).isdigit() else 0, headers, raw


def on_model_error(callback_context: CallbackContext, llm_request: LlmRequest,
                   error: Exception) -> LlmResponse | None:
    """Surface LLM-path denials as a tagged final event instead of crashing.

    error_message contains the literal tag
      "decided_by=<layer> policy=<policy>"
    e.g. "decided_by=apigee policy=llm-token-budget" (S6) or
         "decided_by=agent-gateway policy=egress-not-authorized".
    """
    del callback_context, llm_request
    status, headers, raw = _error_parts(error)
    if status == 0:
        return None  # not an HTTP API error (e.g. cancellation) -> default handling
    decided_by, policy, detail = classify(status, headers, raw, "llm")
    policy = policy or f"http-{status}"
    tag = f"decided_by={decided_by} policy={policy}"
    log.info("model call refused: status=%s %s", status, tag)
    human = {
        "apigee": "The Apigee LLM gateway refused the model call",
        "agent-gateway": "Agent Gateway blocked the model call",
    }.get(decided_by or "", "The model call failed")
    return LlmResponse(
        error_code=str(status),
        error_message=f"{tag} status={status} detail={detail[:200]}",
        content=types.Content(role="model", parts=[types.Part(
            text=f"{human} ({tag}). I can't continue this request right now.")]),
        turn_complete=True,
    )
