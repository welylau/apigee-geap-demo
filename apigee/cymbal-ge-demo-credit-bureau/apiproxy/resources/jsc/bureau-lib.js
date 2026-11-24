/*
 * bureau-lib.js  (cymbal-ge-demo-credit-bureau) - pure functions, ES5; also loaded by node tests.
 *
 * Apigee fronts the third-party credit bureau (Cloud Run, MCP JSON-RPC at /mcp) as a PAID API:
 *   - classify(): only JSON-RPC "tools/call" is a paid lookup; initialize / notifications / ping /
 *     tools/list (the MCP handshake) are free and never counted.
 *   - The request body is read, never modified; the bureau's response body is never read or modified
 *     (Agent Gateway Model Armor must see the raw CUST-666 response for S3).
 *   - errors(): JSON-RPC error contract of DESIGN.md with decided_by "apigee".
 */
var BUREAU = (function () {
  'use strict';

  var MAX_BODY = 65536;

  // [HTTP status, JSON-RPC code, message]
  var REASONS = {
    'parse-error': [400, -32700, 'Parse error: body must be a single JSON-RPC 2.0 object.'],
    'invalid-request': [400, -32600, 'Invalid JSON-RPC 2.0 request.'],
    'method-not-allowed': [405, -32600, 'Only POST is supported (no SSE stream).'],
    'unknown-path': [404, -32600, 'Unknown path. POST JSON-RPC to /cymbal-ge-demo/bureau.'],
    'invalid-api-key': [401, -32001, 'A valid x-api-key for an app on the internal-agent product is required.'],
    'rate-limited': [429, -32001, 'Too many requests; slow down.'],
    'credit-bureau-quota': [429, -32001, 'Credit bureau lookups are a paid API limited to 3 per minute for this app. Try again later.'],
    'upstream-error': [502, -32603, 'The credit bureau is unavailable or returned an error.'],
    'internal-error': [500, -32603, 'Internal error.']
  };

  function isValidId(id) {
    return id === null || typeof id === 'string' || (typeof id === 'number' && isFinite(id));
  }

  function safeIdJson(idJson) {
    if (idJson === null || idJson === undefined || idJson === '') return 'null';
    try {
      var v = JSON.parse(String(idJson));
      return isValidId(v) ? JSON.stringify(v) : 'null';
    } catch (e) {
      return 'null';
    }
  }

  /** -> {ok:true, method, idJson, paid:boolean} | {ok:false, reason, idJson} */
  function classify(bodyText) {
    if (bodyText === null || bodyText === undefined || String(bodyText) === '') return { ok: false, reason: 'parse-error', idJson: 'null' };
    var text = String(bodyText);
    if (text.length > MAX_BODY) return { ok: false, reason: 'invalid-request', idJson: 'null' };
    var msg;
    try { msg = JSON.parse(text); } catch (e) { return { ok: false, reason: 'parse-error', idJson: 'null' }; }
    if (msg === null || typeof msg !== 'object' || msg instanceof Array) return { ok: false, reason: 'invalid-request', idJson: 'null' };
    var hasId = Object.prototype.hasOwnProperty.call(msg, 'id');
    if (hasId && !isValidId(msg.id)) return { ok: false, reason: 'invalid-request', idJson: 'null' };
    var idJson = hasId ? JSON.stringify(msg.id) : 'null';
    if (msg.jsonrpc !== '2.0') return { ok: false, reason: 'invalid-request', idJson: idJson };
    var method = typeof msg.method === 'string' ? msg.method : '';
    if (!method && !(hasId && (Object.prototype.hasOwnProperty.call(msg, 'result') || Object.prototype.hasOwnProperty.call(msg, 'error')))) {
      return { ok: false, reason: 'invalid-request', idJson: idJson };
    }
    return { ok: true, method: method, idJson: idJson, paid: method === 'tools/call' };
  }

  var KEY_FAULTS = ['InvalidApiKey', 'FailedToResolveAPIKey', 'ApiKeyNotApproved', 'InvalidApiKeyForGivenResource',
    'consumer_key_expired', 'invalid_client-app_not_approved', 'DeveloperStatusNotActive', 'app_not_approved'];

  /** flags: {keyFailed, quotaFailed, inTarget} */
  function faultReason(reject, faultName, flags) {
    if (reject && REASONS[reject]) return reject;
    if (KEY_FAULTS.indexOf(faultName) >= 0 || flags.keyFailed) return 'invalid-api-key';
    if (faultName === 'QuotaViolation' || flags.quotaFailed) return 'credit-bureau-quota';
    if (faultName === 'SpikeArrestViolation') return 'rate-limited';
    if (flags.inTarget) return 'upstream-error';
    return 'internal-error';
  }

  function buildError(reason, idJson) {
    var r = REASONS[reason] || REASONS['internal-error'];
    var policy = REASONS[reason] ? reason : 'internal-error';
    var err = { code: r[1], message: r[2], data: { decided_by: 'apigee', policy: policy } };
    return { status: r[0], policy: policy, body: '{"jsonrpc":"2.0","id":' + safeIdJson(idJson) + ',"error":' + JSON.stringify(err) + '}' };
  }

  return { classify: classify, faultReason: faultReason, buildError: buildError, REASONS: REASONS };
})();

if (typeof module !== 'undefined' && module.exports) {
  module.exports = BUREAU;
}
