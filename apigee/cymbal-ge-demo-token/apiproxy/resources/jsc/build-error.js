/*
 * JS-Build-Error (cymbal-ge-demo-token, DefaultFaultRule)
 * Sets cymbal.err_status / cymbal.err_policy / cymbal.err_body for AM-Error-Response.
 * Precedence: explicit cymbal.reject from a proxy step, then the native fault, then internal-error.
 * Messages are fixed strings: no fault strings, policy names, keys or caller input are echoed.
 */
var CATALOG = {
  'method-not-allowed': [405, 'INVALID_ARGUMENT', 'Only POST is supported on this endpoint.'],
  'unknown-path': [404, 'NOT_FOUND', 'Unknown path. POST /cymbal-ge-demo/token.'],
  'invalid-request': [400, 'INVALID_ARGUMENT', 'Body must be JSON: {"user":"rm-alice"|"teller-bob","actor":"rm-agent"|"insights-agent"}.'],
  'unknown-user': [400, 'INVALID_ARGUMENT', 'Unknown demo user. Use rm-alice or teller-bob.'],
  'unknown-actor': [400, 'INVALID_ARGUMENT', 'Unknown agent. Delegate to rm-agent or insights-agent.'],
  'invalid-api-key': [401, 'UNAUTHENTICATED', 'A valid x-api-key for the web UI app is required.'],
  'rate-limited': [429, 'RESOURCE_EXHAUSTED', 'Too many token requests; slow down.'],
  'config-missing': [500, 'INTERNAL', 'Token service is not configured.'],
  'internal-error': [500, 'INTERNAL', 'Token service error.']
};

var KEY_FAULTS = ['InvalidApiKey', 'FailedToResolveAPIKey', 'ApiKeyNotApproved',
  'InvalidApiKeyForGivenResource', 'consumer_key_expired', 'invalid_client-app_not_approved',
  'DeveloperStatusNotActive', 'app_not_approved'];

function reasonFor(reject, faultName, vars) {
  if (reject && Object.prototype.hasOwnProperty.call(CATALOG, reject)) return reject;
  if (KEY_FAULTS.indexOf(faultName) >= 0 || vars.keyFailed) return 'invalid-api-key';
  if (faultName === 'SpikeArrestViolation') return 'rate-limited';
  return 'internal-error';
}

function buildError(reason) {
  var e = CATALOG[reason];
  return {
    status: e[0],
    policy: reason,
    body: JSON.stringify({ error: { code: e[0], status: e[1], message: e[2], decided_by: 'apigee', policy: reason } })
  };
}

if (typeof context !== 'undefined') {
  var reason = reasonFor(
    context.getVariable('cymbal.reject'),
    context.getVariable('fault.name'),
    { keyFailed: String(context.getVariable('verifyapikey.VA-VerifyKey.failed')) === 'true' }
  );
  var out = buildError(reason);
  context.setVariable('cymbal.err_status', String(out.status));
  context.setVariable('cymbal.err_policy', out.policy);
  context.setVariable('cymbal.err_body', out.body);
}

if (typeof module !== 'undefined') {
  module.exports = { reasonFor: reasonFor, buildError: buildError, CATALOG: CATALOG };
}
