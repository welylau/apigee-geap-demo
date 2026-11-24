/*
 * JS-Mcp-Respond (proxy response flow; no target). Executes the already-authorized JSON-RPC call
 * against the mock core-banking data and writes the response with the decision headers.
 */
(function () {
  var J = 'jwt.JWT-Verify-UserToken.decoded.claim.';
  var tokenPresent = context.getVariable('request.header.x-user-token') !== null &&
    context.getVariable('request.header.x-user-token') !== '';
  var user = MCP.userFromClaims(tokenPresent, {
    sub: context.getVariable(J + 'sub'),
    role: context.getVariable(J + 'role'),
    scope: context.getVariable(J + 'scope'),
    transfer_limit: context.getVariable(J + 'transfer_limit'),
    exp: context.getVariable(J + 'exp')
  });
  var args = {};
  var params = {};
  try { args = JSON.parse(context.getVariable('mcp.args_json') || '{}'); } catch (e) { args = {}; }
  try { params = JSON.parse(context.getVariable('mcp.params_json') || '{}'); } catch (e2) { params = {}; }

  var r = MCP.respond({
    kind: context.getVariable('mcp.kind'),
    idJson: context.getVariable('mcp.id_json'),
    method: context.getVariable('mcp.method') || '',
    params: params,
    tool: context.getVariable('mcp.tool') || '',
    args: args,
    allowedToolsAttr: context.getVariable('verifyapikey.VA-VerifyKey.apiproduct.allowed_tools'),
    user: user,
    nowIso: new Date().toISOString()
  });

  context.setVariable('response.status.code', r.status);
  if (r.body !== null) {
    context.setVariable('response.header.Content-Type', 'application/json');
    context.setVariable('response.content', r.body);
  } else {
    context.setVariable('response.content', '');
  }
  context.setVariable('response.header.Cache-Control', 'no-store');
  context.setVariable('response.header.x-cymbal-decided-by', 'apigee');
  context.setVariable('response.header.x-cymbal-policy', r.policy);
  if (r.listed !== null && r.listed !== undefined) {
    context.setVariable('response.header.x-cymbal-tools-listed', String(r.listed));
  }
})();
