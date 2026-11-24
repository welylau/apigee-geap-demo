/*
 * JS-Mcp-Authorize (request flow, after VA-VerifyKey and the optional VerifyJWT).
 * Inputs: product custom attributes allowed_tools / user_token_required (via VA-VerifyKey) and the
 * verified end-user claims (jwt.JWT-Verify-UserToken.decoded.claim.*). VerifyJWT already faulted on any
 * invalid token, so claims present here are verified. Decision -> cymbal.reject (+ cymbal.reject_message).
 */
(function () {
  var VA = 'verifyapikey.VA-VerifyKey.apiproduct.';
  var J = 'jwt.JWT-Verify-UserToken.decoded.claim.';
  var tokenPresent = context.getVariable('request.header.x-user-token') !== null &&
    context.getVariable('request.header.x-user-token') !== '';
  var user = MCP.userFromClaims(tokenPresent, {
    sub: context.getVariable(J + 'sub'),
    role: context.getVariable(J + 'role'),
    scope: context.getVariable(J + 'scope'),
    transfer_limit: context.getVariable(J + 'transfer_limit'),
    exp: context.getVariable(J + 'exp'),
    act: context.getVariable(J + 'act')
  });
  var args = {};
  try { args = JSON.parse(context.getVariable('mcp.args_json') || '{}'); } catch (e) { args = {}; }

  var d = MCP.authorize({
    kind: context.getVariable('mcp.kind'),
    method: context.getVariable('mcp.method') || '',
    tool: context.getVariable('mcp.tool') || '',
    args: args,
    allowedToolsAttr: context.getVariable(VA + 'allowed_tools'),
    userTokenRequired: String(context.getVariable(VA + 'user_token_required')) === 'true',
    user: user,
    // Apigee's identity for the calling agent: the developer app behind the verified x-api-key.
    callerApp: context.getVariable('verifyapikey.VA-VerifyKey.app.name')
  });
  if (!d.allow) {
    context.setVariable('cymbal.reject', d.reason);
    if (d.message) context.setVariable('cymbal.reject_message', d.message);
    return;
  }
  context.setVariable('mcp.policy', d.policy);
  if (user) context.setVariable('mcp.user_sub', String(user.sub || ''));
})();
