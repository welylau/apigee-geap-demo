/*
 * JS-Build-Error (cymbal-ge-demo-llm; DefaultFaultRule of both ProxyEndpoint and TargetEndpoint).
 * Upstream bodies are never relayed: Vertex errors become upstream-* with a fixed message, and a local
 * token-budget rejection (429 llm-token-budget) stays distinguishable from an upstream 429 (503).
 */
(function () {
  var inTarget = String(context.getVariable('cymbal.in_target')) === 'true';
  var status = Number(context.getVariable('response.status.code'));
  var reason = LLM.faultReason(
    context.getVariable('cymbal.reject'),
    context.getVariable('fault.name'),
    {
      keyFailed: String(context.getVariable('verifyapikey.VA-VerifyKey.failed')) === 'true',
      inTarget: inTarget,
      upstreamStatus: isFinite(status) ? status : null
    }
  );
  var out = LLM.buildError(reason);
  context.setVariable('cymbal.err_status', String(out.status));
  context.setVariable('cymbal.err_policy', out.policy);
  context.setVariable('cymbal.err_body', out.body);
})();
