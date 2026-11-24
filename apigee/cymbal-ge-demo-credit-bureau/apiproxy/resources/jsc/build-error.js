/*
 * JS-Build-Error (cymbal-ge-demo-credit-bureau; DefaultFaultRule of ProxyEndpoint and TargetEndpoint).
 * Bureau 5xx / connection failures -> sanitized 502 upstream-error (bureau body never relayed on errors).
 * Bureau 4xx are NOT faults (success.codes includes 4xx) and pass through untouched.
 */
(function () {
  var reason = BUREAU.faultReason(
    context.getVariable('cymbal.reject'),
    context.getVariable('fault.name'),
    {
      keyFailed: String(context.getVariable('verifyapikey.VA-VerifyKey.failed')) === 'true',
      quotaFailed: String(context.getVariable('ratelimit.Q-Credit-Bureau.failed')) === 'true',
      inTarget: String(context.getVariable('cymbal.in_target')) === 'true'
    }
  );
  var out = BUREAU.buildError(reason, context.getVariable('bureau.id_json'));
  context.setVariable('cymbal.err_status', String(out.status));
  context.setVariable('cymbal.err_policy', out.policy);
  context.setVariable('cymbal.err_body', out.body);
})();
