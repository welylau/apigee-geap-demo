/*
 * JS-Build-Error (cymbal-ge-demo-mcp-banking, DefaultFaultRule with AlwaysEnforce).
 * Produces the JSON-RPC error contract from DESIGN.md:
 *   {"jsonrpc":"2.0","id":<id>,"error":{"code":-32001,"message":"...","data":{"decided_by":"apigee","policy":"..."}}}
 * Sets cymbal.err_status / cymbal.err_policy / cymbal.err_body for AM-Error-Response.
 */
(function () {
  var reason = MCP.faultReason(
    context.getVariable('cymbal.reject'),
    context.getVariable('fault.name'),
    {
      keyFailed: String(context.getVariable('verifyapikey.VA-VerifyKey.failed')) === 'true',
      jwtFailed: String(context.getVariable('JWT.failed')) === 'true' ||
        String(context.getVariable('jwt.JWT-Verify-UserToken.failed')) === 'true',
      quotaFailed: String(context.getVariable('ratelimit.Q-Product-Quota.failed')) === 'true'
    }
  );
  var msg = context.getVariable('cymbal.reject') === reason ? context.getVariable('cymbal.reject_message') : null;
  var out = MCP.buildError(reason, context.getVariable('mcp.id_json'), msg || null);
  context.setVariable('cymbal.err_status', String(out.status));
  context.setVariable('cymbal.err_policy', out.policy);
  context.setVariable('cymbal.err_body', out.body);
})();
