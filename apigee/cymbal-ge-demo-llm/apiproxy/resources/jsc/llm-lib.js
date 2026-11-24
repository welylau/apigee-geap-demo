/*
 * llm-lib.js  (cymbal-ge-demo-llm)
 * Pure functions: Vertex path validation, cymbal-auto model routing, model allowlist, usage
 * extraction and the sanitized error catalog. Included by the JS policies (IncludeURL) and by
 * tests/llm-lib.test.js under node. ES5 only.
 */
var LLM = (function () {
  'use strict';

  var PATH_RE = /^\/v1(?:beta1)?\/projects\/([^\/]+)\/locations\/([^\/]+)\/publishers\/google\/models\/([^\/:]+):([A-Za-z]+)$/;
  var PROJECT_RE = /^[a-z0-9][a-z0-9-]{0,62}$/;
  var MAX_PROMPT_CHARS = 200000;

  // [HTTP status, Google status, message]
  var REASONS = {
    'method-not-allowed': [405, 'INVALID_ARGUMENT', 'Only POST is supported.'],
    'unknown-path': [404, 'NOT_FOUND', 'Use POST /cymbal-ge-demo/llm/v1/projects/{project}/locations/global/publishers/google/models/{model}:generateContent.'],
    'streaming-not-supported': [400, 'INVALID_ARGUMENT', 'Streaming is not supported by this gateway; use :generateContent.'],
    'location-not-allowed': [400, 'INVALID_ARGUMENT', 'Only location global is supported.'],
    'model-not-allowed': [400, 'INVALID_ARGUMENT', 'Model not allowed. Use cymbal-auto, gemini-3.5-flash or gemini-3.5-flash-lite.'],
    'invalid-request': [400, 'INVALID_ARGUMENT', 'Body must be a Vertex AI generateContent JSON request with contents.'],
    'prompt-too-large': [400, 'INVALID_ARGUMENT', 'Prompt is too large for this gateway.'],
    'invalid-api-key': [401, 'UNAUTHENTICATED', 'A valid x-api-key for an app on the internal-agent product is required.'],
    'llm-token-budget': [429, 'RESOURCE_EXHAUSTED', 'LLM token budget for this app is exhausted. Retry after the budget window.'],
    'llm-budget-not-configured': [500, 'INTERNAL', 'LLM token budget is not configured for this API product.'],
    'upstream-rejected': [400, 'INVALID_ARGUMENT', 'The model rejected the request.'],
    'upstream-rate-limited': [503, 'UNAVAILABLE', 'The model is temporarily rate limited upstream. Retry shortly.'],
    'upstream-error': [502, 'UNAVAILABLE', 'The model backend returned an error.'],
    'internal-error': [500, 'INTERNAL', 'LLM gateway error.']
  };

  function splitList(s) {
    var out = [];
    var parts = String(s || '').split(/[\s,]+/);
    for (var i = 0; i < parts.length; i++) if (parts[i]) out.push(parts[i]);
    return out;
  }

  /** Total characters of all text parts in contents[] and systemInstruction (the routing signal). */
  function promptChars(body) {
    var n = 0;
    function addParts(parts) {
      if (!(parts instanceof Array)) return;
      for (var j = 0; j < parts.length; j++) {
        if (parts[j] && typeof parts[j].text === 'string') n += parts[j].text.length;
      }
    }
    for (var i = 0; i < body.contents.length; i++) {
      if (body.contents[i]) addParts(body.contents[i].parts);
    }
    if (body.systemInstruction && typeof body.systemInstruction === 'object') addParts(body.systemInstruction.parts);
    return n;
  }

  /**
   * in: {pathsuffix, query, bodyText, config:{alias, defaultModel, routedModel, threshold, allowedModels}}
   * out: {ok:true, model, alias, route, chars} | {ok:false, reason}
   */
  function route(input) {
    var cfg = input.config;
    var m = PATH_RE.exec(String(input.pathsuffix || ''));
    if (!m) return { ok: false, reason: 'unknown-path' };
    var project = m[1];
    var location = m[2];
    var model = m[3];
    var verb = m[4];
    if (verb === 'streamGenerateContent' || /(^|&)alt=sse(&|$)/.test(String(input.query || ''))) return { ok: false, reason: 'streaming-not-supported' };
    if (verb !== 'generateContent') return { ok: false, reason: 'unknown-path' };
    if (!PROJECT_RE.test(project)) return { ok: false, reason: 'unknown-path' };
    if (location !== 'global') return { ok: false, reason: 'location-not-allowed' };

    var body;
    try { body = JSON.parse(String(input.bodyText || '')); } catch (e) { return { ok: false, reason: 'invalid-request' }; }
    if (!body || typeof body !== 'object' || !(body.contents instanceof Array) || body.contents.length === 0) {
      return { ok: false, reason: 'invalid-request' };
    }
    var chars = promptChars(body);
    if (chars > MAX_PROMPT_CHARS) return { ok: false, reason: 'prompt-too-large' };

    var allowed = splitList(cfg.allowedModels);
    if (model === cfg.alias) {
      var long = chars > cfg.threshold;
      return { ok: true, alias: model, model: long ? cfg.routedModel : cfg.defaultModel,
        route: long ? 'auto-long-prompt' : 'auto-default', chars: chars };
    }
    if (allowed.indexOf(model) >= 0) return { ok: true, alias: '', model: model, route: 'explicit', chars: chars };
    return { ok: false, reason: 'model-not-allowed' };
  }

  /** Reads Vertex usageMetadata. Missing/invalid usage is reported as invalid, never as zero. */
  function usage(contentText) {
    var body;
    try { body = JSON.parse(String(contentText || '')); } catch (e) { return { valid: false }; }
    var u = body && body.usageMetadata;
    if (!u || typeof u.totalTokenCount !== 'number' || u.totalTokenCount < 0) return { valid: false };
    return {
      valid: true,
      total: u.totalTokenCount,
      prompt: typeof u.promptTokenCount === 'number' ? u.promptTokenCount : 0,
      output: typeof u.candidatesTokenCount === 'number' ? u.candidatesTokenCount : 0,
      thinking: typeof u.thoughtsTokenCount === 'number' ? u.thoughtsTokenCount : 0
    };
  }

  var KEY_FAULTS = ['InvalidApiKey', 'FailedToResolveAPIKey', 'ApiKeyNotApproved', 'InvalidApiKeyForGivenResource',
    'consumer_key_expired', 'invalid_client-app_not_approved', 'DeveloperStatusNotActive', 'app_not_approved'];

  /** flags: {keyFailed, upstreamStatus (number|null), inTarget} */
  function faultReason(reject, faultName, flags) {
    if (reject && REASONS[reject]) return reject;
    if (KEY_FAULTS.indexOf(faultName) >= 0 || flags.keyFailed) return 'invalid-api-key';
    if (faultName === 'LLMTokenQuotaViolation') return 'llm-token-budget';
    if (faultName === 'ErrorResponseCode' || flags.inTarget) {
      var s = flags.upstreamStatus;
      if (s === 429) return 'upstream-rate-limited';
      if (s === 400) return 'upstream-rejected';
      return 'upstream-error';
    }
    return 'internal-error';
  }

  function buildError(reason) {
    var r = REASONS[reason] || REASONS['internal-error'];
    var policy = REASONS[reason] ? reason : 'internal-error';
    return {
      status: r[0],
      policy: policy,
      body: JSON.stringify({ error: { code: r[0], status: r[1], message: r[2], decided_by: 'apigee', policy: policy } })
    };
  }

  return { route: route, usage: usage, promptChars: promptChars, faultReason: faultReason, buildError: buildError, REASONS: REASONS };
})();

if (typeof module !== 'undefined' && module.exports) {
  module.exports = LLM;
}
